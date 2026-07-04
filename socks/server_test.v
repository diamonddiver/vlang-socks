module socks

import net

fn start_echo_target() !(&net.TcpListener, string) {
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

fn test_server_socks5_connect_echo() {
	mut echo, echo_addr := start_echo_target() or { panic(err) }
	defer {
		echo.close() or {}
	}
	mut h := spawn_serve(ServerConfig{
		addr:      '127.0.0.1:0'
		versions:  [.v5]
		allow_udp: false
	})!
	defer {
		h.stop()
		h.wait()
	}
	mut conn := dial(ClientConfig{ proxy_addr: h.addr(), version: .v5 }, echo_addr)!
	conn.write('xyz'.bytes())!
	mut b := []u8{len: 8}
	n := conn.read(mut b)!
	assert b[..n] == 'xyz'.bytes()
	conn.close()!
}

fn test_server_socks4_connect_echo() {
	mut echo, echo_addr := start_echo_target() or { panic(err) }
	defer {
		echo.close() or {}
	}
	mut h := spawn_serve(ServerConfig{
		addr:      '127.0.0.1:0'
		versions:  [.v4]
		allow_udp: false
	})!
	defer {
		h.stop()
		h.wait()
	}
	mut conn := dial(ClientConfig{ proxy_addr: h.addr(), version: .v4 }, echo_addr)!
	conn.write('hi4'.bytes())!
	mut b := []u8{len: 8}
	n := conn.read(mut b)!
	assert b[..n] == 'hi4'.bytes()
	conn.close()!
}

fn test_spawn_serve_rejects_bad_versions() {
	spawn_serve(ServerConfig{
		versions: [SocksVersion.v4a]
	}) or {
		assert err.msg().contains('.v4a requires .v4')
		return
	}
	assert false
}
