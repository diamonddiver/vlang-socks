module socks

import net
import socks.core
import socks.socks5

// fake_udp_relay: control TCP does a no-auth SOCKS5 UDP ASSOCIATE handshake,
// then a real UDP socket echoes every datagram back verbatim.
fn fake_udp_relay(mut c net.TcpConn, relay_host string) {
	mut h := []u8{len: 2}
	c.read(mut h) or { return }
	mut methods := []u8{len: int(h[1])}
	c.read(mut methods) or { return }
	c.write(socks5.encode_method_select(socks5.method_no_auth)) or { return }
	mut req := []u8{len: 10}
	c.read(mut req) or { return }
	mut u := net.listen_udp('${relay_host}:0') or { return }
	// net.UdpConn has no `.addr()` (unlike TcpListener/TcpConn); the embedded
	// Socket.address() reads the bound local address via getsockname().
	uaddr := u.sock.address() or { return }
	host := uaddr.str().all_before_last(':')
	port := uaddr.str().all_after_last(':').u16()
	c.write(socks5.encode_reply(core.rep_success, socks5.Addr{ atyp: .ipv4, host: host, port: port })) or {
		return
	}
	spawn fn (mut u net.UdpConn) {
		for {
			mut b := []u8{len: 2048}
			n, peer := u.read(mut b) or { break }
			u.write_to(peer, b[..n]) or { break }
		}
	}(mut u)
	// keep control conn open until the client closes it
	mut sink := []u8{len: 1}
	c.read(mut sink) or {}
}

// fake_udp_relay_wildcard: identical to fake_udp_relay except the SOCKS5
// reply advertises the wildcard address 0.0.0.0 instead of the real bound
// host, mimicking a multi-homed server. The real UDP socket still binds to
// `relay_host` so datagrams can actually flow; only the advertised host in
// the reply differs. This exercises udp_associate's fallback that
// substitutes the proxy's own host when the relay reports 0.0.0.0/empty.
fn fake_udp_relay_wildcard(mut c net.TcpConn, relay_host string) {
	mut h := []u8{len: 2}
	c.read(mut h) or { return }
	mut methods := []u8{len: int(h[1])}
	c.read(mut methods) or { return }
	c.write(socks5.encode_method_select(socks5.method_no_auth)) or { return }
	mut req := []u8{len: 10}
	c.read(mut req) or { return }
	mut u := net.listen_udp('${relay_host}:0') or { return }
	uaddr := u.sock.address() or { return }
	port := uaddr.str().all_after_last(':').u16()
	c.write(socks5.encode_reply(core.rep_success, socks5.Addr{
		atyp: .ipv4
		host: '0.0.0.0'
		port: port
	})) or { return }
	spawn fn (mut u net.UdpConn) {
		for {
			mut b := []u8{len: 2048}
			n, peer := u.read(mut b) or { break }
			u.write_to(peer, b[..n]) or { break }
		}
	}(mut u)
	// keep control conn open until the client closes it
	mut sink := []u8{len: 1}
	c.read(mut sink) or {}
}

fn test_udp_associate_roundtrip() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := l.addr() or { panic(err) }.str()
	defer {
		l.close() or {}
	}
	spawn fn (mut l net.TcpListener) {
		mut c := l.accept() or { return }
		fake_udp_relay(mut c, '127.0.0.1')
	}(mut l)

	mut sess := udp_associate(ClientConfig{ proxy_addr: addr })!
	sess.write_to('9.9.9.9:53', 'query'.bytes())!
	who, data := sess.read_from()!
	assert data == 'query'.bytes()
	assert who == '9.9.9.9:53'
	sess.close()
}

