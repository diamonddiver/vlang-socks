module socks

import net
import picoev
import socks.core
import socks.resolver
import socks.socks5

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

// A resolver pool whose job queue is full (all workers stuck on slow/dead
// targets) must not let apply() block the whole event loop on submit(): the
// client should get an immediate SOCKS5 failure reply instead of a hang.
fn test_apply_replies_failure_when_resolver_queue_full() {
	mut pv := picoev.new(picoev.Config{
		port:   0
		family: .ip
	})!
	mut srv := &Server{
		pool: resolver.new_for_test(1)
	}
	// Fills the cap-1 queue; no worker drains it (new_for_test spawns none),
	// so the next submit has no room.
	srv.pool.submit(resolver.Job{
		id:     999
		target: core.Target{
			host: '10.0.0.1'
			port: 80
		}
	})

	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	addr := l.addr()!.str()
	mut proxy_side := net.dial_tcp(addr)!
	mut client_side := l.accept()!
	l.close() or {}

	fd := proxy_side.sock.handle
	mut r := &Relay{
		client:    proxy_side
		client_fd: fd
		fam:       .socks5
		m5:        &socks5.Conn5{
			stage: .request
		}
	}
	pv_add(mut pv, fd)

	act := core.Action{
		connect: core.Target{
			host: '1.2.3.4'
			port: 80
		}
	}
	srv.apply(mut pv, mut r, act)

	mut b := []u8{len: 16}
	n := client_side.read(mut b)!
	assert b[0] == 0x05 // VER
	assert b[1] != 0x00 // REP: must NOT report success
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
