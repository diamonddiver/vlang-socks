module socks

import net
import sync
import time
import picoev
import socks.core
import socks.socks5
import socks.socks4
import socks.resolver

// sweep_tick is how often reap() checks for handshake timeouts between
// resolver-result wakeups.
const sweep_tick = 1 * time.second

// relay_hwm is the fixed backpressure high-water mark: once a relay
// direction's outbound queue exceeds this many bytes, the opposite side's
// read interest is paused until the queue drains back under it.
const relay_hwm = 256 * 1024

// udp_dns_cache_ttl / udp_dns_cache_cap bound how long and how many
// domain -> IP results a relay caches after a UDP domain-typed resolve, to
// avoid re-resolving every datagram to the same domain.
const udp_dns_cache_ttl = 30 * time.second

const udp_dns_cache_cap = 64

// udp_resolve_queue_cap bounds how many datagrams a relay buffers while a
// UDP domain resolve is in flight (drop-oldest on overflow).
const udp_resolve_queue_cap = 16

// Fd role in the event loop.
enum FdRole {
	listener
	notify
	client
	target
	udp
}

// Relay is one proxied connection: a client side and (once connected) a target
// side, driven by exactly one protocol state machine. @[heap] because every
// Relay is allocated with &Relay{} and shared by pointer through the roles /
// relays / pending maps — V requires heap-declared structs to store and reassign
// mutable references to them across those maps.
@[heap]
struct Relay {
mut:
	client    &net.TcpConn = unsafe { nil }
	target    &net.TcpConn = unsafe { nil }
	client_fd int
	target_fd int = -1
	fam       ProtoFamily
	m5        &socks5.Conn5 = unsafe { nil }
	m4        &socks4.Conn4 = unsafe { nil }
	relaying  bool
	conn_id   u64 // id of this relay's outstanding resolver job (0 = none)
	// accepted_at is used by the handshake-timeout sweep to detect connections
	// that never finish negotiating (see Server.sweep_timeouts).
	accepted_at time.Time
	// last_activity is updated on every successful client/target/UDP read
	// once relaying has started; the idle-timeout sweep closes a relay whose
	// last_activity is too old.
	last_activity time.Time
	// client_out / target_out hold bytes that couldn't be sent immediately
	// (EAGAIN) to the client / target, in send order — drained by
	// drain_client / drain_target on the next writable event. client_paused /
	// target_paused mirror whether the OPPOSITE side's read interest is
	// currently disabled because this queue exceeded relay_hwm (backpressure).
	client_out    []u8
	target_out    []u8
	client_paused bool
	target_paused bool
	// UDP association fields (SOCKS5 UDP ASSOCIATE)
	udp        &net.UdpConn = unsafe { nil }
	udp_fd     int          = -1
	client_udp string
	// UDP domain-typed target resolution: at most one resolve job in flight
	// per association, with datagrams to that same domain queued behind it.
	udp_resolve_domain string
	udp_resolve_job    u64 // id of this relay's outstanding UDP resolve job (0 = none)
	udp_resolve_queue  []UdpPendingDgram
	udp_cache          map[string]UdpCacheEntry
}

struct UdpPendingDgram {
	data []u8
	port u16
}

struct UdpCacheEntry {
	ip      string
	expires time.Time
}

struct Server {
mut:
	cfg        ServerConfig
	bound_addr string
	listener   &net.TcpListener = unsafe { nil }
	pool       resolver.Pool
	pv         &picoev.Picoev = unsafe { nil }
	// notify socket pair: reaper writes a byte, loop drains results.
	notify_w  &net.TcpConn = unsafe { nil }
	notify_r  &net.TcpConn = unsafe { nil }
	notify_fd int
	// fd bookkeeping (only mutated on the loop thread).
	roles   map[int]FdRole
	relays  map[int]&Relay // both client_fd and target_fd key the same Relay
	next_id u64            // monotonic resolver-job id (NEVER an fd — avoids fd-reuse aliasing)
	pending map[u64]&Relay // outstanding resolver jobs, keyed by job id
	// relay_buf is the single shared read buffer for read_some. Safe to reuse
	// across calls: read_some only ever runs on the picoev loop thread (from
	// raw_cb), and by the time try_send()/write() returns, its data argument
	// has already been copied to the kernel — or the unsent remainder has
	// been .clone()'d into a per-relay queue — so overwriting relay_buf on
	// the next read_some call never races with a still-in-flight caller.
	relay_buf []u8 = []u8{len: 65536}
	// results queue + stop flag (shared: guarded by qmu).
	qmu      &sync.Mutex = sync.new_mutex()
	results  []resolver.Result
	stopping bool
	// conn_count is the number of currently accepted connections, enforced
	// against cfg.max_connections in on_accept. Loop-thread-only.
	conn_count int
	// shutdown_done is loop-thread-only; guards shutdown() so pool.close() (which
	// panics on a double-close of its channel) runs exactly once even though
	// several notify bytes can arrive after stopping is set.
	shutdown_done bool
	// lifecycle
	reaper_stop chan bool
	loop_thr    thread
	reaper_thr  thread
}

