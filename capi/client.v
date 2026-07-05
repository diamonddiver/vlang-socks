module capi

import net
import socks
import socks.core

// socks_dial connects through the proxy to target_addr and returns the raw
// connected socket fd (ownership transferred to the caller — this library
// drops its own wrapper without closing it; see client.v's dial() for why
// that's safe). -1 on failure (check socks_last_error_code/message).
// version: one of SOCKS_V4(1)/SOCKS_V4A(2)/SOCKS_V5(4) (socks.h).
// auth_mode: 0 = no auth, 1 = user/pass. resolve_mode: 0 = server_side, 1 =
// client_side.
@[export: 'socks_dial']
pub fn dial(proxy_addr &char, version int, auth_mode int, user &char, pass &char, resolve_mode int, target_addr &char) int {
	ver := match version {
		1 {
			socks.SocksVersion.v4
		}
		2 {
			socks.SocksVersion.v4a
		}
		4 {
			socks.SocksVersion.v5
		}
		else {
			set_error(int(core.SocksErrorCode.internal_error), 'socks_dial: invalid version ${version}')
			return -1
		}
	}
	mode := if resolve_mode == 1 {
		socks.ResolveMode.client_side
	} else {
		socks.ResolveMode.server_side
	}
	cfg := socks.ClientConfig{
		proxy_addr:   cstr(proxy_addr)
		version:      ver
		auth:         auth_from_mode(auth_mode, user, pass)
		resolve_mode: mode
	}
	mut conn := socks.dial(cfg, cstr(target_addr)) or {
		record_error(err)
		return -1
	}
	clear_error()
	fd := conn.sock.handle
	// This library is built with -d net_nonblocking_sockets (required for
	// its own internal timeout handling), which leaves every socket it
	// creates — including this one — with O_NONBLOCK set at the OS level.
	// A plain C/Python caller doing an ordinary blocking read()/recv() on
	// this fd would otherwise get EAGAIN immediately instead of blocking.
	// Restore normal blocking-socket behavior before handing it over: this
	// is a plain kernel fd property, freely resettable regardless of which
	// library/flag originally set it.
	net.set_blocking(fd, true) or {}
	return fd
}
