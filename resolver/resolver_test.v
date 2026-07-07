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
	mut p := new(2, 0)
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
	mut p := new(1, 0)
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
	assert e.kind in [core.SocksErrorCode.connection_refused, .host_unreachable, .internal_error]
}

// test_classify_unrecognized_error_is_internal guards the catch-all branch:
// an OS/dial error whose message matches none of the recognized keywords
// must classify as .internal_error (a local "couldn't classify this"
// marker), not silently masquerade as .general_failure (a remote-reported
// code implying the peer itself rejected the connection).
fn test_classify_unrecognized_error_is_internal() {
	e := classify(error('made-up'), core.Target{ host: '1.2.3.4', port: 80 })
	assert e.kind == .internal_error
}

fn test_resolver_resolve_kind_job_reports_addr() {
	mut p := new(1, 0)
	defer {
		p.close()
	}
	p.submit(Job{
		id:     3
		target: core.Target{
			host: '127.0.0.1'
			port: 53
		}
		kind:   .resolve
	})
	r := <-p.results
	assert r.id == 3
	if _ := r.conn {
		assert false // resolve-kind jobs never dial
	}
	addr := r.addr or { panic('expected an addr, got err') }
	assert addr.str().all_before_last(':') == '127.0.0.1'
}

fn test_try_submit_reports_false_when_queue_full() {
	// No workers spawned (constructed directly, not via new()), so nothing
	// drains `jobs` — the queue stays exactly as full as we leave it.
	mut p := Pool{
		jobs:    chan Job{cap: 1}
		results: chan Result{cap: 1}
	}
	job := Job{
		id:     1
		target: core.Target{
			host: '10.0.0.1'
			port: 80
		}
	}
	assert p.try_submit(job) == true // fills the cap-1 queue
	assert p.try_submit(job) == false // queue full: must return immediately, not block
}
