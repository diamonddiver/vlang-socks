# Changelog

All notable changes to vlang-socks are documented here. Versioning follows [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-07

Initial release: SOCKS4/4a/5 client and server for V with C ABI.

### Added

- SOCKS4, SOCKS4a, SOCKS5 client and server support
- SOCKS5 username/password authentication
- UDP ASSOCIATE relay
- Non-blocking event-loop server with backpressure, idle timeout, handshake timeout, connection cap, and per-dial timeout
- C ABI (`libsocks`) with generated header, pkg-config file, and static/shared builds for Linux/amd64, Linux/arm64, Windows/amd64
- Cross-platform containerized build via Docker
- CI/CD via GitHub Actions
- Examples in C and Python (ctypes)

### Known Limitations

See [LIMITATIONS.md](LIMITATIONS.md) for v1 scope and hardening trade-offs:
- Event loop has no cancel primitive; threads may run in background after `stop()`
- UDP ASSOCIATE: first datagram defines the client; no independent verification
- UDP fragmentation not supported
- No egress/SSRF filtering or per-source rate limiting (deploy behind a rate-limiter)
- Server not hardened for untrusted clients without `idle_timeout` and rate limiting

[0.1.0]: https://github.com/diamonddiver/vlang-socks/releases/tag/0.1.0
