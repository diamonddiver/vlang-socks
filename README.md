# vlang-socks

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md)

[![CI](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml/badge.svg)](https://github.com/diamonddiver/vlang-socks/actions/workflows/ci.yml)

A SOCKS4/4a/5 client and server library for [V](https://vlang.io), with a C
ABI for use from other languages.

**Note:** The V import is `import socks`, but the binary and repo are named
`vlang-socks`.

## Features

- SOCKS4, SOCKS4a, and SOCKS5 support (client and server)
- SOCKS5 username/password auth
- UDP ASSOCIATE
- Non-blocking event-loop server with backpressure, idle/handshake/connect
  timeouts, and a connection cap
- C ABI (`libsocks`) with a generated header, pkg-config file, and static/shared
  builds for linux/amd64, linux/arm64, and windows/amd64

See [LIMITATIONS.md](LIMITATIONS.md) for what this library does and does not
harden against before exposing it to untrusted clients.

## Quick Start

### Testing (no build needed)

Test the library locally without installing anything:

```sh
# With Docker (host needs only docker + sudo)
make test-all

# Or test one module
make test MODULE=socks5
```

All tests pass on Linux/amd64 and Linux/arm64. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
if tests fail.

## Install (V)

```sh
v install --git https://github.com/diamonddiver/vlang-socks
```

```v
import socks

cfg := socks.ClientConfig{
	proxy_addr: '127.0.0.1:1080'
	version: .v5
}
mut conn := socks.dial(cfg, 'example.com:80')!
```

## Architecture

```
Client (V/C/Python) --[SOCKS handshake]--> Proxy Server
                                               |
                                            [relay]
                                               |
                                          Target Host
```

The server accepts SOCKS4/4a/5 clients, parses handshakes, dials the target,
and relays data bidirectionally with backpressure, idle timeouts, and
connection limits. See [LIMITATIONS.md](LIMITATIONS.md) for what it does not
harden against.

## Server Example

```v
import socks

mut handle := socks.spawn_serve(socks.ServerConfig{
	addr: ':1080'
	versions: [.v5]
})!
handle.wait()
```

## C ABI

A prebuilt static/shared library plus `socks.h` and a pkg-config file are
built with `make lib` (single target) or `make lib-all` (every supported
target), output to `out/<target>/`. See `examples/c/main.c` for usage from C
and `examples/python/client.py` for usage via `ctypes`.

## Development

This project uses a containerized V toolchain, so the host only needs Docker:

```sh
make test MODULE=socks5   # test one module
make test-all             # test every module
make vet                  # what CI checks (fmt-verify + vet)
make lib                  # build the C ABI library for linux/amd64
make lib-all              # build for all supported platforms
make shell                # interactive dev shell for debugging
```

Run `make help` for the full target list.

See [CONTRIBUTING.md](CONTRIBUTING.md) for platform support, setup, and
conventions. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if tests fail.

### Cross-Compilation


The C library is built for Linux (amd64, arm64) and Windows (amd64):

```sh
make lib-all              # build for all three targets
ls out/*/libsocks.*       # outputs to out/<target>/
```

Each platform's artifacts are in `out/<platform>/` and include:
- `libsocks.a` (static)
- `libsocks.so*` (shared, Linux only)
- `libsocks.lib` / `libsocks.dll` (Windows static/dynamic)
- `socks.h` (C API header)
- `socks.pc` (pkg-config file)

Install to a target sysroot with:

```sh
make install PREFIX=/path/to/sysroot
```

**Note:** Windows/amd64 binaries are built but not runtime-tested. Linux
platforms are fully tested; macOS is untested.

No bare feet in production for real pentest. Only for redteam, until it become popular 💎

## License

MIT, see [LICENSE](LICENSE).
