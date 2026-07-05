module resolver

import net
import time
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

// new starts `nworkers` blocking resolve+connect workers, each bounding a
// single dial to at most connect_timeout (<= 0 disables the bound).
pub fn new(nworkers int, connect_timeout time.Duration) Pool {
	n := if nworkers < 1 { 1 } else { nworkers }
	p := Pool{
		jobs:     chan Job{cap: 256}
		results:  chan Result{cap: 256}
		nworkers: n
	}
	for _ in 0 .. n {
		spawn worker(p.jobs, p.results, connect_timeout)
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

// try_submit is submit()'s non-blocking counterpart: it enqueues job and
// returns true, or returns false immediately (instead of blocking) if the
// queue is full — e.g. because every worker is stuck on a slow/unreachable
// target. Callers on the event-loop thread must use this, not submit(): a
// blocked submit() there stalls every connection, not just the slow one.
// Same close() precondition as submit() applies.
pub fn (mut p Pool) try_submit(job Job) bool {
	mut sent := false
	select {
		p.jobs <- job {
			sent = true
		}
		else {
			sent = false
		}
	}
	return sent
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

// new_for_test builds a pool with a bounded job queue and NO workers draining
// it, for deterministic tests of queue-full behavior (try_submit()). Do not
// use in production: with no workers, submitted jobs never complete.
pub fn new_for_test(queue_cap int) Pool {
	return Pool{
		jobs:    chan Job{cap: queue_cap}
		results: chan Result{cap: queue_cap}
	}
}

// worker drains jobs, bounding each dial to connect_timeout when set so one
// slow/unreachable target can't occupy this worker slot forever.
fn worker(jobs chan Job, results chan Result, connect_timeout time.Duration) {
	for {
		job := <-jobs or { break } // channel closed => exit
		if connect_timeout <= 0 {
			dial_and_report(job, results)
		} else {
			run_with_timeout(job, results, connect_timeout)
		}
	}
}

// dial_and_report performs the blocking resolve+connect and reports the
// outcome on results.
fn dial_and_report(job Job, results chan Result) {
	conn := net.dial_tcp(dial_addr(job.target)) or {
		results <- Result{
			id:  job.id
			err: classify(err, job.target)
		}
		return
	}
	results <- Result{
		id:   job.id
		conn: conn
	}
}

// run_with_timeout races dial_and_report against timeout. If the dial hasn't
// reported by then, a .local_timeout Result is sent immediately so the
// worker pool slot frees up — but dial_and_report's goroutine keeps running
// in the background (vlib has no way to cancel a blocking connect(2)) and
// eventually writes its result into the now-abandoned `done` channel.
fn run_with_timeout(job Job, results chan Result, timeout time.Duration) {
	done := chan Result{cap: 1}
	spawn dial_and_report(job, done)
	select {
		r := <-done {
			results <- r
		}
		i64(timeout) {
			// select's timeout branch key must type-check as a plain
			// integer (nanoseconds), not the time.Duration alias — a
			// checker quirk confirmed against this V version: a bare
			// Duration-typed function parameter is rejected here even
			// though a Duration-typed const (e.g. server.v's sweep_tick)
			// is accepted. Casting sidesteps it without changing meaning,
			// since Duration's underlying representation already is
			// nanoseconds.
			results <- Result{
				id:  job.id
				err: core.err(.local_timeout, 'connect ${job.target.host}:${job.target.port} timed out after ${timeout}')
			}
			// The background dial isn't cancellable, but if it LATER
			// succeeds it hands back a connected socket on `done` that no
			// one reads. net.TcpConn has no GC finalizer, so that fd would
			// leak for the process lifetime. Drain `done` asynchronously
			// and close any late connection to reclaim its fd.
			spawn fn (done chan Result) {
				late := <-done
				if mut c := late.conn {
					c.close() or {}
				}
			}(done)
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
		core.SocksErrorCode.internal_error
	}
	return core.err_cause(kind, 'connect ${t.host}:${t.port}', e)
}
