# vlang-socks

A SOCKS4/4a/5 client and server library for [V](https://vlang.io), with a C
ABI for use from other languages.

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

## Server

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
```

Run `make help` for the full target list.

## License

MIT, see [LICENSE](LICENSE).
