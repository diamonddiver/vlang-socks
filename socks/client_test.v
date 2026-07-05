module socks

import net
import time
import socks.core
import socks.socks5
import socks.socks4

fn spawn_fake_proxy(handler fn (mut net.TcpConn)) !(&net.TcpListener, string) {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	addr := l.addr()!.str()
	spawn fn (mut l net.TcpListener, handler fn (mut net.TcpConn)) {
		mut c := l.accept() or { return }
		handler(mut c)
	}(mut l, handler)
	return l, addr
}

fn echo_loop(mut c net.TcpConn) {
	for {
		mut b := []u8{len: 64}
		n := c.read(mut b) or { break }
		if n == 0 {
			break
		}
		c.write(b[..n]) or { break }
	}
}

fn handle_s5_noauth(mut c net.TcpConn) {
	mut h := []u8{len: 2}
	c.read(mut h) or { return }
	mut methods := []u8{len: int(h[1])}
	c.read(mut methods) or { return }
	c.write(socks5.encode_method_select(socks5.method_no_auth)) or { return }
	mut req := []u8{len: 10} // IPv4 CONNECT is exactly 10 bytes
	c.read(mut req) or { return }
	c.write(socks5.encode_reply(core.rep_success, socks5.Addr{ atyp: .ipv4, host: '0.0.0.0', port: 0 })) or {
		return
	}
	echo_loop(mut c)
}

fn handle_s5_userpass(status_ok bool) fn (mut net.TcpConn) {
	return fn [status_ok] (mut c net.TcpConn) {
		mut h := []u8{len: 2}
		c.read(mut h) or { return }
		mut methods := []u8{len: int(h[1])}
		c.read(mut methods) or { return }
		c.write(socks5.encode_method_select(socks5.method_user_pass)) or { return }
		mut ub := []u8{len: 256}
		c.read(mut ub) or { return } // whole userpass frame in one localhost read
		c.write(socks5.encode_userpass_reply(status_ok)) or { return }
		if !status_ok {
			return
		}
		mut req := []u8{len: 10}
		c.read(mut req) or { return }
		c.write(socks5.encode_reply(core.rep_success, socks5.Addr{
			atyp: .ipv4
			host: '0.0.0.0'
			port: 0
		})) or { return }
		echo_loop(mut c)
	}
}

fn handle_s5_fail(mut c net.TcpConn) {
	mut h := []u8{len: 2}
	c.read(mut h) or { return }
	mut methods := []u8{len: int(h[1])}
	c.read(mut methods) or { return }
	c.write(socks5.encode_method_select(socks5.method_no_auth)) or { return }
	mut req := []u8{len: 10}
	c.read(mut req) or { return }
	c.write(socks5.encode_reply(core.rep_code(.host_unreachable), socks5.Addr{
		atyp: .ipv4
		host: '0.0.0.0'
		port: 0
	})) or { return }
}

fn handle_s4(mut c net.TcpConn) {
	mut b := []u8{len: 512}
	c.read(mut b) or { return } // whole SOCKS4/4a request in one localhost read
	c.write(socks4.encode_reply(core.cd_granted)) or { return }
	echo_loop(mut c)
}

fn roundtrip(mut conn net.TcpConn) ! {
	conn.write('ping'.bytes())!
	mut b := []u8{len: 16}
	n := conn.read(mut b)!
	assert b[..n] == 'ping'.bytes()
}

fn test_dial_socks5_noauth() {
	mut l, addr := spawn_fake_proxy(handle_s5_noauth) or { panic(err) }
	defer {
		l.close() or {}
	}
	mut conn := dial(ClientConfig{ proxy_addr: addr }, '1.2.3.4:80')!
	roundtrip(mut conn)!
	conn.close()!
}

fn test_dial_socks5_userpass_ok() {
	mut l, addr := spawn_fake_proxy(handle_s5_userpass(true)) or { panic(err) }
	defer {
		l.close() or {}
	}
	cfg := ClientConfig{
		proxy_addr: addr
		auth:       user_pass_auth('u', 'p')
	}
	mut conn := dial(cfg, '1.2.3.4:80')!
	roundtrip(mut conn)!
	conn.close()!
}

