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

fn test_udp_associate_requires_v5() {
	udp_associate(ClientConfig{ proxy_addr: '127.0.0.1:1', version: .v4 }) or {
		assert err.msg().contains('SOCKS5')
		return
	}
	assert false
}
