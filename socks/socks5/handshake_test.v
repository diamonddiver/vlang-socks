module socks5

import socks.core

fn test_parse_hello() {
	buf := [u8(0x05), 2, 0x00, 0x02]
	h := parse_hello(buf)!
	assert h.methods == [u8(0x00), 0x02]
}

fn test_parse_hello_nmethods_zero_is_protocol_error() {
	buf := [u8(0x05), 0]
	parse_hello(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_parse_hello_truncated_methods() {
	buf := [u8(0x05), 3, 0x00] // claims 3, has 1
	parse_hello(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_parse_hello_bad_version() {
	buf := [u8(0x04), 1, 0x00]
	parse_hello(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_method_select_roundtrip() {
	enc := encode_method_select(method_user_pass)
	assert enc == [u8(0x05), 0x02]
	assert parse_method_select(enc)! == method_user_pass
}

fn test_userpass_roundtrip() {
	up := UserPass{
		user: 'alice'
		pass: 's3cr3t'
	}
	dec := parse_userpass(encode_userpass(up))!
	assert dec == up
}

fn test_userpass_empty_fields_valid() {
	up := UserPass{
		user: ''
		pass: ''
	}
	dec := parse_userpass(encode_userpass(up))!
	assert dec.user == ''
	assert dec.pass == ''
}

fn test_userpass_bad_subneg_version() {
	buf := [u8(0x02), 1, `a`, 1, `b`] // VER=2, not 1
	parse_userpass(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_userpass_truncated_password() {
	buf := [u8(0x01), 1, `a`, 5, `x`] // PLEN=5, only 1 byte
	parse_userpass(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_userpass_reply_roundtrip() {
	assert encode_userpass_reply(true) == [u8(0x01), 0x00]
	assert encode_userpass_reply(false) == [u8(0x01), 0x01]
	assert parse_userpass_reply([u8(0x01), 0x00])! == true
	assert parse_userpass_reply([u8(0x01), 0x01])! == false
}
