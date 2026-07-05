module socks4

import socks.core

fn v4_connect(is_4a bool) []u8 {
	return encode_request(Request{
		host:   if is_4a { 'example.com' } else { '1.2.3.4' }
		port:   80
		userid: 'u'
		is_4a:  is_4a
	})
}

fn test_plain_connect_flow() {
	mut m := Conn4{
		cfg:   Conn4Config{
			allow_plain: true
			allow_4a:    true
		}
		stage: .request
	}
	a := m.feed(v4_connect(false))!
	target := a.connect or { panic('expected connect') }
	assert target.host == '1.2.3.4'
	assert target.port == 80
	assert m.stage == .pending
	a2 := m.on_connected()
	assert a2.reply.len == 8
	assert a2.reply[1] == core.cd_granted
	assert m.stage == .relaying
}

fn test_4a_connect_flow() {
	mut m := Conn4{
		cfg:   Conn4Config{
			allow_plain: true
			allow_4a:    true
		}
		stage: .request
	}
	a := m.feed(v4_connect(true))!
	target := a.connect or { panic('expected connect') }
	assert target.host == 'example.com'
}

fn test_partial_request_waits() {
	mut m := Conn4{
		cfg:   Conn4Config{
			allow_plain: true
		}
		stage: .request
	}
	a := m.feed([u8(0x04), 0x01, 0, 80, 1, 2, 3])! // < 9 bytes
	assert a.reply.len == 0
	assert m.stage == .request
}

fn test_4a_rejected_when_disabled() {
	mut m := Conn4{
		cfg:   Conn4Config{
			allow_plain: true
			allow_4a:    false
		}
		stage: .request
	}
	a := m.feed(v4_connect(true))!
	assert a.close
	assert a.reply[1] == core.cd_code(.address_type_not_supported)
}

fn test_plain_rejected_when_only_4a() {
	mut m := Conn4{
		cfg:   Conn4Config{
			allow_plain: false
			allow_4a:    true
		}
		stage: .request
	}
	a := m.feed(v4_connect(false))!
	assert a.close
	assert a.reply[1] == 91
}

fn test_on_failed_sends_cd91() {
	mut m := Conn4{
		stage: .pending
	}
	a := m.on_failed(.host_unreachable)
	assert a.close
	assert a.reply[1] == 91
}

fn test_bad_command_sends_cd91() {
	mut m := Conn4{
		cfg:   Conn4Config{
			allow_plain: true
		}
		stage: .request
	}
	// CD=0x02 (BIND) is not CONNECT: reply CD=91, don't just drop.
	mut buf := [u8(0x04), 0x02, 0, 80, 1, 2, 3, 4]
	buf << u8(0) // empty USERID NUL
	a := m.feed(buf)!
	assert a.close
	assert a.reply[1] == 91
}

fn test_userid_guard_no_hang() {
	mut m := Conn4{
		cfg:   Conn4Config{
			allow_plain: true
		}
		stage: .request
	}
	mut buf := [u8(0x04), 0x01, 0, 80, 1, 2, 3, 4]
	for _ in 0 .. 300 {
		buf << u8(`x`) // never NUL-terminated, exceeds max_userid
	}
	m.feed(buf) or {
		assert (err as core.SocksError).kind == .protocol_error
		return
	}
	assert false
}
