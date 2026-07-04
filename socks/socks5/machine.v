module socks5

import socks.core

pub enum Stage {
	handshake
	auth
	request
	pending
	relaying
	closed
}

pub struct Conn5Config {
pub:
	require_userpass bool
	username         string
	password         string
	allow_udp        bool
}

pub struct Conn5 {
pub mut:
	cfg          Conn5Config
	stage        Stage
	buf          []u8
	pending_cmd  Command
	pending_addr Addr
}

fn wait() core.Action {
	return core.Action{}
}

// feed appends new client bytes and advances the machine as far as the buffered
// bytes allow, concatenating each step's reply. This handles pipelined control
// frames (e.g. a client that sends hello+request — or hello+userpass+request —
// in a single TCP segment): all get processed in one call instead of stalling
// with the tail sitting unread in the buffer until more bytes arrive.
pub fn (mut m Conn5) feed(data []u8) !core.Action {
	m.buf << data
	mut out := core.Action{}
	for {
		if m.stage !in [Stage.handshake, .auth, .request] {
			break // pending/relaying/closed: client bytes handled elsewhere
		}
		before := m.buf.len
		act := match m.stage {
			.handshake { m.step_handshake()! }
			.auth { m.step_auth()! }
			.request { m.step_request()! }
			else { wait() }
		}
		out.reply << act.reply
		if act.close {
			out.close = true
			break
		}
		if c := act.connect {
			out.connect = c
			break
		}
		if act.udp_associate {
			out.udp_associate = true
			break
		}
		if m.buf.len == before {
			break // a step consumed nothing: it needs more bytes, wait for them
		}
	}
	return out
}

fn (mut m Conn5) step_handshake() !core.Action {
	n := hello_len(m.buf)
	if n < 0 || m.buf.len < n {
		return wait()
	}
	h := parse_hello(m.buf[..n])!
	m.buf = m.buf[n..].clone()
	want := if m.cfg.require_userpass { method_user_pass } else { method_no_auth }
	if want !in h.methods {
		m.stage = .closed
		return core.Action{
			reply: encode_method_select(method_none)
			close: true
		}
	}
	m.stage = if m.cfg.require_userpass { Stage.auth } else { Stage.request }
	return core.Action{
		reply: encode_method_select(want)
	}
}

fn (mut m Conn5) step_auth() !core.Action {
	n := userpass_len(m.buf)
	if n < 0 || m.buf.len < n {
		return wait()
	}
	up := parse_userpass(m.buf[..n])!
	m.buf = m.buf[n..].clone()
	ok := up.user == m.cfg.username && up.pass == m.cfg.password
	if !ok {
		m.stage = .closed
		return core.Action{
			reply: encode_userpass_reply(false)
			close: true
		}
	}
	m.stage = .request
	return core.Action{
		reply: encode_userpass_reply(true)
	}
}

fn (mut m Conn5) step_request() !core.Action {
	n := request_len(m.buf)
	if n < 0 || m.buf.len < n {
		return wait()
	}
	req := parse_request(m.buf[..n]) or {
		// RFC 1928 §6: a request the server understands but cannot honor gets a
		// mapped REP reply before closing. address_type_not_supported and
		// command_not_supported are wire-expressible, so reply with the REP
		// byte; a protocol_error (truncation/garbage) closes with no reply.
		if err is core.SocksError {
			if err.kind in [core.SocksErrorCode.command_not_supported, .address_type_not_supported] {
				m.buf = m.buf[n..].clone()
				return m.fail_reply(err.kind)
			}
		}
		return err
	}
	m.buf = m.buf[n..].clone()
	m.pending_cmd = req.command
	m.pending_addr = req.addr
	match req.command {
		.connect {
			m.stage = .pending
			return core.Action{
				connect: req.addr.target()
			}
		}
		.udp_associate {
			if !m.cfg.allow_udp {
				return m.fail_reply(.command_not_supported)
			}
			m.stage = .pending
			return core.Action{
				udp_associate: true
			}
		}
		.bind {
			return m.fail_reply(.command_not_supported)
		}
	}
}

fn (mut m Conn5) fail_reply(kind core.SocksErrorCode) core.Action {
	m.stage = .closed
	return core.Action{
		reply: encode_reply(core.rep_code(kind), Addr{ atyp: .ipv4, host: '0.0.0.0', port: 0 })
		close: true
	}
}

// on_connected: the driver connected to the target; reply success + relay.
pub fn (mut m Conn5) on_connected(bound Addr) core.Action {
	m.stage = .relaying
	return core.Action{
		reply: encode_reply(core.rep_success, bound)
	}
}

// on_failed: the driver's resolve/connect failed; reply the mapped code + close.
pub fn (mut m Conn5) on_failed(kind core.SocksErrorCode) core.Action {
	return m.fail_reply(kind)
}

// on_udp_bound: the driver opened a UDP relay; reply its bound address + relay.
pub fn (mut m Conn5) on_udp_bound(bound Addr) core.Action {
	m.stage = .relaying
	return core.Action{
		reply: encode_reply(core.rep_success, bound)
	}
}

// --- framing helpers: full frame length, or -1 if undeterminable yet ---

fn hello_len(buf []u8) int {
	if buf.len < 2 {
		return -1
	}
	return 2 + int(buf[1])
}

fn userpass_len(buf []u8) int {
	if buf.len < 2 {
		return -1
	}
	ulen := int(buf[1])
	if buf.len < 2 + ulen + 1 {
		return -1
	}
	plen := int(buf[2 + ulen])
	return 2 + ulen + 1 + plen
}

fn request_len(buf []u8) int {
	if buf.len < 4 {
		return -1
	}
	atyp := buf[3]
	if atyp == 0x01 {
		return 3 + 7
	}
	if atyp == 0x04 {
		return 3 + 19
	}
	if atyp == 0x03 {
		if buf.len < 5 {
			return -1
		}
		return 3 + 2 + int(buf[4]) + 2
	}
	// unknown ATYP: 4 bytes is enough for parse_request to raise the error.
	return 4
}
