module socks5

import socks.core

fn test_parse_ipv4() {
	buf := [u8(0x01), 127, 0, 0, 1, 0x1f, 0x90] // 127.0.0.1:8080
	a, n := parse_addr(buf)!
	assert n == 7
	assert a.atyp == .ipv4
	assert a.host == '127.0.0.1'
	assert a.port == 8080
}

fn test_parse_domain() {
	name := 'example.com'.bytes()
	mut buf := [u8(0x03), u8(name.len)]
	buf << name
	buf << [u8(0x01), 0xbb] // 443
	a, n := parse_addr(buf)!
	assert n == buf.len
	assert a.atyp == .domain
	assert a.host == 'example.com'
	assert a.port == 443
}

fn test_parse_domain_zero_length_is_valid() {
	buf := [u8(0x03), 0, 0x00, 0x50] // empty host, port 80
	a, n := parse_addr(buf)!
	assert n == 4
	assert a.host == ''
	assert a.port == 80
}

fn test_parse_domain_overrun_is_protocol_error() {
	buf := [u8(0x03), 200, 0x01, 0x02] // claims 200 bytes, has none
	parse_addr(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_parse_bad_atyp_is_addr_not_supported() {
	buf := [u8(0x02), 0, 0]
	parse_addr(buf) or {
		assert (err as core.SocksError).kind == .address_type_not_supported
		return
	}
	assert false
}

fn test_parse_ipv6_roundtrip() {
	// ::1 port 53
	mut buf := [u8(0x04)]
	buf << []u8{len: 15}
	buf << u8(1)
	buf << [u8(0), 53]
	a, n := parse_addr(buf)!
	assert n == 19
	assert a.atyp == .ipv6
	assert a.port == 53
	re := encode_addr(a)
	assert re[1..17] == buf[1..17]
}

fn test_ipv6_hex_group_roundtrip() {
	// Exercises hex-letter groups (2001:0db8:...:0001), which a decimal-only
	// string parser would corrupt. Full 16-byte form, no '::' compression.
	raw := [u8(0x20), 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
	mut buf := [u8(0x04)]
	buf << raw
	buf << [u8(0), 53]
	a, _ := parse_addr(buf)!
	assert a.atyp == .ipv6
	re := encode_addr(a)
	assert re[1..17] == raw // 16 address bytes survive the hex round-trip
}

fn test_encode_ipv4_roundtrip() {
	a := Addr{
		atyp: .ipv4
		host: '10.0.0.5'
		port: 1080
	}
	enc := encode_addr(a)
	assert enc == [u8(0x01), 10, 0, 0, 5, 0x04, 0x38]
	back, n := parse_addr(enc)!
	assert n == enc.len
	assert back == a
}

fn test_encode_domain_roundtrip() {
	a := Addr{
		atyp: .domain
		host: 'v-lang.io'
		port: 9000
	}
	back, _ := parse_addr(encode_addr(a))!
	assert back == a
}
