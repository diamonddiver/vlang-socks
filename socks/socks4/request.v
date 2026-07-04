module socks4

import socks.core

pub const socks4_version = u8(0x04)
pub const cmd_connect = u8(0x01)
pub const max_userid = 256
pub const max_domain = 256

pub struct Request {
pub:
	host   string // dotted IPv4 (plain) or domain name (4a)
	port   u16
	userid string
	is_4a  bool
}

// scan_cstr returns (string, index-after-NUL) for a NUL-terminated field
// starting at `start`, or an error if no NUL appears within `max` bytes.
fn scan_cstr(buf []u8, start int, max int, what string) !(string, int) {
	mut i := start
	end := if start + max < buf.len { start + max } else { buf.len }
	for i < end {
		if buf[i] == 0 {
			return buf[start..i].bytestr(), i + 1
		}
		i++
	}
	return core.err(.protocol_error, 'socks4: unterminated ${what}')
}

// parse_request decodes VN CD DSTPORT DSTIP USERID NUL [DOMAIN NUL].
pub fn parse_request(buf []u8) !Request {
	if buf.len < 9 {
		return core.err(.protocol_error, 'socks4: request too short')
	}
	if buf[0] != socks4_version {
		return core.err(.protocol_error, 'socks4: bad version 0x${buf[0]:02x}')
	}
	if buf[1] != cmd_connect {
		return core.err(.command_not_supported, 'socks4: CD 0x${buf[1]:02x}')
	}
	port := u16(buf[2]) << 8 | u16(buf[3])
	ip0, ip1, ip2, ip3 := buf[4], buf[5], buf[6], buf[7]
	userid, after_userid := scan_cstr(buf, 8, max_userid, 'USERID')!
	// SOCKS4a marker: first three octets 0, last non-zero.
	is_4a := ip0 == 0 && ip1 == 0 && ip2 == 0 && ip3 != 0
	if is_4a {
		domain, _ := scan_cstr(buf, after_userid, max_domain, 'domain')!
		if domain.len == 0 {
			return core.err(.protocol_error, 'socks4a: empty domain')
		}
		return Request{
			host:   domain
			port:   port
			userid: userid
			is_4a:  true
		}
	}
	return Request{
		host:   '${ip0}.${ip1}.${ip2}.${ip3}'
		port:   port
		userid: userid
		is_4a:  false
	}
}

pub fn encode_request(r Request) []u8 {
	mut out := [socks4_version, cmd_connect, u8(r.port >> 8), u8(r.port & 0xff)]
	if r.is_4a {
		out << [u8(0), 0, 0, 1] // 0.0.0.1 marker
		out << r.userid.bytes()
		out << u8(0)
		out << r.host.bytes()
		out << u8(0)
	} else {
		for p in r.host.split('.') {
			out << u8(p.u16())
		}
		out << r.userid.bytes()
		out << u8(0)
	}
	return out
}

// encode_reply builds VN=0 CD DSTPORT(2)=0 DSTIP(4)=0.
pub fn encode_reply(cd u8) []u8 {
	return [u8(0), cd, 0, 0, 0, 0, 0, 0]
}

pub fn parse_reply(buf []u8) !u8 {
	if buf.len < 8 {
		return core.err(.protocol_error, 'socks4: reply too short')
	}
	return buf[1]
}
