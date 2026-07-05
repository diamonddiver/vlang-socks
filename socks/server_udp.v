module socks

import net
import picoev
import socks.socks5

// start_udp opens a UDP relay socket bound on the server's IP and replies with
// its address.
fn (mut s Server) start_udp(mut pv picoev.Picoev, mut r Relay) {
	host, _ := split_host_port(s.bound_addr) or {
		s.fail_relay(mut pv, mut r, .general_failure)
		return
	}
	mut u := net.listen_udp('${host}:0') or {
		s.fail_relay(mut pv, mut r, .general_failure)
		return
	}
	// Same deliberate "block forever" policy as the TCP client/target conns in
	// server.v's on_accept/on_result (see those for the full net.infinite_timeout
	// vs net.no_timeout rationale) — this relay socket's write_to calls should
	// have an explicit, verified deadline policy rather than an accidental one.
	u.set_read_timeout(net.infinite_timeout)
	u.set_write_timeout(net.infinite_timeout)
	// net.UdpConn has no `.addr()` (unlike TcpListener/TcpConn); the embedded
	// Socket.address() reads the bound local address via getsockname() (same
	// correction Task 19 applied in its fake_udp_relay test helper).
	uaddr := u.sock.address() or {
		u.close() or {}
		s.fail_relay(mut pv, mut r, .general_failure)
		return
	}
	r.udp = u
	r.udp_fd = u.sock.handle
	bhost := uaddr.str().all_before_last(':')
	bport := uaddr.str().all_after_last(':').u16()
	act := r.m5.on_udp_bound(socks5.Addr{ atyp: .ipv4, host: bhost, port: bport })
	r.client.write(act.reply) or {
		s.close_relay(mut pv, mut r)
		return
	}
	r.relaying = true
	s.relays[r.udp_fd] = r
	s.roles[r.udp_fd] = .udp
	pv_add(mut pv, r.udp_fd)
}

// on_udp_readable forwards a datagram in whichever direction it came.
fn (mut s Server) on_udp_readable(mut pv picoev.Picoev, fd int) {
	mut r := s.relays[fd] or { return }
	mut buf := []u8{len: 65535}
	n, peer := r.udp.read(mut buf) or { return }
	peer_str := peer.str()
	// The first datagram (and any from the same address) is the client.
	if r.client_udp == '' || peer_str == r.client_udp {
		r.client_udp = peer_str
		dg := socks5.parse_udp_datagram(buf[..n]) or { return } // FRAG!=0 => dropped
		if dg.addr.atyp == .domain {
			return
		}
		// dg.addr.host is an IP literal here, so resolve_addrs does no DNS query.
		taddr := resolve_first('${dg.addr.host}:${dg.addr.port}') or { return }
		r.udp.write_to(taddr, dg.data) or {}
	} else {
		pkt := build_udp_reply_datagram(peer, buf[..n]) or { return }
		caddr := resolve_first(r.client_udp) or { return }
		r.udp.write_to(caddr, pkt) or {}
	}
}

// build_udp_reply_datagram encodes a target's reply as a SOCKS5 UDP datagram
// addressed from peer. Returns none for an IPv6 peer: v1's ATYP is hardcoded
// to .ipv4 here (see LIMITATIONS.md), and mis-encoding an IPv6 source as
// ATYP=0x01 would silently corrupt the header (wrong address byte length)
// rather than just fail loudly, so the datagram is dropped instead.
fn build_udp_reply_datagram(peer net.Addr, data []u8) ?[]u8 {
	if peer.family() == .ip6 {
		return none
	}
	peer_str := peer.str()
	src := socks5.Addr{
		atyp: .ipv4
		host: peer_str.all_before_last(':')
		port: peer_str.all_after_last(':').u16()
	}
	return socks5.encode_udp_datagram(src, data)
}

// resolve_first resolves addr to its first candidate, or none on any failure
// (unresolvable, or resolves to zero addresses) — the shared "best effort,
// silently drop the datagram" shape both UDP relay directions use.
fn resolve_first(addr string) ?net.Addr {
	xs := net.resolve_addrs(addr, .ip, .udp) or { return none }
	if xs.len == 0 {
		return none
	}
	return xs[0]
}
