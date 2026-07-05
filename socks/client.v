module socks

import net
import time
import socks.core
import socks.socks5
import socks.socks4

const client_timeout = 30 * time.second

// dial connects through the proxy (speaking cfg.version) and returns a plain
// TCP connection to target_addr.
pub fn dial(cfg ClientConfig, target_addr string) !net.TcpConn {
	host, port := split_host_port(target_addr)!
	mut conn := net.dial_tcp(cfg.proxy_addr)!
	conn.set_read_timeout(client_timeout)
	conn.set_write_timeout(client_timeout)
	match cfg.version {
		.v5 {
			dial5(mut conn, cfg, host, port) or {
				conn.close() or {}
				return err
			}
		}
		.v4, .v4a {
			dial4(mut conn, cfg, host, port) or {
				conn.close() or {}
				return err
			}
		}
	}
	// The 30s client_timeout above only bounds the handshake itself. The
	// caller receives this connection as a plain data tunnel and may
	// legitimately idle on it far longer (long-poll, keep-alive, etc.), so
	// the deadline must not survive past this point.
	//
	// Deliberately net.infinite_timeout, NOT net.no_timeout: net.no_timeout
	// is Duration(0), which in vlib/net's wait_for_common falls back to
	// TcpConn's read_deadline/write_deadline time.Time fields. Those default
	// to the zero-valued time.Time{} — NOT the same instant as time.unix(0)
	// — because Time.unix() lazily recomputes from the (year:0, month:0,
	// day:0, ...) calendar fields via mktime when its private `unix` field
	// is itself still 0, yielding a huge negative timestamp (verified: -62169984000, i.e. deep in year 0) instead of 0. select_deadline's
	// `deadline.unix() == 0` "is this infinite?" check then reads false, and
	// the connection is treated as already past its deadline: every read
	// times out in microseconds instead of blocking (reproduced directly
	// against this vlib build; confirmed with -d net_nonblocking_sockets).
	// net.infinite_timeout instead hits wait_for_common's dedicated
	// `timeout == infinite_timeout` branch, which sets real_deadline to a
	// freshly constructed time.unix(0) (whose unix() does read back as 0),
	// bypassing the broken zero-value deadline fields entirely and blocking
	// for real.
	conn.set_read_timeout(net.infinite_timeout)
	conn.set_write_timeout(net.infinite_timeout)
	return *conn
}

fn dial5(mut conn net.TcpConn, cfg ClientConfig, host string, port u16) ! {
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
		if up.user.len > 255 || up.pass.len > 255 {
			return core.err(.protocol_error, 'socks: username/password must each be 255 bytes or fewer')
		}
		conn.write(socks5.encode_userpass(socks5.UserPass{ user: up.user, pass: up.pass }))!
		ok := socks5.parse_userpass_reply(read_exact(mut conn, 2)!)!
		if !ok {
			return core.err(.auth_failed, 'proxy rejected credentials')
		}
	}
	addr := make_addr5(host, port, cfg.resolve_mode)!
	conn.write(socks5.encode_request(socks5.Request{ command: .connect, addr: addr }))!
	rep := read_reply5(mut conn)!
	if rep.rep != core.rep_success {
		return core.err(core.code_from_rep(rep.rep), 'connect ${host}:${port}')
	}
}

fn dial4(mut conn net.TcpConn, cfg ClientConfig, host string, port u16) ! {
	mut req := socks4.Request{
		host: host
		port: port
	}
	if is_ipv4(host) {
		req = socks4.Request{
			host:  host
			port:  port
			is_4a: false
		}
	} else if cfg.version == .v4a && cfg.resolve_mode == .server_side {
		req = socks4.Request{
			host:  host
			port:  port
			is_4a: true
		}
	} else {
		// plain SOCKS4 (or client_side) cannot carry a domain: resolve locally.
		ip := resolve_ipv4(host, port)!
		req = socks4.Request{
			host:  ip
			port:  port
			is_4a: false
		}
	}
	conn.write(socks4.encode_request(req))!
	cd := socks4.parse_reply(read_exact(mut conn, 8)!)!
	if cd != core.cd_granted {
		return core.err(core.code_from_cd(cd), 'connect ${host}:${port}')
	}
}

// make_addr5 chooses the SOCKS5 address encoding for a target.
fn make_addr5(host string, port u16, mode ResolveMode) !socks5.Addr {
	if is_ipv4(host) {
		return socks5.Addr{
			atyp: .ipv4
			host: host
			port: port
		}
	}
	if host.contains(':') {
		// A ':' means IPv6 syntax was intended; reject outright rather than
		// falling through to encode it as a malformed literal or a "domain"
		// (domain names cannot contain ':') — encode_addr's ipv6 arm has no
		// validation of its own and would otherwise silently truncate/corrupt.
		if !is_ipv6(host) {
			return core.err(.protocol_error, 'socks: malformed IPv6 address ${host}')
		}
		return socks5.Addr{
			atyp: .ipv6
			host: host
			port: port
		}
	}
	if mode == .client_side {
		ip := resolve_ipv4(host, port)!
		return socks5.Addr{
			atyp: .ipv4
			host: ip
			port: port
		}
	}
	if host.len > 255 {
		// encode_addr's domain arm casts the byte length to u8; anything over
		// 255 bytes would silently wrap and corrupt the wire frame instead of
		// erroring.
		return core.err(.protocol_error, 'socks: domain name too long (${host.len} bytes, max 255): ${host}')
	}
	return socks5.Addr{
		atyp: .domain
		host: host
		port: port
	}
}

