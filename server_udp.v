module socks

import net
import time
import picoev
import socks.core
import socks.resolver
import socks.socks5

// start_udp opens a UDP relay socket bound on the server's IP and replies with
// its address.
fn (mut s Server) start_udp(mut pv picoev.Picoev, mut r Relay) {
	host, _ := split_host_port(s.bound_addr) or {
		s.fail_relay(mut pv, mut r, .general_failure)
		return
	}
	mut u := net.listen_udp('${host}:0') or {
		s.fail_relay(mut pv, mut r, .general_failure)
		return
	}
	// Same deliberate "block forever" read policy as the TCP client/target
	// conns in server.v's on_accept/on_result (see those for the full
	// net.infinite_timeout vs net.no_timeout rationale).
	u.set_read_timeout(net.infinite_timeout)
	// The write side is deliberately the OPPOSITE choice: net.no_timeout
	// makes a write_to call whose send buffer is full fail in microseconds
	// (the same vlib zero-deadline quirk documented on dial() in client.v)
	// instead of blocking the picoev loop. Datagrams here are already
	// best-effort/droppable (every write_to call below is wrapped in `or
	// {}`), so failing fast and dropping one is strictly better than
	// stalling every other connection on a full UDP send buffer.
	u.set_write_timeout(net.no_timeout)
	// net.UdpConn has no `.addr()` (unlike TcpListener/TcpConn); the embedded
	// Socket.address() reads the bound local address via getsockname() (same
	// correction Task 19 applied in its fake_udp_relay test helper).
	uaddr := u.sock.address() or {
		u.close() or {}
		s.fail_relay(mut pv, mut r, .general_failure)
		return
	}
	r.udp = u
	r.udp_fd = u.sock.handle
	bhost := uaddr.str().all_before_last(':')
	bport := uaddr.str().all_after_last(':').u16()
	act := r.m5.on_udp_bound(socks5.Addr{ atyp: .ipv4, host: bhost, port: bport })
	if !s.send_reply(mut pv, mut r, act.reply) {
		return
	}
	r.relaying = true
	r.last_activity = time.now()
	s.relays[r.udp_fd] = r
	s.roles[r.udp_fd] = .udp
	pv_add(mut pv, r.udp_fd)
}

// on_udp_readable forwards a datagram in whichever direction it came.
fn (mut s Server) on_udp_readable(mut pv picoev.Picoev, fd int) {
	mut r := s.relays[fd] or { return }
	mut buf := []u8{len: 65535}
	n, peer := r.udp.read(mut buf) or { return }
	r.last_activity = time.now()
	peer_str := peer.str()
	// The first datagram claiming to be the client is only trusted if its source
	// IP matches the TCP control connection's peer IP (RFC 1928 client-binding).
	// Without this check, any third party who learns the relay's ephemeral UDP
	// port could register itself as "the client" and hijack the association.
	is_client := if r.client_udp == '' {
		peer_str.all_before_last(':') == tcp_client_ip(r)
	} else {
		peer_str == r.client_udp
	}
	if is_client {
		if r.client_udp == '' {
			r.client_udp = peer_str
		}
		dg := socks5.parse_udp_datagram(buf[..n]) or { return } // FRAG!=0 => dropped
		if dg.addr.atyp == .domain {
			s.handle_udp_domain(mut r, dg)
			return
		}
		// dg.addr.host is an IP literal here, so resolve_addrs does no DNS query.
		taddr := resolve_first('${dg.addr.host}:${dg.addr.port}') or { return }
		r.udp.write_to(taddr, dg.data) or {}
	} else {
		pkt := build_udp_reply_datagram(peer, buf[..n]) or { return }
		caddr := resolve_first(r.client_udp) or { return }
		r.udp.write_to(caddr, pkt) or {}
	}
}

// handle_udp_domain forwards (or queues) a client->target datagram whose
// DST.ADDR is a domain name. At most one resolve is kept in flight per
// association: a datagram for a different domain than the one already being
// resolved is dropped, since starting a second resolve would orphan the
// first one's queue entry in s.pending and misroute its result.
fn (mut s Server) handle_udp_domain(mut r Relay, dg socks5.UdpDatagram) {
	if entry := r.udp_cache[dg.addr.host] {
		if time.now() < entry.expires {
			taddr := resolve_first('${entry.ip}:${dg.addr.port}') or { return }
			r.udp.write_to(taddr, dg.data) or {}
			return
		}
	}
	if r.udp_resolve_job != 0 {
		if r.udp_resolve_domain == dg.addr.host {
			r.udp_resolve_queue << UdpPendingDgram{
				data: dg.data
				port: dg.addr.port
			}
			if r.udp_resolve_queue.len > udp_resolve_queue_cap {
				r.udp_resolve_queue = r.udp_resolve_queue[1..]
			}
		}
		// Different domain already in flight: drop silently.
		return
	}
	s.next_id++
	id := s.next_id
	if !s.pool.try_submit(resolver.Job{
		id:     id
		target: core.Target{
			host: dg.addr.host
			port: dg.addr.port
		}
		kind:   .resolve
	}) {
		return
	}
	r.udp_resolve_domain = dg.addr.host
	r.udp_resolve_job = id
	s.pending[id] = r
	r.udp_resolve_queue << UdpPendingDgram{
		data: dg.data
		port: dg.addr.port
	}
}

// tcp_client_ip returns the host part of the relay's TCP control connection's
// peer address, or '' if it can't be determined.
fn tcp_client_ip(r &Relay) string {
	a := r.client.peer_addr() or { return '' }
	return a.str().all_before_last(':')
}

// build_udp_reply_datagram encodes a target's reply as a SOCKS5 UDP datagram
// addressed from peer. Returns none for an IPv6 peer: v1's ATYP is hardcoded
// to .ipv4 here (see LIMITATIONS.md), and mis-encoding an IPv6 source as
// ATYP=0x01 would silently corrupt the header (wrong address byte length)
// rather than just fail loudly, so the datagram is dropped instead.
fn build_udp_reply_datagram(peer net.Addr, data []u8) ?[]u8 {
	if peer.family() == .ip6 {
		return none
	}
	peer_str := peer.str()
	src := socks5.Addr{
		atyp: .ipv4
		host: peer_str.all_before_last(':')
		port: peer_str.all_after_last(':').u16()
	}
	return socks5.encode_udp_datagram(src, data)
}

// resolve_first resolves addr to its first candidate, or none on any failure
// (unresolvable, or resolves to zero addresses) — the shared "best effort,
// silently drop the datagram" shape both UDP relay directions use.
fn resolve_first(addr string) ?net.Addr {
	xs := net.resolve_addrs(addr, .ip, .udp) or { return none }
	if xs.len == 0 {
		return none
	}
	return xs[0]
}