pub struct ServerHandle {
mut:
	srv &Server = unsafe { nil }
}

pub fn (h ServerHandle) addr() string {
	return h.srv.bound_addr
}

pub fn (mut h ServerHandle) stop() {
	h.srv.request_stop()
}

// wait blocks until the server's owned resources are cleaned up. Because this
// picoev version offers no way to break serve()'s infinite loop, the OS thread
// running the accept loop is intentionally left running as an unreclaimed daemon
// thread until process exit — wait() does NOT join it. wait() therefore does
// NOT guarantee that the picoev accept loop has stopped; it only guarantees the
// resolver workers have been signalled to stop and the results reaper has exited.
// The real proxy listener (s.listener) IS closed by stop(), so the proxy port
// stops accepting new connections promptly, but the picoev loop thread itself
// keeps running.
pub fn (mut h ServerHandle) wait() {
	h.srv.reaper_thr.wait()
}

// spawn_serve starts the listener and event loop without blocking.
pub fn spawn_serve(cfg ServerConfig) !ServerHandle {
	validate_server_config(cfg)!
	mut l := net.listen_tcp(.ip, cfg.addr) or {
		return error('socks: cannot bind ${cfg.addr}: ${err.msg()}')
	}
	addr := l.addr() or {
		l.close() or {}
		return err
	}
	bound := addr.str()
	// notify socket pair over loopback.
	mut np_r, mut np_w := make_notify_pair() or {
		l.close() or {}
		return err
	}
	mut pool := resolver.new(cfg.resolver_threads, cfg.connect_timeout)
	mut srv := &Server{
		cfg:         cfg
		bound_addr:  bound
		listener:    l
		pool:        pool
		notify_r:    np_r
		notify_w:    np_w
		reaper_stop: chan bool{cap: 1}
	}
	srv.notify_fd = np_r.sock.handle
	srv.start() or {
		// pool.close() is safe here (unlike in request_stop()/shutdown()): the
		// loop thread that would ever call pool.submit() has not been spawned
		// yet, since start() failed before reaching that point.
		l.close() or {}
		np_r.close() or {}
		np_w.close() or {}
		pool.close()
		return err
	}
	return ServerHandle{
		srv: srv
	}
}

// serve is the blocking wrapper.
pub fn serve(cfg ServerConfig) ! {
	mut h := spawn_serve(cfg)!
	h.wait()
}

fn (mut s Server) start() ! {
	// picoev.new always creates+binds its OWN internal listener; port:0 keeps it
	// on an ephemeral, never-used port so repeated spawn_serve calls don't clash
	// on a fixed port (Spike B). We never route through picoev's own listener —
	// the real listener and every client/target fd are registered explicitly via
	// pv.add() with the low-level fn (int, int, voidptr) callback. Config.cb
	// (HTTP-mode) and Config.raw_cb (internal-accept-only) are both the wrong hook
	// and are deliberately left unset.
	mut pv := picoev.new(picoev.Config{
		user_data: s
		port:      0
		family:    .ip
	})!
	s.pv = pv
	// Register listener and notify read-end as raw fds.
	s.roles[s.listener.sock.handle] = .listener
	pv_add(mut pv, s.listener.sock.handle)
	s.roles[s.notify_fd] = .notify
	pv_add(mut pv, s.notify_fd)
	// Run the event loop and the results reaper on their own threads.
	s.loop_thr = spawn s.run_loop()
	s.reaper_thr = spawn s.reap()
}

