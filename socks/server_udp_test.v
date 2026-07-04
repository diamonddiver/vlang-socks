module socks

import net

fn test_server_udp_associate_roundtrip() {
	mut target := net.listen_udp('127.0.0.1:0') or { panic(err) }
	// net.UdpConn has no `.addr()` (unlike TcpListener/TcpConn); the embedded
	// Socket.address() reads the bound local address via getsockname() (same
	// correction as Task 19's fake_udp_relay test helper).
	taddr := target.sock.address() or { panic(err) }.str()
	defer {
		target.close() or {}
	}
	spawn fn (mut u net.UdpConn) {
		for {
			mut b := []u8{len: 2048}
			n, peer := u.read(mut b) or { break }
			u.write_to(peer, b[..n]) or { break }
		}
	}(mut target)

	mut h := spawn_serve(ServerConfig{
		addr:      '127.0.0.1:0'
		versions:  [.v5]
		allow_udp: true
	})!
	defer {
		h.stop()
		h.wait()
	}
	mut sess := udp_associate(ClientConfig{ proxy_addr: h.addr() })!
	sess.write_to(taddr, 'ping'.bytes())!
	who, data := sess.read_from()!
	assert data == 'ping'.bytes()
	assert who == taddr
	sess.close()
}
