module socks5

import socks.core

fn test_udp_roundtrip() {
	addr := Addr{
		atyp: .ipv4
		host: '8.8.8.8'
		port: 53
	}
	payload := [u8(1), 2, 3, 4]
	enc := encode_udp_datagram(addr, payload)
	assert enc[0] == 0 && enc[1] == 0 // RSV
	assert enc[2] == 0 // FRAG
	dg := parse_udp_datagram(enc)!
	assert dg.addr == addr
	assert dg.data == payload
}

fn test_udp_frag_low_rejected() {
	addr := Addr{
		atyp: .ipv4
		host: '1.1.1.1'
		port: 53
	}
	mut buf := encode_udp_datagram(addr, [u8(9)])
	buf[2] = 0x01 // FRAG=1
	parse_udp_datagram(buf) or {
		assert (err as core.SocksError).kind == .fragmentation_not_supported
		return
	}
	assert false
}

fn test_udp_frag_high_bit_rejected() {
	addr := Addr{
		atyp: .ipv4
		host: '1.1.1.1'
		port: 53
	}
	mut buf := encode_udp_datagram(addr, [u8(9)])
	buf[2] = 0x80 // end-of-sequence marker
	parse_udp_datagram(buf) or {
		assert (err as core.SocksError).kind == .fragmentation_not_supported
		return
	}
	assert false
}

fn test_udp_truncated_header() {
	parse_udp_datagram([u8(0), 0, 0]) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}