fn (mut s Server) run_loop() {
	s.pv.serve() // never returns (Spike B): picoev has no loop-stop primitive
}

// reap forwards resolver results to the loop and wakes it. It exits on an
// explicit reaper_stop signal rather than on `results` closing: workers may
// still be writing in-flight results to `results` during shutdown, so closing
// that channel would risk a send-on-closed panic. select lets the reaper unblock
// immediately when stop is requested, so wait() can always join it (no hang).
fn (mut s Server) reap() {
	for {
		select {
			r := <-s.pool.results {
				s.qmu.@lock()
				s.results << r
				s.qmu.unlock()
				s.notify_w.write([u8(1)]) or {}
			}
			_ := <-s.reaper_stop {
				break
			}
			sweep_tick {
				// Wake the loop so it can run sweep_timeouts() on the loop
				// thread (s.relays is only ever safely mutated there).
				s.notify_w.write([u8(2)]) or {}
			}
		}
	}
}

fn (mut s Server) request_stop() {
	s.qmu.@lock()
	already := s.stopping
	s.stopping = true
	s.qmu.unlock()
	if already {
		// Idempotent: a second stop() must not re-send on the cap-1 reaper_stop
		// channel (its receiver has already exited → the send would block
		// forever) or double-close the listener.
		return
	}
	// NOTE: pool.close() is intentionally NOT called here. submit() is only ever
	// called on the loop thread (via apply()), and closing the pool's channel
	// concurrently with a submit() panics the whole process (see resolver.submit /
	// resolver.close doc comments). request_stop() runs on an arbitrary external
	// caller thread, so it must not touch the pool. Instead we wake the loop and
	// let shutdown() — which runs ON the loop thread — call pool.close(), where it
	// cannot race a concurrent submit().
	s.reaper_stop <- true // unblock the reaper's select so wait() can join it
	s.notify_w.write([u8(9)]) or {} // wake the loop so on_notify observes `stopping`
	s.listener.close() or {}
}

// raw_cb is picoev's per-fd event entry point. Signature per Spike B:
// fn (fd int, events int, context voidptr), where context is &Picoev. Recover
// the Picoev, then our Server from pv.user_data.
fn raw_cb(fd int, events int, context voidptr) {
	mut pv := unsafe { &picoev.Picoev(context) }
	mut s := unsafe { &Server(pv.user_data) }
	role := s.roles[fd] or { return }
	if (role == .client || role == .target) && events & picoev.picoev_write != 0 {
		s.on_writable(mut pv, fd, role)
		// on_writable may have closed the relay on a hard send error — bail
		// before touching read handling below if so.
		if fd !in s.roles {
			return
		}
	}
	if events & picoev.picoev_read != 0 {
		match role {
			.listener { s.on_accept(mut pv) }
			.notify { s.on_notify(mut pv) }
			.client { s.on_client_readable(mut pv, fd) }
			.target { s.on_target_readable(mut pv, fd) }
			.udp { s.on_udp_readable(mut pv, fd) }
		}
	}
}

fn (mut s Server) on_accept(mut pv picoev.Picoev) {
	mut c := s.listener.accept() or { return }
	if s.cfg.max_connections > 0 && s.conn_count >= s.cfg.max_connections {
		c.close() or {}
		return
	}
	// Deliberately net.infinite_timeout, NOT net.no_timeout / the vlib default:
	// see dial()'s doc comment in client.v for the full explanation of why
	// net.no_timeout (Duration(0)) is a plausible-looking WRONG choice on this
	// V version (a zero-valued time.Time{} quirk makes reads/writes fail in
	// microseconds instead of blocking). Relay traffic is meant to be long-lived,
	// so "block forever" must be an explicit, deliberate choice here too, not
	// whatever a freshly-constructed TcpConn happens to default to. The
	// handshake itself is separately bounded by sweep_timeouts/accepted_at
	// below, since this socket-level timeout only limits a single blocking
	// read call and never fires for a connection that sends no bytes at all.
	c.set_read_timeout(net.infinite_timeout)
	c.set_write_timeout(net.infinite_timeout)
	fd := c.sock.handle
	mut r := &Relay{
		client:      c
		client_fd:   fd
		accepted_at: time.now()
	}
	s.relays[fd] = r
	s.roles[fd] = .client
	s.conn_count++
	pv_add(mut pv, fd)
}

