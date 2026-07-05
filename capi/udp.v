module capi

import socks
import socks.core

// socks_udp_associate opens a SOCKS5 UDP association and returns a registry
// handle (0 on failure). auth_mode/resolve_mode: same encoding as
// socks_dial. Always negotiates SOCKS5 (UDP ASSOCIATE requires it).
@[export: 'socks_udp_associate']
pub fn udp_associate(proxy_addr &char, auth_mode int, user &char, pass &char, resolve_mode int) u64 {
	mode := if resolve_mode == 1 {
		socks.ResolveMode.client_side
	} else {
		socks.ResolveMode.server_side
	}
	cfg := socks.ClientConfig{
		proxy_addr:   cstr(proxy_addr)
		version:      .v5
		auth:         auth_from_mode(auth_mode, user, pass)
		resolve_mode: mode
	}
	sess := socks.udp_associate(cfg) or {
		record_error(err)
		return 0
	}
	clear_error()
	id := alloc_handle()
	reg_mu.@lock()
	sessions[id] = sess
	reg_mu.unlock()
	return id
}

// socks_udp_write_to sends data to addr (host:port) over the association.
// Returns the byte count sent, or -1 on failure / unknown handle.
@[export: 'socks_udp_write_to']
pub fn udp_write_to(id u64, addr &char, data &u8, len int) int {
	reg_mu.@lock()
	mut sess := sessions[id] or {
		reg_mu.unlock()
		set_error(int(core.SocksErrorCode.internal_error), 'socks_udp_write_to: invalid handle')
		return -1
	}
	reg_mu.unlock()
	buf := unsafe { data.vbytes(len) }
	sess.write_to(cstr(addr), buf) or {
		record_error(err)
		return -1
	}
	clear_error()
	return len
}

// socks_udp_read_from blocks for the next datagram, writing its sender's
// "host:port" (NUL-terminated) into addr_buf and its payload into data_buf.
// Returns the payload length, or -1 on failure / unknown handle / either
// buffer too small (addr_cap must include room for the NUL terminator).
@[export: 'socks_udp_read_from']
pub fn udp_read_from(id u64, addr_buf &char, addr_cap int, data_buf &u8, data_cap int) int {
	reg_mu.@lock()
	mut sess := sessions[id] or {
		reg_mu.unlock()
		set_error(int(core.SocksErrorCode.internal_error), 'socks_udp_read_from: invalid handle')
		return -1
	}
	reg_mu.unlock()
	addr, data := sess.read_from() or {
		record_error(err)
		return -1
	}
	if data.len > data_cap || addr.len >= addr_cap {
		set_error(int(core.SocksErrorCode.internal_error), 'socks_udp_read_from: buffer too small')
		return -1
	}
	unsafe {
		mut ab := &u8(addr_buf)
		C.memcpy(data_buf, data.data, usize(data.len))
		C.memcpy(ab, addr.str, usize(addr.len))
		ab[addr.len] = 0
	}
	clear_error()
	return data.len
}

// socks_udp_close releases the association. No-op on an unknown id.
@[export: 'socks_udp_close']
pub fn udp_close(id u64) {
	reg_mu.@lock()
	mut sess := sessions[id] or {
		reg_mu.unlock()
		return
	}
	sessions.delete(id)
	reg_mu.unlock()
	sess.close()
}
