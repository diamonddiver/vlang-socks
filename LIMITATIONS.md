# Known Limitations (v1)

This library's server is built around a single event-loop thread (`picoev`)
handling every accepted connection, plus a small resolver pool for DNS +
outbound `connect()`. That design is efficient for well-behaved clients on a
trusted network, but it is **not hardened against untrusted or hostile
clients**. Read this before deciding whether to expose it directly to
arbitrary internet clients.

## Resource-exhaustion / stall risks

- **No per-connection handshake/idle timeout.** A client that connects and
  never completes (or never finishes) the SOCKS handshake holds its fd and
  `Relay` state indefinitely — until it disconnects on its own or the server
  is stopped. There is no server-side timer to reclaim it. A hostile client
  can hold many connections open this way to exhaust fds.

- **No per-job connect timeout in the resolver pool.** `resolver.Pool` runs a
  fixed number of worker threads (`ServerConfig.resolver_threads`, default 8)
  that perform blocking DNS resolution + `net.dial_tcp()` for each `CONNECT`
  request, and hands work to them through a bounded job queue (capacity 256).
  If enough concurrent requests target slow or unreachable hosts, all workers
  can end up blocked in-flight with no timeout to unstick them, and the job
  queue backs up. This no longer stalls the event loop, though: `apply()`
  hands jobs to the pool via `Pool.try_submit()`, which fails fast (replying
  with a SOCKS failure) instead of blocking when the queue is full, so a
  saturated pool degrades only new `CONNECT` requests, not every other
  connection sharing the event loop. Connections already past this point are
  unaffected either way — there is still no way to unstick an already-blocked
  worker.

- **Relay writes have no finite deadline.** Once a connection is relaying,
  both the client-side and target-side sockets are deliberately given an
  explicit "block forever" read/write deadline (`net.infinite_timeout` —
  chosen over V's default deadline behavior, which has been observed to be an
  unintentional artifact rather than a deliberate choice on this V version;
  see the comments in `socks/client.v`'s `dial()` and `socks/server.v`'s
  `on_accept`/`on_result` for the full explanation). This makes "block
  forever" an intentional, verified choice instead of an accidental one, but
  it does **not** add a finite timeout: a sufficiently slow or malicious peer
  on either side of a relay can still hold that connection's socket (and the
  event-loop thread's write) open indefinitely, since nothing forces it
  closed.

Taken together: this v1 is best suited for **trusted or low-hostility network
environments** (e.g. a personal or internal proxy), not for exposing directly
to arbitrary untrusted internet clients without additional hardening — for
example a reverse proxy / connection-rate-limiter in front, or waiting for a
future version that adds the timeouts described above.

## Protocol / addressing limitations

- **UDP ASSOCIATE: first datagram defines the client.** The relay learns
  which peer address is "the client" from whichever address the first
  datagram on the UDP relay socket came from; all later datagrams from that
  same address are treated as client-to-target traffic, and anything else is
  treated as target-to-client traffic. There's no independent verification
  step, so a peer that races the real client for the first datagram can hijack
  the association.

- **UDP ASSOCIATE: domain-typed targets are dropped.** If a client's UDP
  datagram addresses its target by domain name (ATYP=domain) rather than an
  IP literal, the datagram is silently dropped rather than resolved.

- **UDP ASSOCIATE: IPv6 target/reply handling is incomplete.** The UDP relay
  path (both the bound-address reply and datagram source/destination
  addressing) always encodes addresses as `ATYP=ipv4`, regardless of whether
  the actual address is IPv4 or IPv6 — IPv6 UDP targets and replies are not
  correctly represented.

- **UDP datagram fragmentation is not supported.** Any datagram with
  `FRAG != 0x00` is rejected outright rather than reassembled (by design —
  see the project's scope notes — but worth calling out here too).

## Lifecycle

- **The event-loop thread outlives `stop()`/`wait()`.** The underlying
  `picoev` loop has no stop primitive, so `ServerHandle.stop()` +
  `ServerHandle.wait()` close the listener and clean up the resolver pool /
  tracked relays, but the OS thread actually running the event loop keeps
  running as an unreclaimed daemon thread until the process exits. `wait()`
  returning does **not** mean that thread has stopped, only that the
  resources this library owns have been released.

## Summary

None of the above are correctness bugs in the sense of violating the SOCKS
protocol for well-behaved traffic — they are accepted v1 scope/hardening
trade-offs. But viewed together they mean a single slow or hostile peer can
degrade or stall service for every other connection sharing the same event
loop. Treat this as a proxy for cooperative environments, not as a
public-internet-facing service, until timeouts are added for the cases above.
