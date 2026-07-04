module resolver

import net
import socks.core

fn start_echo() !(&net.TcpListener, string) {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	addr := l.addr()!.str()
	spawn fn (mut l net.TcpListener) {
		for {
			mut c := l.accept() or { return }
			mut b := []u8{len: 64}
			n := c.read(mut b) or {
				c.close() or {}
				continue
			}
			c.write(b[..n]) or {}
			c.close() or {}
		}
	}(mut l)
	return l, addr
}

fn test_resolver_connects_and_reports() {
	mut l, addr := start_echo() or { panic(err) }
	defer {
		l.close() or {}
	}
	host := addr.all_before_last(':')
	port := addr.all_after_last(':').u16()
	mut p := new(2)
	defer {
		p.close()
	}
	p.submit(Job{
		id:     1
		target: core.Target{
			host: host
			port: port
		}
	})
	r := <-p.results
	assert r.id == 1
	mut c := r.conn or { panic('expected a connection, got err') }
	c.write('hi'.bytes())!
	mut rb := []u8{len: 8}
	n := c.read(mut rb)!
	assert rb[..n] == 'hi'.bytes()
	c.close()!
}

fn test_resolver_reports_failure() {
	mut p := new(1)
	defer {
		p.close()
	}
	// 127.0.0.1:1 is a privileged port that should refuse.
	p.submit(Job{
		id:     7
		target: core.Target{
			host: '127.0.0.1'
			port: 1
		}
	})
	r := <-p.results
	assert r.id == 7
	if _ := r.conn {
		assert false // must not have connected
	}
	e := r.err or { panic('expected an error') }
	assert e.kind in [core.SocksErrorCode.connection_refused, .host_unreachable, .general_failure]
}