// test_udp_associate_wildcard_relay_host_falls_back_to_proxy specifically
// exercises the branch in udp_associate that substitutes the proxy host
// when the relay's UDP ASSOCIATE reply advertises 0.0.0.0. The control
// listener (and the relay's real UDP socket) bind to 127.0.0.2 rather than
// 127.0.0.1: on Linux, sending a UDP packet to destination 0.0.0.0:<port> is
// silently kernel-routed to 127.0.0.1:<port> specifically (verified
// empirically; 127.0.0.2 does NOT receive it). Using 127.0.0.1 here would
// let the test pass even if the fallback logic in udp_client.v were deleted
// entirely, since the client's dial of the literal 0.0.0.0 address would
// still reach a relay bound on 127.0.0.1 by kernel accident. With 127.0.0.2,
// only a client that actually substitutes the proxy host (per
// cfg.proxy_addr) will dial the right address and complete the round trip;
// a client that dials 0.0.0.0 literally will time out / error instead.
fn test_udp_associate_wildcard_relay_host_falls_back_to_proxy() {
	mut l := net.listen_tcp(.ip, '127.0.0.2:0') or { panic(err) }
	addr := l.addr() or { panic(err) }.str()
	defer {
		l.close() or {}
	}
	spawn fn (mut l net.TcpListener) {
		mut c := l.accept() or { return }
		fake_udp_relay_wildcard(mut c, '127.0.0.2')
	}(mut l)

	mut sess := udp_associate(ClientConfig{ proxy_addr: addr })!
	sess.write_to('9.9.9.9:53', 'query'.bytes())!
	who, data := sess.read_from()!
	assert data == 'query'.bytes()
	assert who == '9.9.9.9:53'
	sess.close()
}

// test_udp_associate_sets_infinite_timeout guards against a regression: the
// client-side UDP socket used to be left at vlib's short default read/write
// timeout, causing read_from() to spuriously time out on any round trip
// slower than that default — the same class of bug already fixed for the TCP
// tunnel in client.v's dial() and for the server-side sockets in server.v/
// server_udp.v.
fn test_udp_associate_sets_infinite_timeout() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := l.addr() or { panic(err) }.str()
	defer {
		l.close() or {}
	}
	spawn fn (mut l net.TcpListener) {
		mut c := l.accept() or { return }
		fake_udp_relay(mut c, '127.0.0.1')
	}(mut l)

	mut sess := udp_associate(ClientConfig{ proxy_addr: addr })!
	defer {
		sess.close()
	}
	assert sess.udp.read_timeout() == net.infinite_timeout
	assert sess.udp.write_timeout() == net.infinite_timeout
}

// test_udp_associate_honors_resolve_mode guards against a regression:
// write_to() used to hardcode ResolveMode.server_side regardless of what the
// caller configured, silently discarding cfg.resolve_mode once the session
// was built.
fn test_udp_associate_honors_resolve_mode() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := l.addr() or { panic(err) }.str()
	defer {
		l.close() or {}
	}
	spawn fn (mut l net.TcpListener) {
		mut c := l.accept() or { return }
		fake_udp_relay(mut c, '127.0.0.1')
	}(mut l)

	mut sess := udp_associate(ClientConfig{ proxy_addr: addr, resolve_mode: .client_side })!
	defer {
		sess.close()
	}
	assert sess.resolve_mode == .client_side
}

fn test_udp_associate_requires_v5() {
	udp_associate(ClientConfig{ proxy_addr: '127.0.0.1:1', version: .v4 }) or {
		assert err.msg().contains('SOCKS5')
		return
	}
	assert false
}

// fake_proxy_userpass_select: a minimal SOCKS5 proxy stub that only performs
// method negotiation (selecting user/pass auth) and then blocks, waiting for
// the control connection to close. Local to this file because
// client_test.v's spawn_fake_proxy/handle_s5_userpass helpers are not
// visible here: `v test` compiles each _test.v file as its own program
// alongside the module's non-test sources, not alongside sibling _test.v
// files.
fn fake_proxy_userpass_select(mut c net.TcpConn) {
	mut h := []u8{len: 2}
	c.read(mut h) or { return }
	mut methods := []u8{len: int(h[1])}
	c.read(mut methods) or { return }
	c.write(socks5.encode_method_select(socks5.method_user_pass)) or { return }
	mut sink := []u8{len: 1}
	c.read(mut sink) or {}
}

// test_udp_associate_rejects_oversized_username guards against a regression:
// socks5_client_auth's inlined userpass-length check (a separate copy of the
// same logic dial5 has) must reject a >255-byte credential before ever
// reaching the wire.
fn test_udp_associate_rejects_oversized_username() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := l.addr() or { panic(err) }.str()
	defer {
		l.close() or {}
	}
	spawn fn (mut l net.TcpListener) {
		mut c := l.accept() or { return }
		fake_proxy_userpass_select(mut c)
	}(mut l)
	long_user := 'u'.repeat(256)
	cfg := ClientConfig{
		proxy_addr: addr
		version:    .v5
		auth:       user_pass_auth(long_user, 'p')
	}
	udp_associate(cfg) or {
		assert (err as core.SocksError).kind == .protocol_error
		assert err.msg().contains('255')
		return
	}
	assert false
}
