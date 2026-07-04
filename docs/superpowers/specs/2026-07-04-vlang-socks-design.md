# vlang-socks: design

## Summary

`vlang-socks` is a V module implementing both a SOCKS client and a SOCKS server, supporting SOCKS5 (RFC 1928 + RFC 1929 username/password auth) and SOCKS4/4a, with a small CLI binary as a working example. The library's goal is to make standing up or driving a SOCKS proxy from V trivial: a one-line `serve()` for servers, a `dial()` that returns a plain `net.TcpConn` for clients.

## Scope

**In scope:**
- SOCKS5: no-auth and username/password authentication; CONNECT and UDP ASSOCIATE commands; IPv4/IPv6/domain-name addressing.
- SOCKS4 and SOCKS4a: CONNECT command only (no auth, no UDP — per protocol).
- A server that can accept SOCKS4, SOCKS4a, and SOCKS5 connections on the same listener, with each version individually enabled/disableable.
- A client that dials through a proxy and returns a standard `net.TcpConn`, plus a UDP association helper.
- A minimal CLI binary wrapping the server API.

**Out of scope (v1):**
- SOCKS5 BIND command (legacy, rarely used).
- GSSAPI authentication.
- UDP datagram fragmentation (FRAG != 0x00) — rejected, not reassembled.
- Identd verification for SOCKS4 USERID (field is read and ignored).
- CLI configuration file support, daemonization, structured logging.

**Platform support:** Linux, macOS, and Windows, all via the same code path (no platform-specific branches in `vlang-socks` itself — see Architecture).

## Architecture

A single module `socks` with internal sub-packages:

- **`socks`** (public API) — `serve()`, `spawn_serve()`, `ServerHandle`, `dial()`, `udp_associate()`, config structs (`ServerConfig`, `ClientConfig`, `Auth`, `ResolveMode`, `SocksVersion`), and the `SocksError` type. This is the only import most users need.
- **`socks5`** (internal) — SOCKS5 wire codecs (pure `[]u8` functions: handshake/method negotiation, username/password subnegotiation, CONNECT and UDP ASSOCIATE request/reply frames, address types, UDP datagram header) **plus** a per-connection state machine driving those codecs from event-loop callbacks.
- **`socks4`** (internal) — SOCKS4/4a wire codecs (CONNECT request/reply, the 4a domain-name extension) plus its own per-connection state machine.
- **`resolver`** (internal) — a bounded worker pool that performs blocking DNS resolution and outbound `connect()` off the event-loop thread, reporting the resulting connected socket back via a channel the event loop polls.
- **`cmd/vlang-socks`** — thin CLI binary wrapping `socks.serve()`.

**Concurrency model:** a single `picoev` event loop (`vlib/picoev`, epoll on Linux / kqueue on macOS+BSD / `select()` on Windows — backend chosen automatically by picoev per-platform, no branching needed in this codebase) owns the accept loop and all established-connection I/O, including UDP relay sockets, registered via picoev's raw (non-HTTP) callback mode. Threads are used only inside the `resolver` pool, and only for the resolve+connect phase of a single request — never for a connection's sustained relay lifetime. This replaces a simpler thread-per-connection design that was rejected because V's `spawn` maps to real OS threads with no lightweight-scheduler alternative, which doesn't scale well for a proxy server; picoev is V's own event-loop primitive (it backs the `veb` web framework) and lets one thread serve many concurrent connections. Windows support comes from picoev's `select()`-based backend there, which is functional (used by `veb` on Windows today) but is the least optimized of the three and has a lower practical connection ceiling (~4096 fds) than epoll/kqueue — an accepted, documented v1 limitation rather than a blocker.

Per-connection state is an explicit state machine (`awaiting_handshake` → `awaiting_auth` → `awaiting_request` → `awaiting_resolve` → `awaiting_connect` → `relaying` → `closing`), re-entered on each readable/writable event for that connection's fd(s). The first read on a freshly accepted connection fills a per-connection buffer; byte 0 (`0x04` vs `0x05`) selects which state machine (`socks4` vs `socks5`) owns the connection from then on — this replaces any need to "peek" a byte off a blocking stream, since the event loop already buffers incoming bytes as part of normal operation.

