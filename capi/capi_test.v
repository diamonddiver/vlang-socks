module capi

import net

// cs converts a V string literal to a C string pointer for exercising the
// socks_* functions the same way a C caller would. Safe here because V
// string data is always NUL-terminated.
fn cs(s string) &char {
	return unsafe { &char(s.str) }
}

// conn_from_fd wraps a raw fd (as returned by dial()) back into a usable
// net.TcpConn for the test's own read/write, mirroring what socks_dial's doc
// comment promises: the fd is a real, still-open connected socket. The
// timeouts must be set explicitly to net.infinite_timeout, not left at a
// freshly-constructed TcpConn's zero-valued default — see client.v's dial()
// doc comment for why the zero value makes reads/writes fail in
// microseconds on this vlib version.
fn conn_from_fd(fd int) net.TcpConn {
	mut c := net.TcpConn{
		sock:   net.tcp_socket_from_handle_raw(fd)
		handle: fd
	}
	c.set_read_timeout(net.infinite_timeout)
	c.set_write_timeout(net.infinite_timeout)
	return c
}

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

fn test_capi_server_start_dial_stop() {
	socks_init()
	mut echo, echo_addr := start_echo_target() or { panic(err) }
	defer {
		echo.close() or {}
	}

	id := server_start(cs(':0'), 0, cs(''), cs(''), true, 4, 4, false, 0, 0, 0, 0)
	assert id != 0
	defer {
		server_stop(id)
		server_wait(id)
	}

	addr := cstr(server_addr(id))
	assert addr.len > 0

	fd := dial(cs(addr), 4, 0, cs(''), cs(''), 0, cs(echo_addr))
	assert fd >= 0
	mut conn := conn_from_fd(fd)
	conn.write('hello capi'.bytes()) or { panic(err) }
	mut b := []u8{len: 32}
	n := conn.read(mut b) or { panic(err) }
	assert b[..n] == 'hello capi'.bytes()
	conn.close() or {}
}

fn test_capi_dial_invalid_version_sets_last_error() {
	fd := dial(cs('127.0.0.1:1'), 99, 0, cs(''), cs(''), 0, cs('example.com:80'))
	assert fd == -1
	assert last_error_code() != -1
}

fn test_capi_strerror_no_error() {
	assert cstr(strerror(-1)) == 'no error'
}

fn test_capi_udp_roundtrip() {
	socks_init()
	mut target := net.listen_udp('127.0.0.1:0') or { panic(err) }
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

	id := server_start(cs('127.0.0.1:0'), 0, cs(''), cs(''), true, 4, 4, false, 0, 0,
		0, 0)
	assert id != 0
	defer {
		server_stop(id)
		server_wait(id)
	}
	addr := cstr(server_addr(id))

	uid := udp_associate(cs(addr), 0, cs(''), cs(''), 0)
	assert uid != 0
	defer {
		udp_close(uid)
	}

	payload := 'ping'.bytes()
	sent := udp_write_to(uid, cs(taddr), payload.data, payload.len)
	assert sent == payload.len

	mut addr_buf := []u8{len: 64}
	mut data_buf := []u8{len: 2048}
	n := udp_read_from(uid, unsafe { &char(addr_buf.data) }, addr_buf.len, data_buf.data,
		data_buf.len)
	assert n == payload.len
	assert data_buf[..n] == payload
	got_addr := unsafe { cstring_to_vstring(&char(addr_buf.data)) }
	assert got_addr == taddr
}
