module socks

import net
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
