module socks4

import socks.core

fn build_v4(port u16, ip []u8, userid string) []u8 {
	mut b := [u8(0x04), 0x01, u8(port >> 8), u8(port & 0xff)]
	b << ip
	b << userid.bytes()
	b << u8(0)
	return b
}

fn test_parse_plain_socks4() {
	buf := build_v4(80, [u8(127), 0, 0, 1], 'me')
	r := parse_request(buf)!
	assert !r.is_4a
	assert r.host == '127.0.0.1'
	assert r.port == 80
	assert r.userid == 'me'
}

fn test_parse_socks4a() {
	mut buf := build_v4(443, [u8(0), 0, 0, 7], 'user') // 0.0.0.7 => 4a marker
	buf << 'example.com'.bytes()
	buf << u8(0)
	r := parse_request(buf)!
	assert r.is_4a
	assert r.host == 'example.com'
	assert r.port == 443
	assert r.userid == 'user'
}

fn test_userid_missing_nul_is_protocol_error() {
	// 300 non-NUL bytes after DSTIP: guard must trip, not read unbounded.
	mut buf := [u8(0x04), 0x01, 0, 80, 1, 2, 3, 4]
	for _ in 0 .. 300 {
		buf << u8(`x`)
	}
	parse_request(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_socks4a_domain_missing_nul_is_protocol_error() {
	mut buf := build_v4(443, [u8(0), 0, 0, 7], 'u')
	for _ in 0 .. 300 {
		buf << u8(`d`) // domain never NUL-terminated
	}
	parse_request(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_socks4a_marker_without_domain_is_protocol_error() {
	buf := build_v4(443, [u8(0), 0, 0, 9], 'u') // marker but no domain bytes
	parse_request(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_request_roundtrip_plain() {
	r := Request{
		host:   '10.1.2.3'
		port:   8080
		userid: 'x'
		is_4a:  false
	}
	back := parse_request(encode_request(r))!
	assert back == r
}

fn test_request_roundtrip_4a() {
	r := Request{
		host:   'proxy.test'
		port:   1080
		userid: ''
		is_4a:  true
	}
	back := parse_request(encode_request(r))!
	assert back == r
}

fn test_reply_roundtrip() {
	enc := encode_reply(core.cd_granted)
	assert enc.len == 8
	assert enc[0] == 0x00
	assert parse_reply(enc)! == core.cd_granted
}

fn test_parse_reply_bad_vn_is_protocol_error() {
	buf := [u8(1), core.cd_granted, 0, 0, 0, 0, 0, 0]
	parse_reply(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}
