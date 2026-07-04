module socks

import net
import socks.core
import socks.socks5

pub struct UdpSession {
mut:
	control    &net.TcpConn = unsafe { nil }
	udp        &net.UdpConn = unsafe { nil }
	relay_addr string
}

// udp_associate opens a SOCKS5 UDP association and returns a session whose
// write_to/read_from transparently wrap/unwrap the SOCKS5 UDP header.
pub fn udp_associate(cfg ClientConfig) !UdpSession {
	if cfg.version != .v5 {
		return error('socks: udp_associate requires SOCKS5 (set version to .v5)')
	}
	mut conn := net.dial_tcp(cfg.proxy_addr)!
	conn.set_read_timeout(client_timeout)
	conn.set_write_timeout(client_timeout)
	socks5_client_auth(mut conn, cfg) or {
		conn.close() or {}
		return err
	}
	req := socks5.Request{
		command: .udp_associate
		addr:    socks5.Addr{
			atyp: .ipv4
			host: '0.0.0.0'
			port: 0
		}
	}
	conn.write(socks5.encode_request(req)) or {
		conn.close() or {}
		return err
	}
	rep := read_reply5(mut conn) or {
		conn.close() or {}
		return err
	}
	if rep.rep != core.rep_success {
		conn.close() or {}
		return core.err(core.code_from_rep(rep.rep), 'udp associate')
	}
	// If the relay advertises 0.0.0.0, reuse the proxy host.
	mut rhost := rep.addr.host
	if rhost == '0.0.0.0' || rhost == '' {
		rhost, _ = split_host_port(cfg.proxy_addr)!
	}
	relay := '${rhost}:${rep.addr.port}'
	mut u := net.dial_udp(relay) or {
		conn.close() or {}
		return err
	}
	return UdpSession{
		control:    conn
		udp:        u
		relay_addr: relay
	}
}

pub fn (mut s UdpSession) write_to(addr string, data []u8) ! {
	host, port := split_host_port(addr)!
	a := make_addr5(host, port, .server_side)!
	s.udp.write(socks5.encode_udp_datagram(a, data))!
}

pub fn (mut s UdpSession) read_from() !(string, []u8) {
	mut buf := []u8{len: 65535}
	// UdpConn.read returns (int, Addr) — the SAME signature Task 20's server uses.
	// The client ignores the peer (it is always the relay) via `_`.
	n, _ := s.udp.read(mut buf)!
	dg := socks5.parse_udp_datagram(buf[..n])!
	return '${dg.addr.host}:${dg.addr.port}', dg.data
}

pub fn (mut s UdpSession) close() {
	s.udp.close() or {}
	s.control.close() or {}
}

// socks5_client_auth performs the method negotiation (+ optional user/pass)
// portion of a SOCKS5 client handshake. Shared by udp_associate; dial5 inlines
// the same sequence.
fn socks5_client_auth(mut conn net.TcpConn, cfg ClientConfig) ! {
	is_userpass := cfg.auth is UserPassAuth
	methods := if is_userpass {
		[socks5.method_user_pass]
	} else {
		[socks5.method_no_auth]
	}
	conn.write(socks5.encode_hello(methods))!
	sel := socks5.parse_method_select(read_exact(mut conn, 2)!)!
	if sel == socks5.method_none {
		return core.err(.auth_method_not_acceptable, 'proxy rejected all auth methods')
	}
	if sel == socks5.method_user_pass {
		up := cfg.auth as UserPassAuth
		conn.write(socks5.encode_userpass(socks5.UserPass{ user: up.user, pass: up.pass }))!
		ok := socks5.parse_userpass_reply(read_exact(mut conn, 2)!)!
		if !ok {
			return core.err(.auth_failed, 'proxy rejected credentials')
		}
	}
}