Once a `CONNECT` request is fully parsed, the connection's target address is handed to the `resolver` pool (if `resolve_mode == .server_side` and the target is a domain name) for resolution and connection; the pool reports back a connected socket (or failure) via a channel, and the state machine registers that socket with the event loop and transitions to `relaying`, at which point bytes are copied in both directions as read/write events fire on either fd, until either side closes.

## Public API

```v
// --- Shared types ---

pub enum SocksVersion {
    v4
    v4a
    v5
}

pub enum ResolveMode {
    server_side   // default: send/accept domain names as-is, proxy resolves
    client_side   // dialer resolves domain locally before sending an IP
}

// Auth is a sum type shared by client and server config.
pub type Auth = NoAuth | UserPassAuth

pub struct NoAuth {}

pub struct UserPassAuth {
pub:
    user string
    pass string
}

pub fn no_auth() Auth { return NoAuth{} }
pub fn user_pass_auth(user string, pass string) Auth { return UserPassAuth{user, pass} }

// --- Errors ---

// Direction: "remote" variants are only ever parsed from a peer's SOCKS reply code.
// "local" variants are only ever raised by our own code and never come from a peer's reply byte.
pub enum SocksErrorCode {
    general_failure             // remote: REP=0x01 / CD=91
    connection_not_allowed      // remote
    network_unreachable         // remote
    host_unreachable            // remote
    connection_refused          // remote
    ttl_expired                 // remote: REP=0x06, far-end hop count exceeded
    command_not_supported       // remote
    address_type_not_supported  // remote
    auth_failed                 // remote: username/password rejected (RFC1929 STATUS != 0)
    auth_method_not_acceptable  // remote: METHOD=0xFF
    protocol_error              // local: malformed/unexpected bytes from peer
    fragmentation_not_supported // local: UDP datagram had FRAG != 0x00
    local_timeout               // local: our own dial/read/write exceeded a deadline
    internal_error              // local: our mapping/logic couldn't classify the failure
}

pub struct SocksError {
pub:
    kind   SocksErrorCode
    detail string     // e.g. "host example.com:443", "bad ATYP 0x07"
    cause  ?IError    // wrapped OS-level error, when this wraps a lower-level failure
}

pub fn (e SocksError) msg() string {
    if c := e.cause {
        return '${e.detail}: ${c.msg()}'
    }
    return e.detail
}

pub fn (e SocksError) code() int {
    return int(e.kind)
}

// --- Server ---

pub struct ServerConfig {
pub mut:
    addr             string = ':1080'
    auth             Auth = no_auth()
    allow_udp        bool = true
    resolve_mode     ResolveMode = .server_side
    versions         []SocksVersion = [.v4, .v4a, .v5]
    resolver_threads int = 8   // size of the bounded DNS-resolve/connect worker pool
}

// ServerHandle controls a running server started by spawn_serve.
pub struct ServerHandle {}

// stop signals the event loop and resolver pool to shut down and closes the listener.
pub fn (mut h ServerHandle) stop() {}

// wait blocks until the event-loop thread exits (after stop() or a fatal error).
pub fn (mut h ServerHandle) wait() {}

// spawn_serve starts the listener and event loop without blocking, returning a handle
// the caller can use to stop the server later (e.g. in tests, or graceful shutdown).
// Returns an error (not a SocksError) if the config is invalid (e.g. .v4a without .v4)
// or the listener fails to bind.
pub fn spawn_serve(cfg ServerConfig) !ServerHandle {}

// serve is a thin blocking wrapper: pub fn serve(cfg ServerConfig) ! { mut h := spawn_serve(cfg)!  h.wait() }
pub fn serve(cfg ServerConfig) ! {}

// --- Client ---

pub struct ClientConfig {
pub mut:
    proxy_addr   string
    version      SocksVersion = .v5
    auth         Auth = no_auth()
    resolve_mode ResolveMode = .server_side
}

// dial connects through the proxy (speaking cfg.version) and returns a standard TCP
// connection to target_addr.
pub fn dial(cfg ClientConfig, target_addr string) !net.TcpConn {}

pub struct UdpSession {
    // wraps the UDP relay socket and the control TCP connection.
}

pub fn (mut s UdpSession) write_to(addr string, data []u8) ! {}
pub fn (mut s UdpSession) read_from() !(string, []u8) {}
pub fn (mut s UdpSession) close() {}

pub fn udp_associate(cfg ClientConfig) !UdpSession {}
```

