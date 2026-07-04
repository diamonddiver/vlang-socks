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

## Architecture

A single module `socks` with internal sub-packages for protocol-specific wire logic:

- **`socks`** (public API) — `serve()`, `dial()`, `udp_associate()`, config structs (`ServerConfig`, `ClientConfig`, `Auth`, `ResolveMode`, `SocksVersion`), and the `SocksError` type. This is the only import most users need.
- **`socks5`** (internal) — SOCKS5 wire protocol: handshake/method negotiation, username/password subnegotiation, CONNECT and UDP ASSOCIATE request/reply frames, address types (IPv4/IPv6/domain), UDP datagram header.
- **`socks4`** (internal) — SOCKS4/4a wire protocol: CONNECT request/reply, the 4a domain-name extension (`DSTIP=0.0.0.x` + trailing domain).
- **`cmd/vlang-socks`** — thin CLI binary wrapping `socks.serve()`.

The server inspects the first byte of each accepted connection (`0x04` vs `0x05`) to dispatch to the right internal handler, so one server/port can serve SOCKS4, SOCKS4a, and SOCKS5 clients simultaneously (subject to which versions are enabled in `ServerConfig.versions`).

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
    addr         string = ':1080'
    auth         Auth = no_auth()
    allow_udp    bool = true
    resolve_mode ResolveMode = .server_side
    versions     []SocksVersion = [.v4, .v4a, .v5]
}

// serve blocks, accepting connections and spawning a coroutine per connection.
// Returns an error (not a SocksError) if the config is invalid (e.g. .v4a without .v4)
// or the listener fails to bind.
pub fn serve(cfg ServerConfig) ! {}

// --- Client ---

pub struct ClientConfig {
pub mut:
    proxy_addr   string
    auth         Auth = no_auth()
    resolve_mode ResolveMode = .server_side
}

// dial connects through the proxy and returns a standard TCP connection to target_addr.
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
- `ServerConfig.versions`: `.v4` vs `.v4a` are distinguished by request *content*, not the dispatch byte (both use `VN=4`) — a plain SOCKS4 request has a real `DSTIP`; a 4a request signals `DSTIP=0.0.0.x` plus a trailing domain name. Enabling `.v4a` without `.v4` is an invalid config, rejected at `serve()` startup as a plain (non-`SocksError`) config error. If a connection uses the 4a extension while only `.v4` is enabled, the server rejects it with `address_type_not_supported`.
- The CLI never exposes `resolve_mode`; the mini server always uses the default `.server_side` behavior. Library users can set `.client_side` on either `ServerConfig` or `ClientConfig` to disable server-side DNS resolution for that side.

## Data Flow

**Server connection lifecycle** (per accepted TCP connection, each handled in its own `spawn`ed coroutine):
1. Peek the first byte. `0x04` routes to the SOCKS4/4a handler, `0x05` to the SOCKS5 handler, provided the corresponding version is enabled in `ServerConfig.versions`; otherwise (unsupported byte, or a disabled version) the connection is closed with `protocol_error`.
2. **SOCKS5**: negotiate the auth method (no-auth or user/pass, per `ServerConfig.auth`) — if the client offers no acceptable method, reply `METHOD=0xFF` and close (`auth_method_not_acceptable`); if user/pass, verify credentials and reply success/failure (`auth_failed` on mismatch) — then read the command request (CONNECT or UDP ASSOCIATE; BIND and any other CMD → `command_not_supported`). For CONNECT: resolve the address per `resolve_mode` and dial the target, then splice bytes bidirectionally between client and target sockets until either side closes. For UDP ASSOCIATE (only if `allow_udp`): open a UDP relay socket, reply with its bound address/port, then forward datagrams both ways — rejecting any datagram with `FRAG != 0x00` as `fragmentation_not_supported`, and dropping datagrams from any source other than the client's observed address — until the control TCP connection closes, at which point the relay socket is torn down.
3. **SOCKS4/4a**: read the single fixed-format CONNECT request (real `DSTIP`, or the 4a `0.0.0.x` marker plus a trailing domain name) → dial target → splice bytes bidirectionally. The USERID field is read (bounded by a max-length guard) and ignored — no identd check is performed. No auth, no UDP (per protocol).
4. Any protocol violation or downstream dial failure maps to a `SocksError`; the server-side REP/CD mapping table converts its `kind` to the appropriate SOCKS5 REP byte or SOCKS4 CD byte before closing the connection.