fn test_dial_socks5_userpass_rejected() {
	mut l, addr := spawn_fake_proxy(handle_s5_userpass(false)) or { panic(err) }
	defer {
		l.close() or {}
	}
	cfg := ClientConfig{
		proxy_addr: addr
		auth:       user_pass_auth('u', 'WRONG')
	}
	dial(cfg, '1.2.3.4:80') or {
		assert (err as core.SocksError).kind == .auth_failed
		return
	}
	assert false
}

// test_dial_socks5_rejects_oversized_username guards against a regression:
// encode_userpass casts the username/password byte length to u8 with no
// bounds check, so a >255-byte credential silently wrapped and corrupted the
// RFC 1929 sub-negotiation frame instead of erroring before ever reaching the
// wire.
fn test_dial_socks5_rejects_oversized_username() {
	mut l, addr := spawn_fake_proxy(handle_s5_userpass(true)) or { panic(err) }
	defer {
		l.close() or {}
	}
	long_user := 'u'.repeat(256)
	cfg := ClientConfig{
		proxy_addr: addr
		auth:       user_pass_auth(long_user, 'p')
	}
	dial(cfg, '1.2.3.4:80') or {
		assert (err as core.SocksError).kind == .protocol_error
		assert err.msg().contains('255')
		return
	}
	assert false
}

fn test_dial_socks5_failure_maps_code() {
	mut l, addr := spawn_fake_proxy(handle_s5_fail) or { panic(err) }
	defer {
		l.close() or {}
	}
	dial(ClientConfig{ proxy_addr: addr }, '5.6.7.8:80') or {
		assert (err as core.SocksError).kind == .host_unreachable
		return
	}
	assert false
}

fn test_dial_socks4() {
	mut l, addr := spawn_fake_proxy(handle_s4) or { panic(err) }
	defer {
		l.close() or {}
	}
	cfg := ClientConfig{
		proxy_addr: addr
		version:    .v4
	}
	mut conn := dial(cfg, '1.2.3.4:80')!
	roundtrip(mut conn)!
	conn.close()!
}

fn test_dial_socks4a() {
	mut l, addr := spawn_fake_proxy(handle_s4) or { panic(err) }
	defer {
		l.close() or {}
	}
	cfg := ClientConfig{
		proxy_addr: addr
		version:    .v4a
	}
	mut conn := dial(cfg, 'example.com:80')!
	roundtrip(mut conn)!
	conn.close()!
}

// test_dial_clears_handshake_deadline guards against a regression: dial()
// sets client_timeout (30s) on the raw connection to bound the SOCKS
// handshake, but must clear it again before handing the connection back to
// the caller. Under the old blocking-socket build this deadline was inert,
// so a leftover 30s timeout was silently harmless; under
// -d net_nonblocking_sockets (see commit 22348c5) it is enforced for real,
// and a caller idling on the returned connection for >30s (e.g. a
// long-poll) would get a spurious timeout error that never happened
// before. Assert directly on TcpConn's public read_timeout()/
// write_timeout() getters, which read back the exact net.Duration dial()
// leaves in place — this is fast (b)-style strong evidence per the task
// brief, and it must be net.infinite_timeout specifically, not
// net.no_timeout: see the long comment in dial() for why plain
// net.no_timeout (Duration 0) does NOT actually mean "block forever" in
// this vlib build (a first attempt at this fix used net.no_timeout and it
// made every post-dial read fail in microseconds — the companion
// behavioral test below is what caught it).
fn test_dial_clears_handshake_deadline() {
	mut l, addr := spawn_fake_proxy(handle_s5_noauth) or { panic(err) }
	defer {
		l.close() or {}
	}
	mut conn := dial(ClientConfig{ proxy_addr: addr }, '1.2.3.4:80')!
	defer {
		conn.close() or {}
	}
	assert conn.read_timeout() == net.infinite_timeout
	assert conn.write_timeout() == net.infinite_timeout
}

