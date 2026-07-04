module socks

import socks.core

fn test_dispatch_socks5() {
	f := dispatch_family(0x05, ServerConfig{})!
	assert f == .socks5
}

fn test_dispatch_socks4() {
	f := dispatch_family(0x04, ServerConfig{})!
	assert f == .socks4
}

fn test_dispatch_unknown_byte_is_protocol_error() {
	dispatch_family(0x07, ServerConfig{}) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_dispatch_socks5_disabled() {
	cfg := ServerConfig{
		versions: [SocksVersion.v4]
	}
	dispatch_family(0x05, cfg) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}

fn test_dispatch_socks4_disabled() {
	cfg := ServerConfig{
		versions: [SocksVersion.v5]
	}
	dispatch_family(0x04, cfg) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}
