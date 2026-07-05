module socks

import socks.socks5
import socks.socks4

const fuzz_iters = 10000

// Lcg is a fixed-seed linear congruential generator for reproducible fuzzing.
struct Lcg {
mut:
	state u64
}

fn (mut g Lcg) next() u32 {
	g.state = g.state * 6364136223846793005 + 1442695040888963407
	return u32(g.state >> 32)
}

fn (mut g Lcg) byte() u8 {
	return u8(g.next())
}

fn (mut g Lcg) intn(n int) int {
	if n <= 0 {
		return 0
	}
	return int(g.next() % u32(n))
}

fn try_parse_addr(buf []u8) ! {
	socks5.parse_addr(buf)!
}

// parse_all runs every parser; each may only decode or return an error.
fn parse_all(buf []u8) {
	socks5.parse_hello(buf) or {}
	socks5.parse_userpass(buf) or {}
	socks5.parse_request(buf) or {}
	socks5.parse_reply(buf) or {}
	socks5.parse_udp_datagram(buf) or {}
	try_parse_addr(buf) or {}
	socks4.parse_request(buf) or {}
	socks4.parse_reply(buf) or {}
}

fn test_fuzz_random_buffers() {
	seed := u64(0x1234_5678_9abc_def0)
	eprintln('fuzz random seed=0x${seed:016x}')
	mut g := Lcg{
		state: seed
	}
	for _ in 0 .. fuzz_iters {
		n := g.intn(301) // 0..300 bytes
		mut buf := []u8{len: n}
		for i in 0 .. n {
			buf[i] = g.byte()
		}
		parse_all(buf)
	}
	assert true
}

fn test_fuzz_mutated_frames() {
	seed := u64(0x0fed_cba9_8765_4321)
	eprintln('fuzz mutate seed=0x${seed:016x}')
	seeds := [
		socks5.encode_hello([u8(0x00), 0x02]),
		socks5.encode_request(socks5.Request{
			command: .connect
			addr:    socks5.Addr{
				atyp: .domain
				host: 'example.com'
				port: 443
			}
		}),
		socks5.encode_udp_datagram(socks5.Addr{ atyp: .ipv4, host: '1.2.3.4', port: 53 },
			[u8(1), 2, 3]),
		socks4.encode_request(socks4.Request{ host: '1.2.3.4', port: 80, userid: 'x' }),
	]
	mut g := Lcg{
		state: seed
	}
	for _ in 0 .. fuzz_iters {
		base := seeds[g.intn(seeds.len)]
		mut buf := base.clone()
		if buf.len > 0 {
			match g.intn(4) {
				0 { buf[g.intn(buf.len)] ^= u8(1) << u8(g.intn(8)) } // bit flip
				1 { buf.insert(g.intn(buf.len + 1), g.byte()) } // insert
				2 { buf.delete(g.intn(buf.len)) } // delete
				else { buf = buf[..g.intn(buf.len)].clone() } // truncate
			}
		}
		parse_all(buf)
	}
	assert true
}