// read_reply5 reads a full VER REP RSV ATYP BND.ADDR BND.PORT reply.
fn read_reply5(mut conn net.TcpConn) !socks5.Reply {
	head := read_exact(mut conn, 4)!
	mut full := head.clone()
	match head[3] {
		0x01 {
			full << read_exact(mut conn, 4 + 2)!
		}
		0x04 {
			full << read_exact(mut conn, 16 + 2)!
		}
		0x03 {
			lb := read_exact(mut conn, 1)!
			full << lb
			full << read_exact(mut conn, int(lb[0]) + 2)!
		}
		else {
			return core.err(.protocol_error, 'reply: bad ATYP 0x${head[3]:02x}')
		}
	}
	return socks5.parse_reply(full)
}

// read_exact reads exactly n bytes or returns a protocol_error.
fn read_exact(mut conn net.TcpConn, n int) ![]u8 {
	mut buf := []u8{len: n}
	mut got := 0
	for got < n {
		// buf[got..] must be taken as an `unsafe` slice to get a view sharing
		// buf's backing array; a plain slice here is implicitly cloned by this
		// V version (confirmed via `v -keepc`: the plain form silently reads
		// into a throwaway copy, leaving buf zeroed), so conn.read must fill
		// this exact view for the bytes to land in buf.
		mut chunk := unsafe { buf[got..] }
		r := conn.read(mut chunk) or {
			if err.msg().contains('timed out') {
				return core.err_cause(.local_timeout, 'read deadline exceeded', err)
			}
			return core.err_cause(.protocol_error, 'short read', err)
		}
		if r <= 0 {
			return core.err(.protocol_error, 'unexpected EOF')
		}
		got += r
	}
	return buf
}

fn split_host_port(addr string) !(string, u16) {
	if addr.starts_with('[') {
		close := addr.index(']') or { return error('socks: bad address ${addr}') }
		rest := addr[close + 1..]
		if !rest.starts_with(':') {
			return error('socks: missing port in ${addr}')
		}
		return addr[1..close], rest[1..].u16()
	}
	i := addr.last_index(':') or { return error('socks: missing port in ${addr}') }
	return addr[..i], addr[i + 1..].u16()
}

fn is_ipv4(s string) bool {
	parts := s.split('.')
	if parts.len != 4 {
		return false
	}
	for p in parts {
		if p.len == 0 || p.len > 3 {
			return false
		}
		for c in p {
			if c < `0` || c > `9` {
				return false
			}
		}
		if p.int() > 255 {
			return false
		}
	}
	return true
}

// is_ipv6 validates a colon-containing host as a plausible IPv6 literal (full
// 8-group form, one '::' abbreviation, or the bare '::' all-zero form), to
// the same fidelity addr.v's ipv6_to_bytes/groups_to_bytes assume — it
// doesn't need full RFC 4291 coverage, just to reject shapes that would
// otherwise silently corrupt.
fn is_ipv6(s string) bool {
	dc_parts := s.split('::')
	if dc_parts.len > 2 {
		return false // more than one '::' is invalid
	}
	mut groups := []string{}
	if dc_parts.len == 2 {
		head := if dc_parts[0] == '' { []string{} } else { dc_parts[0].split(':') }
		tail := if dc_parts[1] == '' { []string{} } else { dc_parts[1].split(':') }
		if head.len + tail.len > 7 {
			return false // '::' must represent at least one omitted group
		}
		groups << head
		groups << tail
	} else {
		groups = s.split(':')
		if groups.len != 8 {
			return false
		}
	}
	for g in groups {
		if g.len == 0 || g.len > 4 {
			return false
		}
		for c in g {
			is_hex := (c >= `0` && c <= `9`) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
			if !is_hex {
				return false
			}
		}
	}
	return true
}

// resolve_ipv4 resolves a domain name to a dotted IPv4 string (client_side mode
// and plain-SOCKS4 domain targets).
fn resolve_ipv4(host string, port u16) !string {
	addrs := net.resolve_addrs('${host}:${port}', .ip, .tcp) or {
		return core.err_cause(.host_unreachable, 'resolve ${host}', err)
	}
	if addrs.len == 0 {
		return core.err(.host_unreachable, 'resolve ${host}: no addresses')
	}
	s := addrs[0].str() // "1.2.3.4:port"
	return s.all_before_last(':')
}
