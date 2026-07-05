module socks

import net
import time
import picoev
import socks.core

// test_send_to_target_queues_and_pauses_client_on_full_buffer builds a
// Server+Relay by hand (mirroring test_apply_replies_failure_when_resolver_queue_full's
// style in server_test.v) over real loopback sockets, saturates the target
// socket's kernel send buffer, then verifies send_to_target queues the
// unsent remainder and pauses the client side, and that drain_target later
// flushes the queue intact (no loss, corruption, or reordering).
fn test_send_to_target_queues_and_pauses_client_on_full_buffer() {
	mut pv := picoev.new(picoev.Config{
		port:   0
		family: .ip
	})!
	mut srv := &Server{}

	// "target" side: a real loopback pair. peer_target is never read from
	// during saturation, so target_conn's kernel send buffer fills up.
	mut tl := net.listen_tcp(.ip, '127.0.0.1:0')!
	taddr := tl.addr()!.str()
	mut target_conn := net.dial_tcp(taddr)!
	mut peer_target := tl.accept()!
	tl.close() or {}
	defer {
		target_conn.close() or {}
		peer_target.close() or {}
	}

	// "client" side: send_to_target only needs a valid fd here (for
	// sync_client_interest's pv.add); nothing is sent/received on it.
	mut cl := net.listen_tcp(.ip, '127.0.0.1:0')!
	caddr := cl.addr()!.str()
	mut client_conn := net.dial_tcp(caddr)!
	mut peer_client := cl.accept()!
	cl.close() or {}
	defer {
		client_conn.close() or {}
		peer_client.close() or {}
	}

	mut r := &Relay{
		client:    client_conn
		client_fd: client_conn.sock.handle
		target:    target_conn
		target_fd: target_conn.sock.handle
		relaying:  true
	}

	// Saturate target_conn's send buffer with raw try_send calls until a
	// short (or zero) write is observed.
	filler := []u8{len: 65536, init: u8(1)}
	mut pre_sent := 0
	mut blocked := false
	for _ in 0 .. 200 {
		n := try_send(r.target_fd, filler) or { panic(err) }
		pre_sent += n
		if n < filler.len {
			blocked = true
			break
		}
	}
	assert blocked

	// Comfortably above relay_hwm (256KiB) even after send_to_target's own
	// try_send call manages to slip a few more bytes through.
	more := []u8{len: 512 * 1024, init: u8(2)}
	srv.send_to_target(mut pv, mut r, more)
	assert r.target_out.len > 0
	assert r.client_paused == true

	// Drain the peer (freeing target_conn's send buffer) and repeatedly
	// drain_target, exactly as the event loop would on successive writable
	// events, until every byte has arrived.
	total_expected := pre_sent + more.len
	mut received := []u8{}
	mut buf := []u8{len: 65536}
	peer_target.set_read_timeout(500 * time.millisecond)
	for received.len < total_expected {
		n := peer_target.read(mut buf) or { break }
		if n == 0 {
			break
		}
		received << buf[..n]
		if r.target_out.len > 0 {
			srv.drain_target(mut pv, mut r)
		}
	}

	assert r.target_out.len == 0
	assert r.client_paused == false
	assert received.len == total_expected
	for i in 0 .. pre_sent {
		assert received[i] == u8(1)
	}
	for i in pre_sent .. received.len {
		assert received[i] == u8(2)
	}
}

// test_apply_queues_reply_remainder_when_client_buffer_full is BUG 1's
// regression guard: when the client socket's send buffer is full, apply()'s
// single non-blocking try_send can only push part (or none) of a SOCKS
// reply frame. The unsent remainder must be QUEUED (not silently dropped) so
// the client still receives the complete reply frame, in order, before any
// relay bytes. Deterministic: the peer never reads until the drain phase, so
// the pipe stays saturated and the reply is guaranteed to land in client_out.
fn test_apply_queues_reply_remainder_when_client_buffer_full() {
	mut pv := picoev.new(picoev.Config{
		port:   0
		family: .ip
	})!
	mut srv := &Server{}

	mut cl := net.listen_tcp(.ip, '127.0.0.1:0')!
	caddr := cl.addr()!.str()
	mut client_conn := net.dial_tcp(caddr)!
	mut peer_client := cl.accept()!
	cl.close() or {}
	defer {
		client_conn.close() or {}
		peer_client.close() or {}
	}

	mut r := &Relay{
		client:    client_conn
		client_fd: client_conn.sock.handle
	}

	// Saturate the client socket's send path (peer_client never reads yet).
	filler := []u8{len: 65536, init: u8(1)}
	mut pre_sent := 0
	mut blocked := false
	for _ in 0 .. 500 {
		n := try_send(r.client_fd, filler) or { panic(err) }
		pre_sent += n
		if n < filler.len {
			blocked = true
			break
		}
	}
	assert blocked

	// A distinctive 10-byte reply frame (mirrors a SOCKS5 success reply's
	// shape; exact bytes just need to be recognizable in the drained stream).
	reply := [u8(0x05), 0x00, 0x00, 0x01, 0xde, 0xad, 0xbe, 0xef, 0x04, 0xd2]
	act := core.Action{
		reply: reply
	}
	srv.apply(mut pv, mut r, act)
	// The pipe was full, so the whole reply must have been queued, not sent.
	assert r.client_out.len > 0
	assert r.client_out == reply

	// Drain the peer, draining client_out on each pass, until everything the
	// client is owed has arrived.
	total_expected := pre_sent + reply.len
	mut received := []u8{}
	mut buf := []u8{len: 65536}
	peer_client.set_read_timeout(500 * time.millisecond)
	for received.len < total_expected {
		n := peer_client.read(mut buf) or { break }
		if n == 0 {
			break
		}
		received << buf[..n]
		if r.client_out.len > 0 {
			srv.drain_client(mut pv, mut r)
		}
	}

	assert r.client_out.len == 0
	assert received.len == total_expected
	// The complete reply frame arrives intact, immediately after the filler
	// (i.e. no relay/other bytes interleaved into the reply).
	assert received[pre_sent..] == reply
}

