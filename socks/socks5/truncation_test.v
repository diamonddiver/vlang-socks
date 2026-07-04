module socks5

// A parser is a function that either decodes or returns an error, never panics.
type Parser = fn (buf []u8) !

fn wrap_hello(b []u8) ! {
	parse_hello(b)!
}

fn wrap_userpass(b []u8) ! {
	parse_userpass(b)!
}

fn wrap_request(b []u8) ! {
	parse_request(b)!
}

fn wrap_reply(b []u8) ! {
	parse_reply(b)!
}

fn wrap_udp(b []u8) ! {
	parse_udp_datagram(b)!
}

fn known_good() map[string][]u8 {
	return {
		'hello':    encode_hello([u8(0x00), 0x02])
		'userpass': encode_userpass(UserPass{ user: 'alice', pass: 'pw' })
		'request':  encode_request(Request{
			command: .connect
			addr:    Addr{
				atyp: .domain
				host: 'example.com'
				port: 443
			}
		})
		'reply':    encode_reply(0x00, Addr{ atyp: .ipv4, host: '1.2.3.4', port: 80 })
		'udp':      encode_udp_datagram(Addr{ atyp: .ipv4, host: '8.8.8.8', port: 53 },
			[u8(1), 2, 3])
	}
}

fn parsers() map[string]Parser {
	return {
		'hello':    wrap_hello
		'userpass': wrap_userpass
		'request':  wrap_request
		'reply':    wrap_reply
		'udp':      wrap_udp
	}
}

fn test_truncate_every_offset_never_panics() {
	good := known_good()
	ps := parsers()
	for name, frame in good {
		p := ps[name]
		for cut in 0 .. frame.len {
			// The only acceptable outcomes are decode-ok or an error;
			// a panic would abort the test binary and fail this test.
			p(frame[..cut]) or { continue }
		}
	}
	assert true
}
