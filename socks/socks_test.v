module socks

import net
import time
import socks.core
import socks.socks5

fn echo_tcp() !(&net.TcpListener, string) {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	addr := l.addr()!.str()
	spawn fn (mut l net.TcpListener) {
		for {
			mut c := l.accept() or { return }
			spawn fn (mut c net.TcpConn) {
				for {
					mut b := []u8{len: 256}
					n := c.read(mut b) or { break }
					if n == 0 {
						break
					}
					c.write(b[..n]) or { break }
				}
				c.close() or {}
			}(mut c)
		}
	}(mut l)
	return l, addr
}

fn echo_udp() !(&net.UdpConn, string) {
	mut u := net.listen_udp('127.0.0.1:0')!
	// net.UdpConn has no `.addr()` (unlike TcpListener/TcpConn); the embedded
	// Socket.address() reads the bound local address via getsockname() (same
	// correction Task 19/20 applied in their own test/production helpers).
	addr := u.sock.address()!.str()
	spawn fn (mut u net.UdpConn) {
		for {
			mut b := []u8{len: 2048}
			n, peer := u.read(mut b) or { break }
			u.write_to(peer, b[..n]) or { break }
		}
	}(mut u)
	return u, addr
}

fn test_socks5_userpass_correct_and_incorrect() {
	mut echo, echo_addr := echo_tcp() or { panic(err) }
	defer {
		echo.close() or {}
	}
	mut h := spawn_serve(ServerConfig{
		addr:      '127.0.0.1:0'
		versions:  [.v5]
		allow_udp: false
		auth:      user_pass_auth('agent', 'hunter2')
	})!
	defer {
		h.stop()
		h.wait()
	}
	// correct credentials
	mut conn := dial(ClientConfig{
		proxy_addr: h.addr()
		version:    .v5
		auth:       user_pass_auth('agent', 'hunter2')
	}, echo_addr)!
	conn.write('ok'.bytes())!
	mut b := []u8{len: 8}
	n := conn.read(mut b)!
	assert b[..n] == 'ok'.bytes()
	conn.close()!
	// incorrect credentials
	dial(ClientConfig{
		proxy_addr: h.addr()
		version:    .v5
		auth:       user_pass_auth('agent', 'WRONG')
	}, echo_addr) or {
		assert (err as core.SocksError).kind == .auth_failed
		return
	}
	assert false
}

fn test_socks4a_domain() {
	mut echo, echo_addr := echo_tcp() or { panic(err) }
	defer {
		echo.close() or {}
	}
	port := echo_addr.all_after_last(':')
	mut h := spawn_serve(ServerConfig{
		addr:      '127.0.0.1:0'
		versions:  [.v4, .v4a]
		allow_udp: false
	})!
	defer {
		h.stop()
		h.wait()
	}
	// SOCKS4a sends the domain 'localhost'; the server resolves it to 127.0.0.1.
	mut conn := dial(ClientConfig{
		proxy_addr: h.addr()
		version:    .v4a
	}, 'localhost:${port}')!
	conn.write('4a'.bytes())!
	mut b := []u8{len: 8}
	n := conn.read(mut b)!
	assert b[..n] == '4a'.bytes()
	conn.close()!
}

fn test_udp_teardown_after_control_close() {
	mut target, taddr := echo_udp() or { panic(err) }
	defer {
		target.close() or {}
	}
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
	sess.write_to(taddr, 'a'.bytes())!
	_, first := sess.read_from()!
	assert first == 'a'.bytes()
	// Close only the control TCP connection: the server must tear down the relay.
	sess.control.close() or {}
	time.sleep(150 * time.millisecond)
	sess.udp.set_read_timeout(500 * time.millisecond)
	sess.write_to(taddr, 'b'.bytes()) or {}
	sess.read_from() or {
		// bounded timeout / error => relay was torn down, no hang
		sess.udp.close() or {}
		return
	}
	assert false
}

fn test_udp_fragmented_datagram_dropped_by_live_relay() {
	mut target, taddr := echo_udp() or { panic(err) }
	defer {
		target.close() or {}
	}
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
	thost := taddr.all_before_last(':')
	tport := taddr.all_after_last(':').u16()
	// Hand-build a FRAG != 0 datagram and send it raw to the relay.
	mut frag := socks5.encode_udp_datagram(socks5.Addr{ atyp: .ipv4, host: thost, port: tport },
		'DROP'.bytes())
	frag[2] = 0x01 // FRAG = 1
	sess.udp.write(frag)!
	// Follow with a valid datagram; only this one may round-trip.
	sess.write_to(taddr, 'OK'.bytes())!
	sess.udp.set_read_timeout(1 * time.second)
	_, data := sess.read_from()!
	assert data == 'OK'.bytes() // never 'DROP' — the relay dropped the fragment
	sess.close()
}

fn test_connect_refused_port() {
	mut h := spawn_serve(ServerConfig{
		addr:      '127.0.0.1:0'
		versions:  [.v5]
		allow_udp: false
	})!
	defer {
		h.stop()
		h.wait()
	}
	// 127.0.0.1:1 refuses.
	dial(ClientConfig{ proxy_addr: h.addr(), version: .v5 }, '127.0.0.1:1') or {
		assert (err as core.SocksError).kind in [core.SocksErrorCode.connection_refused,
			.host_unreachable, .general_failure]
		return
	}
	assert false
}