// test_dial_returned_conn_survives_short_idle is a behavioral companion to
// test_dial_clears_handshake_deadline: it does not merely inspect the
// timeout field, it actually idles on the returned connection past the
// point where a broken "clear" (e.g. net.no_timeout, which was tried and
// silently produced an immediate `net: op timed out` — see dial()'s
// comment) would already have failed. The fake proxy waits well past the
// handshake before writing anything on the tunnel; a correct fix blocks
// until then, a broken one errors out almost instantly.
fn test_dial_returned_conn_survives_short_idle() {
	idle_delay := 300 * time.millisecond
	handler := fn [idle_delay] (mut c net.TcpConn) {
		mut h := []u8{len: 2}
		c.read(mut h) or { return }
		mut methods := []u8{len: int(h[1])}
		c.read(mut methods) or { return }
		c.write(socks5.encode_method_select(socks5.method_no_auth)) or { return }
		mut req := []u8{len: 10}
		c.read(mut req) or { return }
		c.write(socks5.encode_reply(core.rep_success, socks5.Addr{
			atyp: .ipv4
			host: '0.0.0.0'
			port: 0
		})) or { return }
		// Handshake is done; idle past it before the tunnel carries data,
		// exactly like a long-poll caller would idle on the returned conn.
		time.sleep(idle_delay)
		c.write('late'.bytes()) or {}
	}
	mut l, addr := spawn_fake_proxy(handler) or { panic(err) }
	defer {
		l.close() or {}
	}
	mut conn := dial(ClientConfig{ proxy_addr: addr }, '1.2.3.4:80')!
	defer {
		conn.close() or {}
	}
	mut b := []u8{len: 16}
	n := conn.read(mut b)!
	assert b[..n] == 'late'.bytes()
}

// test_make_addr5_rejects_oversized_domain guards against a regression:
// encode_addr's domain arm casts the byte length to u8 with no bounds check,
// so a >255-byte domain name silently wrapped and corrupted the wire frame
// instead of erroring before ever reaching the wire.
fn test_make_addr5_rejects_oversized_domain() {
	long_host := 'a'.repeat(256)
	make_addr5(long_host, 80, .server_side) or {
		assert (err as core.SocksError).kind == .protocol_error
		assert err.msg().contains('too long')
		return
	}
	assert false
}

fn test_make_addr5_accepts_domain_at_limit() {
	host := 'a'.repeat(255)
	addr := make_addr5(host, 80, .server_side)!
	assert addr.atyp == .domain
	assert addr.host == host
}

// test_make_addr5_rejects_malformed_ipv6 guards against a regression: any
// host containing ':' used to be encoded as .ipv6 unconditionally, and
// encode_addr's ipv6 arm silently truncates/corrupts malformed literals
// instead of erroring.
fn test_make_addr5_rejects_malformed_ipv6() {
	make_addr5('1:2:3', 80, .server_side) or {
		assert (err as core.SocksError).kind == .protocol_error
		assert err.msg().contains('malformed')
		return
	}
	assert false
}

fn test_make_addr5_accepts_valid_ipv6() {
	full := make_addr5('2001:db8:0:0:0:0:0:1', 80, .server_side)!
	assert full.atyp == .ipv6
	compressed := make_addr5('2001:db8::1', 80, .server_side)!
	assert compressed.atyp == .ipv6
	loopback := make_addr5('::1', 80, .server_side)!
	assert loopback.atyp == .ipv6
}

// test_make_addr5_accepts_bare_double_colon guards against a regression: the
// bare '::' literal (RFC 4291's all-zero address, 0:0:0:0:0:0:0:0) must be
// accepted, not rejected as malformed.
fn test_make_addr5_accepts_bare_double_colon() {
	addr := make_addr5('::', 80, .server_side)!
	assert addr.atyp == .ipv6
}

// test_make_addr5_rejects_embedded_ipv4_form documents current, intentionally
// narrower-than-RFC-4291 behavior: is_ipv6 only accepts pure hex-group IPv6
// literals, not embedded-IPv4 forms like '::ffff:1.2.3.4'. This is
// coverage-only; that behavior should not change.
fn test_make_addr5_rejects_embedded_ipv4_form() {
	make_addr5('::ffff:1.2.3.4', 80, .server_side) or {
		assert err.msg().contains('malformed')
		return
	}
	assert false
}
