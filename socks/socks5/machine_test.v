module socks5

import socks.core

fn zero_addr() Addr {
	return Addr{
		atyp: .ipv4
		host: '0.0.0.0'
		port: 0
	}
}

fn test_noauth_connect_flow() {
	mut m := Conn5{
		cfg:   Conn5Config{}
		stage: .handshake
	}
	a1 := m.feed(encode_hello([u8(method_no_auth)]))!
	assert a1.reply == encode_method_select(method_no_auth)
	assert !a1.close
	req := encode_request(Request{
		command: .connect
		addr:    Addr{
			atyp: .ipv4
			host: '1.2.3.4'
			port: 80
		}
	})
	a2 := m.feed(req)!
	target := a2.connect or { panic('expected connect target') }
	assert target.host == '1.2.3.4'
	assert target.port == 80
	assert m.stage == .pending
	a3 := m.on_connected(zero_addr())
	assert a3.reply[0] == socks5_version
	assert a3.reply[1] == core.rep_success
	assert m.stage == .relaying
}

fn test_partial_hello_waits() {
	mut m := Conn5{
		stage: .handshake
	}
	a := m.feed([u8(0x05)])! // only VER, no NMETHODS yet
	assert a.reply.len == 0
	assert !a.close
	assert m.stage == .handshake
}

fn test_no_acceptable_method() {
	mut m := Conn5{
		cfg:   Conn5Config{
			require_userpass: true
		}
		stage: .handshake
	}
	a := m.feed(encode_hello([u8(method_no_auth)]))! // client offers only no-auth
	assert a.reply == encode_method_select(method_none)
	assert a.close
	assert m.stage == .closed
}

fn test_userpass_success_then_connect() {
	mut m := Conn5{
		cfg:   Conn5Config{
			require_userpass: true
			username:         'u'
			password:         'p'
		}
		stage: .handshake
	}
	m.feed(encode_hello([u8(method_user_pass)]))!
	a := m.feed(encode_userpass(UserPass{ user: 'u', pass: 'p' }))!
	assert a.reply == encode_userpass_reply(true)
	assert !a.close
	assert m.stage == .request
}

fn test_userpass_failure_closes() {
	mut m := Conn5{
		cfg:   Conn5Config{
			require_userpass: true
			username:         'u'
			password:         'p'
		}
		stage: .handshake
	}
	m.feed(encode_hello([u8(method_user_pass)]))!
	a := m.feed(encode_userpass(UserPass{ user: 'u', pass: 'WRONG' }))!
	assert a.reply == encode_userpass_reply(false)
	assert a.close
	assert m.stage == .closed
}

fn test_bind_command_not_supported() {
	mut m := Conn5{
		stage: .handshake
	}
	m.feed(encode_hello([u8(method_no_auth)]))!
	req := encode_request(Request{
		command: .bind
		addr:    Addr{
			atyp: .ipv4
			host: '1.1.1.1'
			port: 1
		}
	})
	a := m.feed(req)!
	assert a.close
	assert a.reply[1] == core.rep_code(.command_not_supported)
}

fn test_udp_disabled_rejected() {
	mut m := Conn5{
		cfg:   Conn5Config{
			allow_udp: false
		}
		stage: .handshake
	}
	m.feed(encode_hello([u8(method_no_auth)]))!
	req := encode_request(Request{
		command: .udp_associate
		addr:    zero_addr()
	})
	a := m.feed(req)!
	assert a.close
	assert a.reply[1] == core.rep_code(.command_not_supported)
}

fn test_udp_enabled_requests_bind() {
	mut m := Conn5{
		cfg:   Conn5Config{
			allow_udp: true
		}
		stage: .handshake
	}
	m.feed(encode_hello([u8(method_no_auth)]))!
	req := encode_request(Request{
		command: .udp_associate
		addr:    zero_addr()
	})
	a := m.feed(req)!
	assert a.udp_associate
	assert m.stage == .pending
	a2 := m.on_udp_bound(Addr{ atyp: .ipv4, host: '127.0.0.1', port: 5555 })
	assert a2.reply[1] == core.rep_success
	assert m.stage == .relaying
}

fn test_on_failed_maps_reply() {
	mut m := Conn5{
		stage: .pending
	}
	a := m.on_failed(.host_unreachable)
	assert a.close
	assert a.reply[1] == core.rep_code(.host_unreachable)
}

fn test_bad_atyp_replies_addr_not_supported() {
	mut m := Conn5{
		stage: .handshake
	}
	m.feed(encode_hello([u8(method_no_auth)]))!
	// VER CMD RSV ATYP=0x02 (unsupported) ...
	a := m.feed([u8(0x05), 0x01, 0x00, 0x02, 0, 0])!
	assert a.close
	assert a.reply[1] == core.rep_code(.address_type_not_supported)
}

fn test_bad_command_replies_not_supported() {
	mut m := Conn5{
		stage: .handshake
	}
	m.feed(encode_hello([u8(method_no_auth)]))!
	// VER CMD=0x09 (unknown) RSV ATYP=ipv4 addr port
	a := m.feed([u8(0x05), 0x09, 0x00, 0x01, 1, 2, 3, 4, 0, 80])!
	assert a.close
	assert a.reply[1] == core.rep_code(.command_not_supported)
}

fn test_pipelined_hello_and_request() {
	mut m := Conn5{
		stage: .handshake
	}
	// A client that sends hello and CONNECT in one segment must not stall.
	mut pipelined := encode_hello([u8(method_no_auth)])
	pipelined << encode_request(Request{
		command: .connect
		addr:    Addr{
			atyp: .ipv4
			host: '1.2.3.4'
			port: 80
		}
	})
	a := m.feed(pipelined)!
	assert a.reply == encode_method_select(method_no_auth) // method-select still sent
	target := a.connect or { panic('expected connect from pipelined frames') }
	assert target.host == '1.2.3.4'
	assert m.stage == .pending
}

fn test_connect_leaves_pipelined_payload_in_buf() {
	// A client that piggy-backs application bytes after the CONNECT request must
	// not lose them: they stay in buf so the driver can flush them to the target
	// once the relay is up (see Task 18 on_result). This locks that invariant.
	mut m := Conn5{
		stage: .handshake
	}
	m.feed(encode_hello([u8(method_no_auth)]))!
	mut req := encode_request(Request{
		command: .connect
		addr:    Addr{
			atyp: .ipv4
			host: '1.2.3.4'
			port: 80
		}
	})
	req << 'EARLYDATA'.bytes()
	a := m.feed(req)!
	target := a.connect or { panic('expected connect') }
	assert target.host == '1.2.3.4'
	assert m.buf == 'EARLYDATA'.bytes()
}