Notes:
- `dial()` returns a plain `net.TcpConn` so it drops directly into any code that already accepts one.
- `ClientConfig.version` selects which protocol `dial()`/`udp_associate()` speaks to the proxy. `udp_associate()` returns a plain (non-`SocksError`) config error if `cfg.version != .v5`, since SOCKS4/4a have no UDP ASSOCIATE command.
- `ServerConfig.versions`: `.v4` vs `.v4a` are distinguished by request *content*, not the dispatch byte (both use `VN=4`) — a plain SOCKS4 request has a real `DSTIP`; a 4a request signals `DSTIP=0.0.0.x` plus a trailing domain name. Enabling `.v4a` without `.v4` is an invalid config, rejected at `serve()`/`spawn_serve()` startup as a plain (non-`SocksError`) config error. If a connection uses the 4a extension while only `.v4` is enabled, the server rejects it with `address_type_not_supported`.
- The CLI never exposes `resolve_mode`; the mini server always uses the default `.server_side` behavior. Library users can set `.client_side` on either `ServerConfig` or `ClientConfig` to disable server-side DNS resolution for that side.
- `ServerConfig.resolver_threads` bounds the DNS-resolve/connect worker pool (see Architecture); it does not bound total concurrent connections, which are handled by the single event loop.

## Data Flow

**Server connection lifecycle** (per accepted connection, driven entirely by picoev callbacks on the single event-loop thread — no per-connection coroutine or thread):
1. On the first readable event, buffer the incoming bytes and inspect byte 0. `0x04` hands the connection's state machine to the SOCKS4/4a handler, `0x05` to the SOCKS5 handler, provided the corresponding version is enabled in `ServerConfig.versions`; otherwise (unsupported byte, or a disabled version) the connection is closed with `protocol_error`.
2. **SOCKS5**: negotiate the auth method (no-auth or user/pass, per `ServerConfig.auth`) — if the client offers no acceptable method, reply `METHOD=0xFF` and close (`auth_method_not_acceptable`); if user/pass, verify credentials and reply success/failure (`auth_failed` on mismatch) — then read the command request (CONNECT or UDP ASSOCIATE; BIND and any other CMD → `command_not_supported`). For CONNECT: hand the target address to the `resolver` pool (per `resolve_mode`); on a successful callback, register the resulting socket with the event loop and transition to `relaying`, copying bytes bidirectionally between client and target fds as read/write events fire on either, until either side closes. For UDP ASSOCIATE (only if `allow_udp`): open a UDP relay socket, register it with the event loop, reply with its bound address/port, then forward datagrams both ways as they arrive — rejecting any datagram with `FRAG != 0x00` as `fragmentation_not_supported`, and dropping datagrams from any source other than the client's observed address — until the control TCP connection closes, at which point the relay socket is deregistered and torn down.
3. **SOCKS4/4a**: read the single fixed-format CONNECT request (real `DSTIP`, or the 4a `0.0.0.x` marker plus a trailing domain name) → hand off to the `resolver` pool → on success, register the target socket and transition to `relaying` as above. The USERID field is read (bounded by a max-length guard) and ignored — no identd check is performed. No auth, no UDP (per protocol).
4. Any protocol violation or downstream resolve/connect failure maps to a `SocksError`; the server-side REP/CD mapping table converts its `kind` to the appropriate SOCKS5 REP byte, or the collapsed SOCKS4 CD byte (see Error Handling), before closing the connection.

**Client dial flow** (`dial()`): connect to `proxy_addr` → send version/auth negotiation for `cfg.version` → perform auth if configured → send a CONNECT request for `target_addr` (as a domain name or a pre-resolved IP, depending on `resolve_mode`) → on a failure reply, parse the REP/CD byte back into the matching `SocksErrorCode` and return it wrapped in a `SocksError`; on success, return the underlying `net.TcpConn`. `dial()` is a blocking client-side call (there is no event loop on the client side — only the server multiplexes connections), so it uses ordinary blocking socket calls with deadlines, same as before.

