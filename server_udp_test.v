module socks

import net
import time
import socks.resolver
import socks.socks5

fn test_server_udp_associate_roundtrip() {
	mut target := net.listen_udp('127.0.0.1:0') or { panic(err) }
	// net.UdpConn has no `.addr()` (unlike TcpListener/TcpConn); the embedded
	// Socket.address() reads the bound local address via getsockname() (same
	// correction as Task 19's fake_udp_relay test helper).
	taddr := target.sock.address() or { panic(err) }.str()
	defer {
		target.close() or {}
	}
	spawn fn (mut u net.UdpConn) {
		for {
			mut b := []u8{len: 2048}
			n, peer := u.read(mut b) or { break }
			u.write_to(peer, b[..n]) or { break }
		}
	}(mut target)

	mut h := spawn_serve(ServerConfig{
		addr:      '127.0.0.1:0'
		versions:  [.v5]
		allow_udp: true
	})!
	defer {
		h.stop()
		h.wait()
	}
	mut sess := udp_associate(ClientConfig{ proxy_addr: h.addr() })!
	sess.write_to(taddr, 'ping'.bytes())!
	who, data := sess.read_from()!
	assert data == 'ping'.bytes()
	assert who == taddr
	sess.close()
}

fn test_build_udp_reply_datagram_encodes_ipv4_peer() {
	peer := net.new_ip(80, [u8(127), 0, 0, 1]!)
	pkt := build_udp_reply_datagram(peer, [u8(1), 2, 3]) or { panic('expected Some(pkt)') }
	dg := socks5.parse_udp_datagram(pkt)!
	assert dg.addr.atyp == .ipv4
	assert dg.addr.host == '127.0.0.1'
	assert dg.addr.port == 80
	assert dg.data == [u8(1), 2, 3]
}

fn test_build_udp_reply_datagram_drops_ipv6_peer() {
	// v1 has no correct IPv6-reply encoding (see LIMITATIONS.md): dropping is
	// the safe choice over silently emitting a corrupted ATYP=0x01 header
	// with mismatched (IPv6-length) address bytes.
	addr := [u8(0x20), 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]!
	peer := net.new_ip6(80, addr)
	got := build_udp_reply_datagram(peer, [u8(1), 2, 3])
	if _ := got {
		assert false
	}
}

fn test_handle_udp_domain_cache_hit_forwards() {
	mut target := net.listen_udp('127.0.0.1:0') or { panic(err) }
	defer {
		target.close() or {}
	}
	taddr := target.sock.address() or { panic(err) }
	tport := taddr.str().all_after_last(':').u16()

	mut relay_sock := net.listen_udp('127.0.0.1:0') or { panic(err) }
	relay_sock.set_write_timeout(net.no_timeout)

	mut s := &Server{}
	mut r := &Relay{
		udp: relay_sock
	}
	r.udp_cache['example.com'] = UdpCacheEntry{
		ip:      '127.0.0.1'
		expires: time.now().add(1 * time.minute)
	}
	dg := socks5.UdpDatagram{
		addr: socks5.Addr{
			atyp: .domain
			host: 'example.com'
			port: tport
		}
		data: 'hi'.bytes()
	}
	s.handle_udp_domain(mut r, dg)

	mut buf := []u8{len: 64}
	n, _ := target.read(mut buf) or { panic(err) }
	assert buf[..n] == 'hi'.bytes()
}

fn test_handle_udp_domain_queues_same_domain_in_flight() {
	mut relay_sock := net.listen_udp('127.0.0.1:0') or { panic(err) }
	mut s := &Server{
		pool: resolver.new_for_test(4)
	}
	mut r := &Relay{
		udp: relay_sock
	}
	dg1 := socks5.UdpDatagram{
		addr: socks5.Addr{
			atyp: .domain
			host: 'example.com'
			port: 53
		}
		data: 'a'.bytes()
	}
	dg2 := socks5.UdpDatagram{
		addr: socks5.Addr{
			atyp: .domain
			host: 'example.com'
			port: 54
		}
		data: 'b'.bytes()
	}
	s.handle_udp_domain(mut r, dg1)
	job_id := r.udp_resolve_job
	assert job_id != 0
	s.handle_udp_domain(mut r, dg2)
	assert r.udp_resolve_job == job_id // still the same in-flight job
	assert r.udp_resolve_queue.len == 2
	assert r.udp_resolve_queue[0].port == 53
	assert r.udp_resolve_queue[1].port == 54
}

fn test_handle_udp_domain_drops_different_domain_while_in_flight() {
	mut relay_sock := net.listen_udp('127.0.0.1:0') or { panic(err) }
	mut s := &Server{
		pool: resolver.new_for_test(4)
	}
	mut r := &Relay{
		udp: relay_sock
	}
	dg1 := socks5.UdpDatagram{
		addr: socks5.Addr{
			atyp: .domain
			host: 'example.com'
			port: 53
		}
		data: 'a'.bytes()
	}
	dg2 := socks5.UdpDatagram{
		addr: socks5.Addr{
			atyp: .domain
			host: 'other.example'
			port: 53
		}
		data: 'b'.bytes()
	}
	s.handle_udp_domain(mut r, dg1)
	job_id := r.udp_resolve_job
	s.handle_udp_domain(mut r, dg2)
	assert r.udp_resolve_job == job_id // untouched: no second job started
	assert r.udp_resolve_domain == 'example.com'
	assert r.udp_resolve_queue.len == 1 // dg2 silently dropped
}