fn (mut s Server) on_client_readable(mut pv picoev.Picoev, fd int) {
	mut r := s.relays[fd] or { return }
	data := s.read_some(mut r.client) or {
		s.close_relay(mut pv, mut r, none)
		return
	}
	if data.len == 0 {
		s.close_relay(mut pv, mut r, none)
		return
	}
	r.last_activity = time.now()
	if r.relaying {
		// forward client -> target
		if r.target_fd >= 0 {
			s.send_to_target(mut pv, mut r, data)
		}
		return
	}
	s.drive(mut pv, mut r, data)
}

// drive feeds bytes to the connection's state machine, choosing the protocol on
// the first byte, and acts on the resulting Action.
fn (mut s Server) drive(mut pv picoev.Picoev, mut r Relay, data []u8) {
	mut feed := data.clone()
	if r.m5 == unsafe { nil } && r.m4 == unsafe { nil } {
		fam := dispatch_family(feed[0], s.cfg) or {
			s.close_relay(mut pv, mut r, none)
			return
		}
		r.fam = fam
		if fam == .socks5 {
			r.m5 = &socks5.Conn5{
				cfg:   s.socks5_cfg()
				stage: .handshake
			}
		} else {
			r.m4 = &socks4.Conn4{
				cfg:   s.socks4_cfg()
				stage: .request
			}
		}
	}
	act := if r.fam == .socks5 {
		r.m5.feed(feed) or {
			s.close_relay(mut pv, mut r, none)
			return
		}
	} else {
		r.m4.feed(feed) or {
			s.close_relay(mut pv, mut r, none)
			return
		}
	}
	s.apply(mut pv, mut r, act)
}

fn (mut s Server) apply(mut pv picoev.Picoev, mut r Relay, act core.Action) {
	if !s.send_reply(mut pv, mut r, act.reply) {
		return
	}
	if act.close {
		s.close_relay(mut pv, mut r, none)
		return
	}
	if act.udp_associate {
		s.start_udp(mut pv, mut r)
		return
	}
	if t := act.connect {
		if s.cfg.resolve_mode == .client_side && !is_ip_literal(t.host) {
			// .client_side means the server must not resolve domain names
			// itself; a client that sent one anyway is refused instead of
			// silently falling back to server-side DNS.
			s.fail_relay(mut pv, mut r, .address_type_not_supported)
			return
		}
		if s.cfg.log_connections {
			ver := if r.fam == .socks5 { 'socks5' } else { 'socks4' }
			src := if a := r.client.peer_addr() { a.str() } else { '?' }
			println('${ver} ${src} -> ${t.host}:${t.port}')
		}
		s.next_id++
		id := s.next_id
		if !s.pool.try_submit(resolver.Job{ id: id, target: t }) {
			// All resolver workers are stuck and the job queue is full: fail
			// this connection fast instead of blocking submit(), which would
			// stall the entire event loop (every other connection) until a
			// worker frees up.
			s.fail_relay(mut pv, mut r, .general_failure)
			return
		}
		r.conn_id = id
		s.pending[id] = r
	}
}

fn (mut s Server) on_notify(mut pv picoev.Picoev) {
	mut drain := []u8{len: 64}
	s.notify_r.read(mut drain) or {}
	s.qmu.@lock()
	stopping := s.stopping
	batch := s.results.clone()
	s.results = []
	s.qmu.unlock()
	if stopping {
		s.shutdown(mut pv)
		return
	}
	for res in batch {
		s.on_result(mut pv, res)
	}
	s.sweep_timeouts(mut pv)
}