fn fast_echo_target() !(&net.TcpListener, string) {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	addr := l.addr()!.str()
	spawn fn (mut l net.TcpListener) {
		for {
			mut c := l.accept() or { return }
			spawn fn (mut c net.TcpConn) {
				for {
					mut b := []u8{len: 256}
					n := c.read(mut b) or { break }
					if n == 0 {
						break
					}
					c.write(b[..n]) or { break }
				}
				c.close() or {}
			}(mut c)
		}
	}(mut l)
	return l, addr
}

// slow_target accepts one connection and reads it back deliberately slowly,
// accumulating exactly `want` bytes before reporting them on the returned
// channel (bounding on a byte count rather than EOF, since the test keeps
// the connection open throughout).
fn slow_target(want int) !(&net.TcpListener, string, chan []u8) {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	addr := l.addr()!.str()
	result := chan []u8{cap: 1}
	spawn fn (mut l net.TcpListener, want int, result chan []u8) {
		mut c := l.accept() or { return }
		mut received := []u8{}
		mut b := []u8{len: 65536}
		for received.len < want {
			n := c.read(mut b) or { break }
			if n == 0 {
				break
			}
			received << b[..n]
			time.sleep(30 * time.millisecond) // deliberately slow consumer
		}
		result <- received
		c.close() or {}
	}(mut l, want, result)
	return l, addr, result
}

// test_slow_target_does_not_stall_other_connections is the end-to-end proof
// that D1's non-blocking queued relay writes keep one slow connection from
// stalling the shared picoev loop: a second, unrelated proxied connection
// must complete quickly while the first is still being drained slowly.
fn test_slow_target_does_not_stall_other_connections() {
	mut payload := []u8{len: 3 * 1024 * 1024}
	for i in 0 .. payload.len {
		payload[i] = u8(i % 256)
	}

	mut slow_l, slow_addr, slow_result := slow_target(payload.len) or { panic(err) }
	defer {
		slow_l.close() or {}
	}
	mut fast_l, fast_addr := fast_echo_target() or { panic(err) }
	defer {
		fast_l.close() or {}
	}

	mut h := spawn_serve(ServerConfig{
		addr:      '127.0.0.1:0'
		versions:  [.v5]
		allow_udp: false
	})!
	defer {
		h.stop()
		h.wait()
	}

	mut conn1_val := dial(ClientConfig{ proxy_addr: h.addr(), version: .v5 }, slow_addr)!
	// dial() returns net.TcpConn by value (unlike accept()'s &net.TcpConn),
	// and spawn requires a genuine reference argument to mutate across the
	// goroutine boundary — take conn1's address once, then only ever use
	// that pointer below.
	mut conn1 := &conn1_val
	write_done := chan bool{cap: 1}
	spawn fn (mut c net.TcpConn, data []u8, done chan bool) {
		c.write(data) or {}
		done <- true
	}(mut conn1, payload, write_done)

	// Let the slow target's consumption fall behind so the relay is
	// genuinely backpressured (not just "hasn't started yet") by the time
	// the second connection is dialed below.
	time.sleep(100 * time.millisecond)

	sw := time.now()
	mut conn2 := dial(ClientConfig{ proxy_addr: h.addr(), version: .v5 }, fast_addr)!
	conn2.write('ping'.bytes())!
	mut b := []u8{len: 8}
	n := conn2.read(mut b)!
	assert b[..n] == 'ping'.bytes()
	elapsed := time.now() - sw
	assert elapsed < 500 * time.millisecond
	conn2.close() or {}

	// Bounded wait for the slow target to eventually receive everything the
	// first connection sent, intact.

	select {
		got := <-slow_result {
			assert got == payload
		}
		10 * time.second {
			assert false // slow target never finished draining - loop stalled
		}
	}
	_ := <-write_done
	conn1.close() or {}
}