**Client UDP flow** (`udp_associate()`): connect the control TCP channel → send a UDP ASSOCIATE request → server replies with the relay address → client opens its own UDP socket to that address and transparently wraps/unwraps the SOCKS5 UDP header in `write_to`/`read_from` (FRAG always `0x00`, since fragmentation isn't supported on the send side either). Closing the returned `UdpSession` closes the control connection, which tears down the relay server-side.

## Error Handling

Errors are represented as `SocksError` (a struct implementing V's `IError` via `msg()`/`code()`), not a bare enum — this is what lets `SocksError` be used directly as the propagated error in `!T` returns.

- `kind` is a `SocksErrorCode`, split into remote-reported variants (parsed from a peer's SOCKS reply/CD byte — e.g. `host_unreachable`, `auth_failed`) and local-only variants (raised by our own code, never from a peer's reply byte — e.g. `protocol_error`, `local_timeout`, `fragmentation_not_supported`, `internal_error`). See the doc comment on `SocksErrorCode` in the API section for the full breakdown.
- `general_failure` (remote, REP=0x01) is distinct from `internal_error` (local, our own mapping logic giving up) — callers can distinguish "the far end said generic failure" from "we couldn't classify this."
- `ttl_expired` (remote, REP=0x06) is distinct from `local_timeout` (local, our own dial/read/write deadline firing) — these are different failure classes and must not be conflated.
- Every `SocksError` carries a `detail` string for context (which host, what malformed byte) and an optional wrapped `cause IError` so lower-level OS errors (failed dial, read, write) are preserved, not discarded.
- The server-side REP/CD mapping table is the single source of truth converting a `SocksErrorCode` to the wire-level reply byte, shared by both the SOCKS4 and SOCKS5 handlers so they don't duplicate that logic.
- **SOCKS4/4a CD collapse**: SOCKS4 only defines CD 90 (granted), 91 (rejected or failed), 92/93 (identd-related, unused here since identd isn't implemented). Every remote-mappable `SocksErrorCode` that SOCKS5 distinguishes (`general_failure`, `connection_not_allowed`, `network_unreachable`, `host_unreachable`, `connection_refused`, `ttl_expired`, `command_not_supported`, `address_type_not_supported`) collapses to CD=91 on the SOCKS4/4a wire — the protocol has no finer granularity to preserve. Local-only variants (`protocol_error`, `fragmentation_not_supported`, `local_timeout`, `internal_error`, `auth_failed`, `auth_method_not_acceptable` — the latter two never apply to SOCKS4 anyway, which has no auth) that occur before a request is fully parsed result in the connection being closed with no reply at all, matching SOCKS5's behavior for unparseable input.
- Config-level errors (e.g. `.v4a` enabled without `.v4`, `.udp_associate()` called with a non-`.v5` `ClientConfig`, listener bind failure) are plain V errors, not `SocksError` — they represent a misconfiguration caught at `serve()`/`spawn_serve()`/call-time, not a protocol-level failure during a connection.

## Testing

**Unit tests** (`*_test.v`, pure byte-buffer round-trips — no sockets, sub-second budget):
- `socks5_test.v`:
  - Handshake: NMETHODS=0; a method list with no method the server supports → `0xFF`/`auth_method_not_acceptable`.
  - User/pass subnegotiation: ULEN=0 and/or PLEN=0 (valid, must not crash); subnegotiation VER byte != `0x01` → `protocol_error`.
  - Request frame: unsupported ATYP (e.g. `0x02`) → `address_type_not_supported`; CMD outside {1,2,3} → `command_not_supported`; domain name with length byte 0 (valid); domain length byte overrunning the buffer → `protocol_error`.
  - REP-code <-> `SocksErrorCode` mapping round-trip, both directions.
  - UDP header: FRAG=1 (low end) and FRAG=0x80 (high-bit end-of-sequence marker) both → `fragmentation_not_supported`.
  - Generic truncation fuzz: for each SOCKS5 frame type (hello, auth request, request/reply, UDP header), truncate at every byte offset and assert `protocol_error`, never a panic/hang.
- `socks4_test.v`:
  - CONNECT/reply round-trip (plain SOCKS4 + SOCKS4a), CD-code mapping.
  - Missing NULL terminator on USERID → max-length guard triggers, returns `protocol_error` (not an unbounded read).
  - SOCKS4a domain name missing its own NULL terminator → `protocol_error`.
  - `DSTIP=0.0.0.x` with no domain name bytes following → `protocol_error` (malformed 4a).
- `server_dispatch_test.v`: first-byte version dispatch — a byte that's neither `0x04` nor `0x05` → `protocol_error`, connection closed, no panic.
- `fuzz_test.v`: a seeded, deterministic fuzz harness (10,000 iterations per parser) over the same set of parsers, using two strategies: pure random byte buffers (0-300 bytes), and mutated valid frames (bit flips/insertions/deletions/truncation applied to the known-good encoded frames from the round-trip tests). The only acceptable outcomes are a successful decode or a `SocksError` return; a panic fails the test and prints the seed and input bytes for reproduction. No per-call timeout is needed (these are pure, single-pass functions with no input-controlled unbounded loops, guaranteed by the max-length guards above); an unbounded loop found later would manifest as a timeout on the overall test function.

**Integration tests** (`socks_test.v`, real `spawn_serve()` instances on `127.0.0.1:0` driven by `dial()`/`udp_associate()`, each stopped via `ServerHandle.stop()`/`wait()` in a test-cleanup step so no event-loop thread or listener leaks past its test; capped at 7 scenarios to stay well under a 30s total budget; every read/dial uses an explicit 1-2s deadline, never a bare blocking read):
1. Plain CONNECT through SOCKS5 (no-auth) to a local echo listener.
2. CONNECT through SOCKS5 with username/password, both correct and incorrect credentials.
3. CONNECT through SOCKS4 and SOCKS4a to a local echo listener.
4. UDP ASSOCIATE happy path: exchange datagrams via the relay.
5. UDP ASSOCIATE teardown: close the control connection, then assert (bounded wait) that a subsequent send fails rather than hangs.
6. One fragmented UDP datagram sent through a live relay → bounded wait for `fragmentation_not_supported` (confirms the live relay surfaces the error, not just the parser).
7. Connect to a closed port → expect `host_unreachable`/`connection_refused` per protocol.

## Implementation Risk / Spike Plan

Before writing the full implementation plan, two V-specific risks should be validated with small throwaway programs, since the design depends on both:
1. **`cause ?IError` as a struct field**: confirm it compiles and unwraps (`if c := e.cause { ... }`) cleanly on the target V version — some V versions have had cgen issues with Option-typed struct fields.
2. **picoev + resolver-pool handoff**: confirm a minimal `picoev` raw-callback server that accepts a connection, reads a few bytes, hands an address to a worker-pool thread for `resolve()`+`connect()`, and receives the connected socket back via a channel for registration with the event loop — actually works end-to-end — before committing the full state-machine design to this pattern.

If either spike fails, fall back accordingly: a `cause` stored as a formatted string instead of `?IError`, or (if picoev's handoff pattern proves unworkable) revisit the concurrency model.

## CLI

A thin binary at `cmd/vlang-socks/main.v`, wrapping `socks.serve()` with no logic beyond flag parsing:

```
vlang-socks serve [--addr :1080] [--user NAME --pass PASS] [--no-udp] [--versions 4,4a,5]
```

- `--addr` — listen address, default `:1080`.
- `--user`/`--pass` — if both given, configures `UserPassAuth`; if omitted, no-auth. Only one credential pair is supported via the CLI (multi-credential setups are a library-only concern).
- `--no-udp` — sets `allow_udp = false`; UDP is enabled by default.
- `--versions` — comma-separated subset of `{4, 4a, 5}`, default all three; parsed into `[]SocksVersion` and passed straight to `ServerConfig.versions`. `4a` without `4` is rejected before attempting to bind.
- No `--resolve-mode` flag: the CLI always uses the default `.server_side` resolve mode.
- Prints the bound address on startup and logs one line per accepted connection (protocol version, source, target) to stdout. No structured logging, no config file, no daemonization — this binary exists as a working example and manual-testing tool, not a production deployment target.
- Uses V's standard `flag` module; invalid flags or a `serve()` startup failure print the error and exit non-zero.

## RFC Verification

Design details were checked against source specs during review:
- RFC 1928 (SOCKS Protocol Version 5) — handshake, request/reply formats, ATYP values, REP codes, UDP ASSOCIATE header and lifecycle.
- RFC 1929 (Username/Password Authentication for SOCKS V5) — subnegotiation format.
- SOCKS4 protocol spec (openssh.org/txt/socks4.protocol) — CONNECT request/reply format, CD codes, USERID field.
- SOCKS4A protocol spec (openssh.org/txt/socks4a.protocol) — domain-name signaling via `DSTIP=0.0.0.x` and trailing domain name.

All wire-format details in this spec match these sources.
