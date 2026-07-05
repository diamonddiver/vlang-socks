module core

fn test_err_msg_without_cause() {
	e := err(.protocol_error, 'bad ATYP 0x07')
	assert e.msg() == 'bad ATYP 0x07'
	assert e.code() == int(SocksErrorCode.protocol_error)
}

fn test_err_msg_with_cause() {
	e := err_cause(.host_unreachable, 'host example.com:443', error('no route'))
	assert e.msg() == 'host example.com:443: no route'
	assert e.kind == .host_unreachable
}

fn test_socks_error_is_ierror() {
	// A SocksError must be usable as the error of a `!` function.
	f := fn () !int {
		return err(.connection_refused, 'refused')
	}
	f() or {
		assert err.msg() == 'refused'
		assert err.code() == int(SocksErrorCode.connection_refused)
		return
	}
	assert false // should have taken the `or` branch
}
