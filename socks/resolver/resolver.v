module resolver

import net
import socks.core

pub struct Job {
pub:
	id     u64
	target core.Target
}

pub struct Result {
pub:
	id   u64
	conn ?&net.TcpConn
	err  ?core.SocksError
}

pub struct Pool {
mut:
	jobs chan Job
pub mut:
	results  chan Result
	nworkers int
}

// new starts `nworkers` blocking resolve+connect workers.
pub fn new(nworkers int) Pool {
	n := if nworkers < 1 { 1 } else { nworkers }
	p := Pool{
		jobs:     chan Job{cap: 256}
		results:  chan Result{cap: 256}
		nworkers: n
	}
	for _ in 0 .. n {
		spawn worker(p.jobs, p.results)
	}
	return p
}

// submit enqueues job for a worker to pick up.
//
// Precondition: submit() must never be called after, or concurrently with,
// close(). Closing a V channel while a push is in flight (or afterwards)
// makes the push panic the whole process with `panic('push on closed
// channel')` — there is no recoverable error path, since this method's
// signature (per the spec) returns nothing to report failure with.
// Callers own this sequencing: only close() the pool from the same
// single thread/context that calls submit(), and only after that context
// has permanently stopped issuing new submit() calls.
pub fn (mut p Pool) submit(job Job) {
	p.jobs <- job
}

// close shuts down the jobs channel, signalling workers to exit once they
// drain any already-queued jobs.
//
// Precondition: see submit() — the caller must guarantee no submit() call
// is in flight or issued after close() is called, or the next submit()
// will panic on the closed channel.
pub fn (mut p Pool) close() {
	p.jobs.close()
}

fn worker(jobs chan Job, results chan Result) {
	for {
		job := <-jobs or { break } // channel closed => exit
		conn := net.dial_tcp(dial_addr(job.target)) or {
			results <- Result{
				id:  job.id
				err: classify(err, job.target)
			}
			continue
		}
		results <- Result{
			id:   job.id
			conn: conn
		}
	}
}

fn dial_addr(t core.Target) string {
	if t.host.contains(':') {
		return '[${t.host}]:${t.port}' // IPv6 literal
	}
	return '${t.host}:${t.port}'
}

// classify maps a dial/resolve failure to a remote-style SocksErrorCode,
// wrapping the original OS error as the cause.
fn classify(e IError, t core.Target) core.SocksError {
	msg := e.msg().to_lower()
	kind := if msg.contains('refused') {
		core.SocksErrorCode.connection_refused
	} else if msg.contains('unreachable') {
		core.SocksErrorCode.network_unreachable
	} else if msg.contains('no such host') || msg.contains('not known') || msg.contains('resolve') {
		core.SocksErrorCode.host_unreachable
	} else {
		core.SocksErrorCode.general_failure
	}
	return core.err_cause(kind, 'connect ${t.host}:${t.port}', e)
}
