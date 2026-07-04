module socks

import socks.core

enum ProtoFamily {
	socks4
	socks5
}

// dispatch_family selects the protocol handler from the first byte, honoring
// the enabled-versions config. Unknown byte / disabled family => protocol_error.
fn dispatch_family(first u8, cfg ServerConfig) !ProtoFamily {
	if first == 0x05 {
		if SocksVersion.v5 !in cfg.versions {
			return core.err(.protocol_error, 'socks5 not enabled')
		}
		return .socks5
	}
	if first == 0x04 {
		if SocksVersion.v4 !in cfg.versions && SocksVersion.v4a !in cfg.versions {
			return core.err(.protocol_error, 'socks4 not enabled')
		}
		return .socks4
	}
	return core.err(.protocol_error, 'unknown version byte 0x${first:02x}')
}
