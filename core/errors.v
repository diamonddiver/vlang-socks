module core

// SocksErrorCode splits into remote-reported variants (parsed from a peer's
// SOCKS reply/CD byte) and local-only variants (raised by our own code).
pub enum SocksErrorCode {
	general_failure             // remote: REP=0x01 / CD=91
	connection_not_allowed      // remote
	network_unreachable         // remote
	host_unreachable            // remote
	connection_refused          // remote
	ttl_expired                 // remote: REP=0x06
	command_not_supported       // remote
	address_type_not_supported  // remote
	auth_failed                 // remote: RFC1929 STATUS != 0
	auth_method_not_acceptable  // remote: METHOD=0xFF
	protocol_error              // local: malformed/unexpected bytes from peer
	fragmentation_not_supported // local: UDP FRAG != 0x00
	local_timeout               // local: our own deadline fired
	internal_error              // local: could not classify the failure
}

pub struct SocksError {
pub:
	kind   SocksErrorCode
	detail string
	cause  ?IError
}

pub fn (e SocksError) msg() string {
	if c := e.cause {
		return '${e.detail}: ${c.msg()}'
	}
	return e.detail
}

pub fn (e SocksError) code() int {
	return int(e.kind)
}

// err builds a SocksError with no wrapped cause.
pub fn err(kind SocksErrorCode, detail string) SocksError {
	return SocksError{
		kind:   kind
		detail: detail
	}
}

// err_cause builds a SocksError wrapping a lower-level OS/IO error.
pub fn err_cause(kind SocksErrorCode, detail string, cause IError) SocksError {
	return SocksError{
		kind:   kind
		detail: detail
		cause:  cause
	}
}