**Client dial flow** (`dial()`): connect to `proxy_addr` → send version/auth negotiation → perform auth if configured → send a CONNECT request for `target_addr` (as a domain name or a pre-resolved IP, depending on `resolve_mode`) → on a failure reply, parse the REP/CD byte back into the matching `SocksErrorCode` and return it wrapped in a `SocksError`; on success, return the underlying `net.TcpConn`.

**Client UDP flow** (`udp_associate()`): connect the control TCP channel → send a UDP ASSOCIATE request → server replies with the relay address → client opens its own UDP socket to that address and transparently wraps/unwraps the SOCKS5 UDP header in `write_to`/`read_from` (FRAG always `0x00`, since fragmentation isn't supported on the send side either). Closing the returned `UdpSession` closes the control connection, which tears down the relay server-side.

## Error Handling

Errors are represented as `SocksError` (a struct implementing V's `IError` via `msg()`/`code()`), not a bare enum — this is what lets `SocksError` be used directly as the propagated error in `!T` returns.

- `kind` is a `SocksErrorCode`, split into remote-reported variants (parsed from a peer's SOCKS reply/CD byte — e.g. `host_unreachable`, `auth_failed`) and local-only variants (raised by our own code, never from a peer's reply byte — e.g. `protocol_error`, `local_timeout`, `fragmentation_not_supported`, `internal_error`). See the doc comment on `SocksErrorCode` in the API section for the full breakdown.
- `general_failure` (remote, REP=0x01) is distinct from `internal_error` (local, our own mapping logic giving up) — callers can distinguish "the far end said generic failure" from "we couldn't classify this."
- `ttl_expired` (remote, REP=0x06) is distinct from `local_timeout` (local, our own dial/read/write deadline firing) — these are different failure classes and must not be conflated.
- Every `SocksError` carries a `detail` string for context (which host, what malformed byte) and an optional wrapped `cause IError` so lower-level OS errors (failed dial, read, write) are preserved, not discarded.
- The server-side REP/CD mapping table is the single source of truth converting a `SocksErrorCode` to the wire-level reply byte, shared by both the SOCKS4 and SOCKS5 handlers so they don't duplicate that logic.
- Config-level errors (e.g. `.v4a` enabled without `.v4`, listener bind failure) are plain V errors, not `SocksError` — they represent a misconfiguration caught at `serve()` startup, not a protocol-level failure during a connection.

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

**Integration tests** (`socks_test.v`, real `serve()` instances on `127.0.0.1:0` driven by `dial()`/`udp_associate()`; capped at 7 scenarios to stay well under a 30s total budget; every read/dial uses an explicit 1-2s deadline, never a bare blocking read):
1. Plain CONNECT through SOCKS5 (no-auth) to a local echo listener.
2. CONNECT through SOCKS5 with username/password, both correct and incorrect credentials.
3. CONNECT through SOCKS4 and SOCKS4a to a local echo listener.
4. UDP ASSOCIATE happy path: exchange datagrams via the relay.
5. UDP ASSOCIATE teardown: close the control connection, then assert (bounded wait) that a subsequent send fails rather than hangs.
6. One fragmented UDP datagram sent through a live relay → bounded wait for `fragmentation_not_supported` (confirms the live relay surfaces the error, not just the parser).
7. Connect to a closed port → expect `host_unreachable`/`connection_refused` per protocol.

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