// sweep_timeouts closes any accepted connection that hasn't finished its
// SOCKS4/5 handshake within cfg.handshake_timeout, and any established relay
// that has idled (no successful read in either direction) longer than
// cfg.idle_timeout. Run on the loop thread only (woken periodically by
// reap()'s sweep_tick), since s.relays must only be mutated there.
fn (mut s Server) sweep_timeouts(mut pv picoev.Picoev) {
	if s.cfg.handshake_timeout <= 0 && s.cfg.idle_timeout <= 0 {
		return
	}
	now := time.now()
	for fd, _ in s.relays.clone() {
		mut r := s.relays[fd] or { continue }
		// Only check once per relay, keyed on its client_fd (target/udp fds
		// share the same Relay pointer and would otherwise be checked twice).
		if fd != r.client_fd {
			continue
		}
		if r.relaying {
			if s.cfg.idle_timeout > 0 && now - r.last_activity > s.cfg.idle_timeout {
				s.close_relay(mut pv, mut r, none)
			}
		} else {
			if s.cfg.handshake_timeout > 0 && now - r.accepted_at > s.cfg.handshake_timeout {
				s.close_relay(mut pv, mut r, core.SocksErrorCode.local_timeout)
			}
		}
	}
}

fn (mut s Server) on_result(mut pv picoev.Picoev, res resolver.Result) {
	// Look the relay up by the unique job id, not the fd: a client can vanish
	// mid-resolve and its fd be reused by a fresh accept before this result
	// lands, so keying on fd would attach the target to the wrong connection.
	mut r := s.pending[res.id] or {
		// Client already gone: close_relay dropped the pending entry while this
		// job was in flight. If the resolver still produced a connected socket,
		// close it here — otherwise its fd leaks (no relay owns it).
		if mut orphan := res.conn {
			orphan.close() or {}
		}
		return
	}
	if r.udp_resolve_job == res.id {
		s.on_udp_resolve_result(mut r, res)
		return
	}
	s.pending.delete(res.id)
	r.conn_id = 0
	if mut tconn := res.conn {
		// Same deliberate "block forever" policy as on_accept's client conn
		// above (and dial()'s tunnel conn in client.v) — an explicit,
		// verified choice rather than whatever a freshly-connected TcpConn
		// happens to default to.
		tconn.set_read_timeout(net.infinite_timeout)
		tconn.set_write_timeout(net.infinite_timeout)
		r.target = tconn
		r.target_fd = tconn.sock.handle
		bound := socks5.Addr{
			atyp: .ipv4
			host: '0.0.0.0'
			port: 0
		}
		act := if r.fam == .socks5 {
			r.m5.on_connected(bound)
		} else {
			r.m4.on_connected()
		}
		// SUCCESS reply. send_reply guarantees the client gets the COMPLETE
		// reply frame before any relay bytes: after this we set relaying=true
		// and start forwarding target->client via send_to_client (which
		// appends after client_out), so a partial reply left unqueued would
		// let the client read relay data as the tail of the SOCKS reply =>
		// protocol desync. Sent BEFORE relaying=true / target registration so
		// it always leads the queue.
		if !s.send_reply(mut pv, mut r, act.reply) {
			return
		}
		r.relaying = true
		r.last_activity = time.now()
		// Register the target fd (and its role) BEFORE flushing any
		// pipelined leftover below: send_to_target's own interest sync must
		// be the last word on the target fd's epoll interest, or this
		// pv_add's plain read-only interest (issued afterwards) would
		// clobber a write-interest bit it had just armed for a slow target.
		s.relays[r.target_fd] = r
		s.roles[r.target_fd] = .target
		pv_add(mut pv, r.target_fd)
		// Flush any client bytes that arrived pipelined before the reply. They
		// were buffered in the state machine (the request-parsing loop leaves the
		// post-request tail in `buf`, and any bytes read while .pending are
		// appended there too), NOT lost — but nothing forwards them unless we do
		// it here, before the first fresh client readable event. Without this a
		// client that sends CONNECT + payload in one segment loses the payload.
		mut leftover := if r.fam == .socks5 { r.m5.buf } else { r.m4.buf }
		if leftover.len > 0 {
			s.send_to_target(mut pv, mut r, leftover)
			if r.fam == .socks5 {
				r.m5.buf = []u8{}
			} else {
				r.m4.buf = []u8{}
			}
		}
	} else {
		kind := if e := res.err { e.kind } else { core.SocksErrorCode.general_failure }
		s.fail_relay(mut pv, mut r, kind)
	}
}

