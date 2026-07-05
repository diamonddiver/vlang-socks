module capi

import time
import socks

// ms_to_duration converts a millisecond count from the C API into a
// time.Duration (nanoseconds), the unit socks.ServerConfig's timeout fields
// use.
fn ms_to_duration(ms i64) time.Duration {
	return time.Duration(ms) * time.millisecond
}

// versions_from_mask decodes the versions_mask bitmask: bit0=v4, bit1=v4a,
// bit2=v5 (same SOCKS_V4/V4A/V5 = 1/2/4 constants documented in
// include/socks.h, reused as plain scalar values by socks_dial's `version`
// argument).
fn versions_from_mask(mask int) []socks.SocksVersion {
	mut out := []socks.SocksVersion{}
	if mask & 1 != 0 {
		out << .v4
	}
	if mask & 2 != 0 {
		out << .v4a
	}
	if mask & 4 != 0 {
		out << .v5
	}
	return out
}

// auth_from_mode builds an Auth from the C API's auth_mode/user/pass triple.
// user/pass are only read when auth_mode == 1 (UserPassAuth).
fn auth_from_mode(auth_mode int, user &char, pass &char) socks.Auth {
	if auth_mode == 1 {
		return socks.user_pass_auth(cstr(user), cstr(pass))
	}
	return socks.no_auth()
}

// socks_server_start builds a ServerConfig from flat scalar arguments,
// starts the server, and returns a registry handle (0 on failure — call
// socks_last_error_code()/socks_last_error_message() for why).
// auth_mode: 0 = no auth, 1 = user/pass (user/pass read only in that case).
// versions_mask: bit0=v4, bit1=v4a, bit2=v5 (see SOCKS_V4/V4A/V5 in socks.h).
@[export: 'socks_server_start']
pub fn server_start(addr &char, auth_mode int, user &char, pass &char, allow_udp bool, versions_mask int, resolver_threads int, log_connections bool, handshake_timeout_ms i64, idle_timeout_ms i64, connect_timeout_ms i64, max_connections int) u64 {
	cfg := socks.ServerConfig{
		addr:              cstr(addr)
		auth:              auth_from_mode(auth_mode, user, pass)
		allow_udp:         allow_udp
		versions:          versions_from_mask(versions_mask)
		resolver_threads:  resolver_threads
		log_connections:   log_connections
		handshake_timeout: ms_to_duration(handshake_timeout_ms)
		idle_timeout:      ms_to_duration(idle_timeout_ms)
		connect_timeout:   ms_to_duration(connect_timeout_ms)
		max_connections:   max_connections
	}
	h := socks.spawn_serve(cfg) or {
		record_error(err)
		return 0
	}
	clear_error()
	id := alloc_handle()
	reg_mu.@lock()
	servers[id] = h
	reg_mu.unlock()
	return id
}

// socks_server_stop closes the listener; see ServerHandle.stop(). No-op on
// an unknown id.
@[export: 'socks_server_stop']
pub fn server_stop(id u64) {
	reg_mu.@lock()
	mut h := servers[id] or {
		reg_mu.unlock()
		return
	}
	reg_mu.unlock()
	h.stop()
}

// socks_server_wait blocks until the server's owned resources are released;
// see ServerHandle.wait(). No-op on an unknown id.
@[export: 'socks_server_wait']
pub fn server_wait(id u64) {
	reg_mu.@lock()
	mut h := servers[id] or {
		reg_mu.unlock()
		return
	}
	reg_mu.unlock()
	h.wait()
}

// socks_server_addr returns the server's bound address (host:port) as a
// NUL-terminated C string owned by the library, valid for the handle's
// lifetime. NULL on an unknown id.
@[export: 'socks_server_addr']
pub fn server_addr(id u64) &char {
	reg_mu.@lock()
	h := servers[id] or {
		reg_mu.unlock()
		return unsafe { nil }
	}
	reg_mu.unlock()
	return unsafe { &char(h.addr().str) }
}
