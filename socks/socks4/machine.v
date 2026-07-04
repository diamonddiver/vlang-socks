module socks4

import socks.core

pub enum Stage4 {
	request
	pending
	relaying
	closed
}

pub struct Conn4Config {
pub:
	allow_plain bool
	allow_4a    bool
}

pub struct Conn4 {
pub mut:
	cfg   Conn4Config
	stage Stage4
	buf   []u8
}

fn wait4() core.Action {
	return core.Action{}
}

pub fn (mut m Conn4) feed(data []u8) !core.Action {
	m.buf << data
	if m.stage != .request {
		return wait4()
	}
	n := socks4_frame_len(m.buf)!
	if n < 0 {
		return wait4()
	}
	req := parse_request(m.buf[..n]) or {
		// A non-CONNECT SOCKS4 command collapses to CD=91 on the wire (spec:
		// SOCKS4/4a CD collapse); any other parse failure closes with no reply.
		if err is core.SocksError && err.kind == core.SocksErrorCode.command_not_supported {
			m.buf = m.buf[n..].clone()
			return m.fail(.command_not_supported)
		}
		return err
	}
	m.buf = m.buf[n..].clone()
	if req.is_4a && !m.cfg.allow_4a {
		return m.fail(.address_type_not_supported)
	}
	if !req.is_4a && !m.cfg.allow_plain {
		return m.fail(.address_type_not_supported)
	}
	m.stage = .pending
	return core.Action{
		connect: core.Target{
			host: req.host
			port: req.port
		}
	}
}

fn (mut m Conn4) fail(kind core.SocksErrorCode) core.Action {
	m.stage = .closed
	return core.Action{
		reply: encode_reply(core.cd_code(kind))
		close: true
	}
}

pub fn (mut m Conn4) on_connected() core.Action {
	m.stage = .relaying
	return core.Action{
		reply: encode_reply(core.cd_granted)
	}
}

pub fn (mut m Conn4) on_failed(kind core.SocksErrorCode) core.Action {
	return m.fail(kind)
}

// socks4_frame_len returns the full request length, -1 if more bytes are
// needed, or a protocol error if a bounded field overruns its guard.
fn socks4_frame_len(buf []u8) !int {
	if buf.len < 9 {
		return -1
	}
	uend := find_nul(buf, 8, max_userid)!
	if uend < 0 {
		return -1
	}
	is_4a := buf[4] == 0 && buf[5] == 0 && buf[6] == 0 && buf[7] != 0
	if !is_4a {
		return uend + 1
	}
	dend := find_nul(buf, uend + 1, max_domain)!
	if dend < 0 {
		return -1
	}
	return dend + 1
}

// find_nul returns the index of the first NUL in buf[start..], scanning at
// most `max` bytes. Returns -1 if not found yet (buffer shorter than the
// guard), or a protocol error if `max` bytes were scanned with no NUL.
fn find_nul(buf []u8, start int, max int) !int {
	limit := start + max
	end := if limit < buf.len { limit } else { buf.len }
	mut i := start
	for i < end {
		if buf[i] == 0 {
			return i
		}
		i++
	}
	if buf.len >= limit {
		return core.err(.protocol_error, 'socks4: field exceeds ${max} bytes')
	}
	return -1
}