// on_udp_resolve_result handles a resolver result for a UDP domain-typed
// target: on success, caches the resolved IP and forwards every datagram
// queued behind this resolve; on failure, drops them all silently (matching
// the existing best-effort UDP relay semantics).
fn (mut s Server) on_udp_resolve_result(mut r Relay, res resolver.Result) {
	s.pending.delete(res.id)
	r.udp_resolve_job = 0
	domain := r.udp_resolve_domain
	r.udp_resolve_domain = ''
	queue := r.udp_resolve_queue.clone()
	r.udp_resolve_queue = []
	addr := res.addr or { return }
	host := addr.str().all_before_last(':')
	if r.udp_cache.len >= udp_dns_cache_cap && domain !in r.udp_cache {
		mut oldest_k := ''
		mut oldest_t := time.now().add(1000 * time.hour)
		for k, v in r.udp_cache {
			if v.expires < oldest_t {
				oldest_t = v.expires
				oldest_k = k
			}
		}
		if oldest_k != '' {
			r.udp_cache.delete(oldest_k)
		}
	}
	r.udp_cache[domain] = UdpCacheEntry{
		ip:      host
		expires: time.now().add(udp_dns_cache_ttl)
	}
	for dg in queue {
		taddr := resolve_first('${host}:${dg.port}') or { continue }
		r.udp.write_to(taddr, dg.data) or {}
	}
}

fn (mut s Server) on_target_readable(mut pv picoev.Picoev, fd int) {
	mut r := s.relays[fd] or { return }
	data := s.read_some(mut r.target) or {
		s.close_relay(mut pv, mut r, none)
		return
	}
	if data.len == 0 {
		s.close_relay(mut pv, mut r, none)
		return
	}
	r.last_activity = time.now()
	s.send_to_client(mut pv, mut r, data)
}

fn (mut s Server) fail_relay(mut pv picoev.Picoev, mut r Relay, kind core.SocksErrorCode) {
	act := if r.fam == .socks5 {
		r.m5.on_failed(kind)
	} else {
		r.m4.on_failed(kind)
	}
	try_send(r.client_fd, act.reply) or {}
	s.close_relay(mut pv, mut r, none)
}

fn (mut s Server) close_relay(mut pv picoev.Picoev, mut r Relay, reason ?core.SocksErrorCode) {
	if s.cfg.log_connections {
		println('close fd=${r.client_fd} reason=${reason}')
	}
	if r.conn_id != 0 {
		s.pending.delete(r.conn_id)
		r.conn_id = 0
	}
	if r.udp_resolve_job != 0 {
		s.pending.delete(r.udp_resolve_job)
		r.udp_resolve_job = 0
	}
	r.udp_resolve_domain = ''
	r.udp_resolve_queue = []
	if r.client_fd >= 0 {
		pv_del(mut pv, r.client_fd)
		s.roles.delete(r.client_fd)
		s.relays.delete(r.client_fd)
		r.client.close() or {}
		r.client_fd = -1 // idempotent: a second close_relay on this relay is a no-op
		s.conn_count--
	}
	if r.target_fd >= 0 {
		pv_del(mut pv, r.target_fd)
		s.roles.delete(r.target_fd)
		s.relays.delete(r.target_fd)
		r.target.close() or {}
		r.target_fd = -1
	}
	if r.udp_fd >= 0 {
		pv_del(mut pv, r.udp_fd)
		s.roles.delete(r.udp_fd)
		s.relays.delete(r.udp_fd)
		r.udp.close() or {}
		r.udp_fd = -1
	}
}

fn (mut s Server) shutdown(mut pv picoev.Picoev) {
	// Idempotent: several notify bytes can arrive after `stopping` is set (the
	// reaper may forward an in-flight result and the stop path also writes one),
	// each waking on_notify → shutdown. pool.close() panics on a double-close of
	// its channel, so guard the whole body to run exactly once.
	if s.shutdown_done {
		return
	}
	s.shutdown_done = true
	// Close every live relay (client + target) so no fd leaks across repeated
	// spawn_serve/stop cycles in a test suite. relays keys each connection by both
	// its fds, so we iterate over a snapshot of the keys and re-look-up in the live
	// map: close_relay deletes both keys of a relay, so the second key hits the
	// `or { continue }` and is skipped.
	for fd, _ in s.relays.clone() {
		mut r := s.relays[fd] or { continue }
		s.close_relay(mut pv, mut r, none)
	}
	// The notify pair is Server-owned and, unlike every relay fd, had no other
	// cleanup path: request_stop() (external thread) only closes s.listener,
	// so without this, both ends leaked 2 fds on every spawn_serve/stop cycle.
	pv_del(mut pv, s.notify_fd)
	s.roles.delete(s.notify_fd)
	s.notify_r.close() or {}
	s.notify_w.close() or {}
	// Shut the resolver pool down here — on the loop thread, the ONLY thread that
	// ever calls submit() — so pool.close() can never race a concurrent submit().
	s.pool.close()
}

