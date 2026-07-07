# Known Limitations (v1)

This library's server is built around a single event-loop thread (`picoev`)
handling every accepted connection, plus a small resolver pool for DNS +
outbound `connect()`. That design is efficient for well-behaved clients on a
trusted network, but it is **not hardened against untrusted or hostile
clients**. Read this before deciding whether to expose it directly to
arbitrary internet clients.

## Resource-exhaustion / stall risks

- **Handshake timeout and connection cap are enforced; idle relays are not by
  default.** An accepted connection that never finishes its SOCKS handshake is
  reclaimed after `ServerConfig.handshake_timeout` (default 30s), and the total
  number of concurrent accepted connections is bounded by
  `ServerConfig.max_connections` (default 0 = unlimited). Once a connection is
  **relaying**, however, it is only reclaimed for inactivity if
  `ServerConfig.idle_timeout` is set (default 0 = disabled): with the default, an
  established relay that goes silent holds its fds and `Relay` state until a peer
  disconnects. Set `idle_timeout` when exposing the server to untrusted clients.

- **Per-connect timeout bounds worker occupancy, not the underlying OS thread.**
  The resolver pool (`ServerConfig.resolver_threads`, default 8) performs
  blocking DNS + `net.dial_tcp()` off the event loop, fed by a bounded job queue
  (capacity 256) that fails fast via `try_submit()` rather than blocking the loop
  when full. Each dial is now bounded by `ServerConfig.connect_timeout` (default
  30s, `<= 0` disables): on expiry the worker slot is freed immediately
  (reporting `.local_timeout`) so a slow/unreachable target no longer pins a
  worker for the OS's full connect timeout. vlib exposes no way to cancel a
  blocked `getaddrinfo()`/`connect()`, so the abandoned dial's OS thread keeps
  running in the background until the kernel gives up (any late-succeeding
  connection is closed so its fd is not leaked). Under sustained abuse against
  black-holed targets, background threads can therefore still accumulate faster
  than they retire, even though the pool itself keeps accepting new jobs.

- **Relay writes are non-blocking with backpressure; no single peer stalls the
  loop.** Relay data is written with a non-blocking send; whatever the kernel
  cannot take immediately is queued per direction and drained on the next
  writable event, and once a direction's outbound queue exceeds a high-water mark
  (256 KiB) the opposite side's reads are paused until it drains. A slow or
  malicious peer on either side therefore backs up only its own connection's
  queue (bounded by that peer's own progress and, if set, `idle_timeout`) instead
  of blocking the single event-loop thread for every other connection. The relay
  sockets still carry `net.infinite_timeout` at the socket level, but that
  deadline is no longer on any path that can block the loop.

What remains for exposing this directly to arbitrary untrusted internet clients
is out-of-scope-for-v1 **policy**, not the stall risks above: there is no egress
filtering (SSRF to loopback/link-local/RFC1918/metadata targets), no per-source
connection or rate limiting, and the UDP / `resolve_mode` gaps below. Enable
`idle_timeout` and put a rate-limiter / egress policy in front before serving
hostile traffic.

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

- **UDP datagram fragmentation is not supported.** Any datagram with
  `FRAG != 0x00` is rejected outright rather than reassembled (by design —
  see the project's scope notes — but worth calling out here too).

## Configuration

- **`ServerConfig.resolve_mode` is not consulted by the server.** Setting it
  to `.client_side` has no effect: `apply()` always hands every `CONNECT`
  target (including domain names) to the resolver pool for server-side DNS
  resolution regardless of this field. A caller relying on `.client_side` to
  make the server refuse to resolve domain names itself (e.g. as an
  SSRF-avoidance policy, requiring clients to pre-resolve and send IP
  literals) gets silently ignored configuration. `ClientConfig.resolve_mode`
  is unaffected by this — it works as documented for `dial()`/`udp_associate()`.

- **`SocksErrorCode.local_timeout` and `.internal_error` are raised only on
  specific paths.** Both are now produced: a client-side read that fails on
  `dial()`'s deadline is reported as `.local_timeout` (not `.protocol_error`, so
  callers can distinguish "the proxy is slow/hung" from "the proxy sent bytes we
  couldn't parse"), a resolver dial that exceeds `connect_timeout` reports
  `.local_timeout`, and an unclassifiable resolver failure reports
  `.internal_error`. The remaining gap: server-side handshake reads on accepted
  connections (the event loop's own `read_some`) do not distinguish a
  read-deadline timeout — only the client `dial()`/`udp_associate()` paths and
  the resolver do.

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
trade-offs. The worst of the earlier stall risks have been closed: a single slow
or hostile peer can no longer freeze the event loop for every other connection
(non-blocking relay writes + backpressure), unfinished handshakes and idle
relays can be reaped (`handshake_timeout` / `idle_timeout`), the connection count
is capped (`max_connections`), and stuck dials free their worker slot
(`connect_timeout`). What remains for a public-internet deployment is
out-of-scope-for-v1 policy — egress/SSRF filtering, per-source rate limiting, and
the UDP / `resolve_mode` gaps above. Enable `idle_timeout` and front the server
with a rate-limiter before exposing it to arbitrary untrusted clients.
