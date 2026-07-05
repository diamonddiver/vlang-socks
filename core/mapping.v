module core

// Target is a resolve/connect destination handed from a state machine to the
// resolver pool. Neutral type so resolver need not import socks5/socks4.
pub struct Target {
pub:
	host string
	port u16
}

pub const rep_success = u8(0x00)
pub const cd_granted = u8(90)

// Action is what a per-connection state machine tells the event-loop driver to
// do after feeding it bytes: send `reply`, optionally `close`, optionally
// resolve+connect a `connect` target, or open a UDP relay (`udp_associate`).
pub struct Action {
pub mut:
	reply         []u8
	close         bool
	connect       ?Target
	udp_associate bool
}

// rep_code maps an error code to a SOCKS5 REP failure byte.
pub fn rep_code(kind SocksErrorCode) u8 {
	return match kind {
		.general_failure { u8(0x01) }
		.connection_not_allowed { u8(0x02) }
		.network_unreachable { u8(0x03) }
		.host_unreachable { u8(0x04) }
		.connection_refused { u8(0x05) }
		.ttl_expired { u8(0x06) }
		.command_not_supported { u8(0x07) }
		.address_type_not_supported { u8(0x08) }
		else { u8(0x01) } // local-only kinds default to general failure
	}
}

// code_from_rep maps a peer's SOCKS5 REP byte back to an error code.
pub fn code_from_rep(rep u8) SocksErrorCode {
	return match rep {
		0x01 { SocksErrorCode.general_failure }
		0x02 { SocksErrorCode.connection_not_allowed }
		0x03 { SocksErrorCode.network_unreachable }
		0x04 { SocksErrorCode.host_unreachable }
		0x05 { SocksErrorCode.connection_refused }
		0x06 { SocksErrorCode.ttl_expired }
		0x07 { SocksErrorCode.command_not_supported }
		0x08 { SocksErrorCode.address_type_not_supported }
		else { SocksErrorCode.general_failure }
	}
}

// cd_code maps an error code to a SOCKS4/4a CD byte. SOCKS4 has no finer
// granularity than "rejected or failed", so every failure collapses to 91.
pub fn cd_code(kind SocksErrorCode) u8 {
	return u8(91)
}

// code_from_cd maps a peer's SOCKS4 CD byte back to an error code.
pub fn code_from_cd(cd u8) SocksErrorCode {
	return SocksErrorCode.general_failure
}