fn (s Server) socks5_cfg() socks5.Conn5Config {
	is_up := s.cfg.auth is UserPassAuth
	mut user := ''
	mut pass := ''
	if is_up {
		up := s.cfg.auth as UserPassAuth
		user = up.user
		pass = up.pass
	}
	return socks5.Conn5Config{
		require_userpass: is_up
		username:         user
		password:         pass
		allow_udp:        s.cfg.allow_udp
	}
}

fn (s Server) socks4_cfg() socks4.Conn4Config {
	return socks4.Conn4Config{
		allow_plain: SocksVersion.v4 in s.cfg.versions
		allow_4a:    SocksVersion.v4a in s.cfg.versions
	}
}

// read_some reads whatever is currently available (picoev signalled readable)
// into the shared relay_buf and returns a view of just the bytes read. See
// relay_buf's doc comment on Server for why reusing that buffer is safe.
fn (mut s Server) read_some(mut c net.TcpConn) ![]u8 {
	n := c.read(mut s.relay_buf) or { return err }
	return s.relay_buf[..n]
}

$if windows {
	#include <winsock2.h>
} $else {
	#include <sys/socket.h>
}

fn C.send(sockfd int, buf voidptr, len usize, flags int) int

// try_send attempts exactly one non-blocking send of data and returns how
// many bytes actually went to the kernel (0 if the socket isn't currently
// writable — not an error).
//
// TcpConn.write()/write_ptr() are unusable for relay writes: on EAGAIN,
// vlib's write_ptr calls a BLOCKING select() gated by the socket's write
// deadline (relay sockets use net.infinite_timeout, i.e. block forever), and
// it discards the partial-sent count on top of that. Either one of those
// would stall the whole event loop on a single slow peer. Binding vlib's own
// raw C.send with MSG_DONTWAIT sidesteps both: it never blocks, and it
// reports exactly how much was sent so the caller can queue the remainder.
fn try_send(fd int, data []u8) !int {
	if data.len == 0 {
		return 0
	}
	n := C.send(fd, data.data, usize(data.len), net.msg_dontwait | net.msg_nosignal)
	if n >= 0 {
		return n
	}
	code := net.error_code()
	if code == int(net.error_ewouldblock) || code == int(net.error_eagain) {
		return 0
	}
	return error('send failed: errno ${code}')
}

// send_reply delivers a single SOCKS reply frame (handshake/auth/connect/
// udp-bind reply) to the client. Like send_to_target/send_to_client below, it
// never sends ahead of an existing backlog: if client_out already has bytes
// queued, the frame is appended behind them instead of racing a fresh
// try_send in front of the backlog, which would let this frame's bytes reach
// the wire before an earlier, still-queued frame's tail. Returns false
// (having already closed the relay) on a hard send error; true otherwise,
// including the no-op case of an empty reply.
fn (mut s Server) send_reply(mut pv picoev.Picoev, mut r Relay, reply []u8) bool {
	if reply.len == 0 {
		return true
	}
	mut sent := 0
	if r.client_out.len == 0 {
		sent = try_send(r.client_fd, reply) or {
			s.close_relay(mut pv, mut r, none)
			return false
		}
	}
	if sent < reply.len {
		r.client_out << reply[sent..].clone()
		s.sync_client_interest(mut pv, mut r)
	}
	return true
}

