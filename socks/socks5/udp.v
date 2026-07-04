module socks5

import socks.core

pub struct UdpDatagram {
pub:
	addr Addr
	data []u8
}

// parse_udp_datagram decodes RSV(2) FRAG ATYP DST.ADDR DST.PORT DATA.
pub fn parse_udp_datagram(buf []u8) !UdpDatagram {
	if buf.len < 4 {
		return core.err(.protocol_error, 'udp: header too short')
	}
	// buf[0], buf[1] = RSV (must be 0, ignored on read).
	frag := buf[2]
	if frag != 0x00 {
		return core.err(.fragmentation_not_supported, 'udp: FRAG=0x${frag:02x}')
	}
	addr, consumed := parse_addr(buf[3..])!
	data := buf[3 + consumed..].clone()
	return UdpDatagram{
		addr: addr
		data: data
	}
}

// encode_udp_datagram builds RSV(2)=0 FRAG=0 ATYP ADDR PORT DATA.
pub fn encode_udp_datagram(addr Addr, data []u8) []u8 {
	mut out := [u8(0), 0, 0] // RSV, RSV, FRAG
	out << encode_addr(addr)
	out << data
	return out
}
