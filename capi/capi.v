// Package capi is the C ABI for libsocks: flat, C-POD-only wrappers around
// module socks's public API, exported as socks_* symbols.
//
// This module (and only this module) uses `__global` for its handle
// registry, which requires building with -enable-globals. module socks
// itself never depends on this module and never needs that flag — plain `v
// import socks` consumers are unaffected. See scripts/build-lib.sh for the
// build invocation that adds -enable-globals for this module only.
module capi

import sync
import socks
import socks.core

// LastError holds the most recent socks_* call's error, if any. Deliberately
// a single global rather than thread-local: callers are expected to check
// the error immediately after the call that may have produced it, the same
// contract as errno/strerror in C.
struct LastError {
mut:
	code int = -1
	msg  string
}

__global (
	reg_mu      = sync.new_mutex()
	next_handle = u64(1)
	servers     map[u64]socks.ServerHandle
	sessions    map[u64]socks.UdpSession
	last_err    LastError
)

fn C.GC_INIT()

// socks_init MUST be called exactly once, before any other socks_* call, by
// every process that links this library. The shared library's `_vinit`
// constructor runs automatically on dlopen, but GC_INIT() does not — V only
// emits that call in its own generated main(), which a -shared build never
// has — so this must be called explicitly to start the Boehm GC.
@[export: 'socks_init']
pub fn socks_init() {
	$if gcboehm ? {
		C.GC_INIT()
	}
}

@[export: 'socks_last_error_code']
pub fn last_error_code() int {
	reg_mu.@lock()
	code := last_err.code
	reg_mu.unlock()
	return code
}

@[export: 'socks_last_error_message']
pub fn last_error_message() &char {
	reg_mu.@lock()
	msg := last_err.msg
	reg_mu.unlock()
	return unsafe { &char(msg.str) }
}

@[export: 'socks_strerror']
pub fn strerror(code int) &char {
	msg := match code {
		-1 { 'no error' }
		int(core.SocksErrorCode.general_failure) { 'general failure' }
		int(core.SocksErrorCode.connection_not_allowed) { 'connection not allowed by ruleset' }
		int(core.SocksErrorCode.network_unreachable) { 'network unreachable' }
		int(core.SocksErrorCode.host_unreachable) { 'host unreachable' }
		int(core.SocksErrorCode.connection_refused) { 'connection refused' }
		int(core.SocksErrorCode.ttl_expired) { 'TTL expired' }
		int(core.SocksErrorCode.command_not_supported) { 'command not supported' }
		int(core.SocksErrorCode.address_type_not_supported) { 'address type not supported' }
		int(core.SocksErrorCode.auth_failed) { 'authentication failed' }
		int(core.SocksErrorCode.auth_method_not_acceptable) { 'no acceptable authentication method' }
		int(core.SocksErrorCode.protocol_error) { 'protocol error' }
		int(core.SocksErrorCode.fragmentation_not_supported) { 'UDP fragmentation not supported' }
		int(core.SocksErrorCode.local_timeout) { 'local timeout' }
		int(core.SocksErrorCode.internal_error) { 'internal error' }
		else { 'unknown error code' }
	}
	return unsafe { &char(msg.str) }
}

// set_error records a raw (code, message) pair as the last error.
fn set_error(code int, msg string) {
	reg_mu.@lock()
	last_err = LastError{
		code: code
		msg:  msg
	}
	reg_mu.unlock()
}

// clear_error marks the last call as successful.
fn clear_error() {
	reg_mu.@lock()
	last_err = LastError{}
	reg_mu.unlock()
}

// record_error captures a V error returned from socks's public API,
// preferring its SocksErrorCode when it is one (see socks.error_kind).
fn record_error(err IError) {
	code := if k := socks.error_kind(err) {
		int(k)
	} else {
		int(core.SocksErrorCode.internal_error)
	}
	set_error(code, err.msg())
}

// alloc_handle returns the next registry id. Never 0: callers reserve that
// as the failure sentinel.
fn alloc_handle() u64 {
	reg_mu.@lock()
	id := next_handle
	next_handle++
	reg_mu.unlock()
	return id
}

// cstr converts a non-nil C string pointer to a V string.
fn cstr(p &char) string {
	return unsafe { cstring_to_vstring(p) }
}
