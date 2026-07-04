module socks5

import socks.core

fn test_parse_connect_request() {
	buf := [u8(0x05), 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50]
	r := parse_request(buf)!
	assert r.command == .connect
	assert r.addr.host == '127.0.0.1'
	assert r.addr.port == 80
}

fn test_request_roundtrip_domain() {
	r := Request{
		command: .udp_associate
		addr:    Addr{
			atyp: .domain
			host: 'proxy.local'
			port: 1080
		}
	}
	back := parse_request(encode_request(r))!
	assert back == r
}

fn test_parse_request_bad_command() {
	buf := [u8(0x05), 0x09, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
	parse_request(buf) or {
		assert (err as core.SocksError).kind == .command_not_supported
		return
	}
	assert false
}

fn test_parse_request_bad_atyp() {
	buf := [u8(0x05), 0x01, 0x00, 0x02, 0, 0]
	parse_request(buf) or {
		assert (err as core.SocksError).kind == .address_type_not_supported
		return
	}
	assert false
}

fn test_parse_request_bad_version() {
	buf := [u8(0x04), 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
	parse_request(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_parse_request_truncated_header() {
	buf := [u8(0x05), 0x01, 0x00] // no ATYP
	parse_request(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_reply_roundtrip() {
	addr := Addr{
		atyp: .ipv4
		host: '0.0.0.0'
		port: 0
	}
	enc := encode_reply(core.rep_success, addr)
	assert enc[0] == 0x05
	assert enc[1] == 0x00
	rep := parse_reply(enc)!
	assert rep.rep == 0x00
	assert rep.addr == addr
}

fn test_parse_reply_failure_code() {
	addr := Addr{
		atyp: .ipv4
		host: '0.0.0.0'
		port: 0
	}
	enc := encode_reply(core.rep_code(.host_unreachable), addr)
	rep := parse_reply(enc)!
	assert core.code_from_rep(rep.rep) == .host_unreachable
}
