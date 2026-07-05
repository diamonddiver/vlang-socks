module socks5

import socks.core

pub const socks5_version = u8(0x05)
pub const method_no_auth = u8(0x00)
pub const method_user_pass = u8(0x02)
pub const method_none = u8(0xff)
pub const userpass_version = u8(0x01)
pub const userpass_ok = u8(0x00)
pub const userpass_fail = u8(0x01)

pub struct Hello {
pub:
	methods []u8
}

// parse_hello decodes VER NMETHODS METHODS...
pub fn parse_hello(buf []u8) !Hello {
	if buf.len < 2 {
		return core.err(.protocol_error, 'hello: too short')
	}
	if buf[0] != socks5_version {
		return core.err(.protocol_error, 'hello: bad version 0x${buf[0]:02x}')
	}
	nmethods := int(buf[1])
	if nmethods == 0 {
		return core.err(.protocol_error, 'hello: NMETHODS=0')
	}
	if buf.len < 2 + nmethods {
		return core.err(.protocol_error, 'hello: truncated method list')
	}
	return Hello{
		methods: buf[2..2 + nmethods].clone()
	}
}

pub fn encode_hello(methods []u8) []u8 {
	mut out := [socks5_version, u8(methods.len)]
	out << methods
	return out
}

// encode_method_select encodes the server's chosen method (VER METHOD).
pub fn encode_method_select(method u8) []u8 {
	return [socks5_version, method]
}

pub fn parse_method_select(buf []u8) !u8 {
	if buf.len < 2 {
		return core.err(.protocol_error, 'method select: too short')
	}
	if buf[0] != socks5_version {
		return core.err(.protocol_error, 'method select: bad version')
	}
	return buf[1]
}

pub struct UserPass {
pub:
	user string
	pass string
}

// parse_userpass decodes VER ULEN UNAME PLEN PASSWD (RFC 1929).
pub fn parse_userpass(buf []u8) !UserPass {
	if buf.len < 2 {
		return core.err(.protocol_error, 'userpass: too short')
	}
	if buf[0] != userpass_version {
		return core.err(.protocol_error, 'userpass: bad subneg version 0x${buf[0]:02x}')
	}
	ulen := int(buf[1])
	if buf.len < 2 + ulen + 1 {
		return core.err(.protocol_error, 'userpass: truncated username')
	}
	user := buf[2..2 + ulen].bytestr()
	plen := int(buf[2 + ulen])
	poff := 2 + ulen + 1
	if buf.len < poff + plen {
		return core.err(.protocol_error, 'userpass: truncated password')
	}
	pass := buf[poff..poff + plen].bytestr()
	return UserPass{
		user: user
		pass: pass
	}
}

pub fn encode_userpass(up UserPass) []u8 {
	u := up.user.bytes()
	p := up.pass.bytes()
	mut out := [userpass_version, u8(u.len)]
	out << u
	out << u8(p.len)
	out << p
	return out
}

pub fn encode_userpass_reply(success bool) []u8 {
	return [userpass_version, if success {
		userpass_ok
	} else {
		userpass_fail
	}]
}

pub fn parse_userpass_reply(buf []u8) !bool {
	if buf.len < 2 {
		return core.err(.protocol_error, 'userpass reply: too short')
	}
	if buf[0] != userpass_version {
		return core.err(.protocol_error, 'userpass reply: bad version')
	}
	return buf[1] == userpass_ok
}
