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
// when the relay's UDP ASSOCIATE reply advertises 0.0.0.0. The relay here
// still really binds to 127.0.0.1 (so the round trip can succeed at all),
// but reports 0.0.0.0 in the reply; proxy_addr is 127.0.0.1:<port>, so the
// client must fall back to 127.0.0.1 to dial the actual relay socket. If the
// fallback logic were broken (e.g. dialing 0.0.0.0 literally, or using the
// wrong host), the round trip below would fail or time out.
fn test_udp_associate_wildcard_relay_host_falls_back_to_proxy() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := l.addr() or { panic(err) }.str()
	defer {
		l.close() or {}
	}
	spawn fn (mut l net.TcpListener) {
		mut c := l.accept() or { return }
		fake_udp_relay_wildcard(mut c, '127.0.0.1')
	}(mut l)

	mut sess := udp_associate(ClientConfig{ proxy_addr: addr })!
	sess.write_to('9.9.9.9:53', 'query'.bytes())!
	who, data := sess.read_from()!
	assert data == 'query'.bytes()
	assert who == '9.9.9.9:53'
	sess.close()
}

fn test_udp_associate_requires_v5() {
	udp_associate(ClientConfig{ proxy_addr: '127.0.0.1:1', version: .v4 }) or {
		assert err.msg().contains('SOCKS5')
		return
	}
	assert false
}
