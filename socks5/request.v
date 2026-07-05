module socks5

import socks.core

pub enum Command {
	connect       = 0x01
	bind          = 0x02
	udp_associate = 0x03
}

pub struct Request {
pub:
	command Command
	addr    Addr
}

// parse_request decodes VER CMD RSV ATYP DST.ADDR DST.PORT.
pub fn parse_request(buf []u8) !Request {
	if buf.len < 4 {
		return core.err(.protocol_error, 'request: too short')
	}
	if buf[0] != socks5_version {
		return core.err(.protocol_error, 'request: bad version 0x${buf[0]:02x}')
	}
	command := match buf[1] {
		0x01 { Command.connect }
		0x02 { Command.bind }
		0x03 { Command.udp_associate }
		else { return core.err(.command_not_supported, 'request: CMD 0x${buf[1]:02x}') }
	}
	// buf[2] is RSV (ignored). Address starts at buf[3].
	addr, _ := parse_addr(buf[3..])!
	return Request{
		command: command
		addr:    addr
	}
}

pub fn encode_request(r Request) []u8 {
	mut out := [socks5_version, u8(r.command), u8(0x00)]
	out << encode_addr(r.addr)
	return out
}

pub struct Reply {
pub:
	rep  u8
	addr Addr
}

// encode_reply builds VER REP RSV ATYP BND.ADDR BND.PORT.
pub fn encode_reply(rep u8, addr Addr) []u8 {
	mut out := [socks5_version, rep, u8(0x00)]
	out << encode_addr(addr)
	return out
}

pub fn parse_reply(buf []u8) !Reply {
	if buf.len < 4 {
		return core.err(.protocol_error, 'reply: too short')
	}
	if buf[0] != socks5_version {
		return core.err(.protocol_error, 'reply: bad version 0x${buf[0]:02x}')
	}
	rep := buf[1]
	addr, _ := parse_addr(buf[3..])!
	return Reply{
		rep:  rep
		addr: addr
	}
}
