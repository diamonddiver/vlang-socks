module socks5

import socks.core

pub enum AddrType {
	ipv4   = 0x01
	domain = 0x03
	ipv6   = 0x04
}

pub struct Addr {
pub:
	atyp AddrType
	host string
	port u16
}

pub fn (a Addr) target() core.Target {
	return core.Target{
		host: a.host
		port: a.port
	}
}

// parse_addr decodes ATYP + address + 2-byte port beginning at buf[0].
// Returns the decoded Addr and the number of bytes consumed.
pub fn parse_addr(buf []u8) !(Addr, int) {
	if buf.len < 1 {
		return core.err(.protocol_error, 'address: empty buffer')
	}
	atyp := buf[0]
	match atyp {
		0x01 {
			if buf.len < 7 {
				return core.err(.protocol_error, 'address: truncated IPv4')
			}
			host := '${buf[1]}.${buf[2]}.${buf[3]}.${buf[4]}'
			port := u16(buf[5]) << 8 | u16(buf[6])
			return Addr{
				atyp: .ipv4
				host: host
				port: port
			}, 7
		}
		0x03 {
			if buf.len < 2 {
				return core.err(.protocol_error, 'address: truncated domain length')
			}
			dlen := int(buf[1])
			need := 2 + dlen + 2
			if buf.len < need {
				return core.err(.protocol_error, 'address: domain overruns buffer')
			}
			host := buf[2..2 + dlen].bytestr()
			port := u16(buf[2 + dlen]) << 8 | u16(buf[2 + dlen + 1])
			return Addr{
				atyp: .domain
				host: host
				port: port
			}, need
		}
		0x04 {
			if buf.len < 19 {
				return core.err(.protocol_error, 'address: truncated IPv6')
			}
			host := ipv6_from_bytes(buf[1..17])
			port := u16(buf[17]) << 8 | u16(buf[18])
			return Addr{
				atyp: .ipv6
				host: host
				port: port
			}, 19
		}
		else {
			return core.err(.address_type_not_supported, 'bad ATYP 0x${atyp:02x}')
		}
	}
}

// encode_addr serializes ATYP + address + 2-byte port.
pub fn encode_addr(a Addr) []u8 {
	mut out := []u8{}
	match a.atyp {
		.ipv4 {
			out << 0x01
			for p in a.host.split('.') {
				out << u8(p.u16())
			}
		}
		.domain {
			out << 0x03
			name := a.host.bytes()
			out << u8(name.len)
			out << name
		}
		.ipv6 {
			out << 0x04
			out << ipv6_to_bytes(a.host)
		}
	}
	out << u8(a.port >> 8)
	out << u8(a.port & 0xff)
	return out
}

// ipv6_from_bytes renders 16 bytes as 8 colon-separated hex groups.
fn ipv6_from_bytes(b []u8) string {
	mut groups := []string{}
	for i := 0; i < 16; i += 2 {
		g := u16(b[i]) << 8 | u16(b[i + 1])
		groups << g.hex()
	}
	return groups.join(':')
}

// ipv6_to_bytes parses an IPv6 text address (full form or one '::') to 16 bytes.
fn ipv6_to_bytes(s string) []u8 {
	if s.contains('::') {
		parts := s.split('::')
		head := if parts[0] == '' { []string{} } else { parts[0].split(':') }
		tail := if parts.len < 2 || parts[1] == '' { []string{} } else { parts[1].split(':') }
		mut groups := []string{}
		groups << head
		for _ in 0 .. (8 - head.len - tail.len) {
			groups << '0'
		}
		groups << tail
		return groups_to_bytes(groups)
	}
	return groups_to_bytes(s.split(':'))
}

fn groups_to_bytes(groups []string) []u8 {
	mut out := []u8{cap: 16}
	for g in groups {
		v := parse_hex_group(g)
		out << u8(v >> 8)
		out << u8(v & 0xff)
	}
	for out.len < 16 {
		out << 0
	}
	return out[..16]
}

// parse_hex_group parses up to 4 hex nibbles into a u16. Done by hand rather
// than via `('0x' + g).u32()` because V's string-to-int helpers do not reliably
// honor a `0x` prefix across versions (some parse decimal and stop at 'x',
// silently yielding 0 and corrupting the address).
fn parse_hex_group(g string) u16 {
	mut v := u16(0)
	for c in g {
		d := if c >= `0` && c <= `9` {
			u16(c - `0`)
		} else if c >= `a` && c <= `f` {
			u16(c - `a` + 10)
		} else if c >= `A` && c <= `F` {
			u16(c - `A` + 10)
		} else {
			u16(0)
		}
		v = (v << 4) | d
	}
	return v
}