// send_to_target sends data toward the target, queuing whatever the kernel
// won't take right now. Never sends ahead of an existing backlog: if
// target_out already has bytes queued, data is appended behind them instead
// of racing a fresh try_send in front of the backlog.
fn (mut s Server) send_to_target(mut pv picoev.Picoev, mut r Relay, data []u8) {
	if r.target_out.len == 0 {
		n := try_send(r.target_fd, data) or {
			s.close_relay(mut pv, mut r, none)
			return
		}
		if n < data.len {
			r.target_out << data[n..].clone()
		}
	} else {
		r.target_out << data.clone()
	}
	r.client_paused = r.target_out.len > relay_hwm
	s.sync_client_interest(mut pv, mut r)
	s.sync_target_interest(mut pv, mut r)
}

// send_to_client mirrors send_to_target for the client direction.
fn (mut s Server) send_to_client(mut pv picoev.Picoev, mut r Relay, data []u8) {
	if r.client_out.len == 0 {
		n := try_send(r.client_fd, data) or {
			s.close_relay(mut pv, mut r, none)
			return
		}
		if n < data.len {
			r.client_out << data[n..].clone()
		}
	} else {
		r.client_out << data.clone()
	}
	r.target_paused = r.client_out.len > relay_hwm
	s.sync_client_interest(mut pv, mut r)
	s.sync_target_interest(mut pv, mut r)
}

// drain_target retries the queued backlog toward target on a writable event,
// slicing off whatever the kernel accepted this time.
fn (mut s Server) drain_target(mut pv picoev.Picoev, mut r Relay) {
	n := try_send(r.target_fd, r.target_out) or {
		s.close_relay(mut pv, mut r, none)
		return
	}
	r.target_out = r.target_out[n..]
	r.client_paused = r.target_out.len > relay_hwm
	s.sync_client_interest(mut pv, mut r)
	s.sync_target_interest(mut pv, mut r)
}

// drain_client mirrors drain_target for the client direction.
fn (mut s Server) drain_client(mut pv picoev.Picoev, mut r Relay) {
	n := try_send(r.client_fd, r.client_out) or {
		s.close_relay(mut pv, mut r, none)
		return
	}
	r.client_out = r.client_out[n..]
	r.target_paused = r.client_out.len > relay_hwm
	s.sync_client_interest(mut pv, mut r)
	s.sync_target_interest(mut pv, mut r)
}

// sync_client_interest re-arms the client fd's epoll interest: read unless
// paused, write only while client_out still has bytes queued. Clearing the
// write bit the instant the queue empties is mandatory — picoev's EPOLLOUT
// is level-triggered, so leaving it set on an empty queue would busy-spin
// the loop at 100% CPU on an idle connection whose peer merely has free
// buffer.
fn (mut s Server) sync_client_interest(mut pv picoev.Picoev, mut r Relay) {
	if r.client_fd < 0 {
		return
	}
	mut events := 0
	if !r.client_paused {
		events |= picoev.picoev_read
	}
	if r.client_out.len > 0 {
		events |= picoev.picoev_write
	}
	pv.add(r.client_fd, events, 0, raw_cb)
}

// sync_target_interest mirrors sync_client_interest for the target fd.
fn (mut s Server) sync_target_interest(mut pv picoev.Picoev, mut r Relay) {
	if r.target_fd < 0 {
		return
	}
	mut events := 0
	if !r.target_paused {
		events |= picoev.picoev_read
	}
	if r.target_out.len > 0 {
		events |= picoev.picoev_write
	}
	pv.add(r.target_fd, events, 0, raw_cb)
}

// on_writable handles a writable event on a client/target fd by draining
// that side's queued backlog.
fn (mut s Server) on_writable(mut pv picoev.Picoev, fd int, role FdRole) {
	mut r := s.relays[fd] or { return }
	if role == .client {
		s.drain_client(mut pv, mut r)
	} else {
		s.drain_target(mut pv, mut r)
	}
}

// --- picoev primitives (adapted to the API confirmed in Spike B) ---

fn pv_add(mut pv picoev.Picoev, fd int) {
	pv.add(fd, picoev.picoev_read, 0, raw_cb)
}

fn pv_del(mut pv picoev.Picoev, fd int) {
	pv.delete(fd)
}

// make_notify_pair builds a connected loopback TCP pair used to wake the loop.
fn make_notify_pair() !(&net.TcpConn, &net.TcpConn) {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	addr := l.addr()!.str()
	mut w := net.dial_tcp(addr)!
	mut r := l.accept()!
	l.close() or {}
	return r, w
}
