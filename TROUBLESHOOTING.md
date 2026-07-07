# Troubleshooting

**Most issues:** run tests via `make test` / `make test-all` (never bare `v`) and prefix Docker with `sudo`. If that doesn't cover it, jump to your section:

[Test failures](#test-failures) · [Docker / permissions](#docker--permissions) · [Platforms](#platforms-tested) · [Build / compilation](#build--compilation) · [UDP relay](#udp-relay)

---

## Test failures

**UDP tests hang, or `set_read_timeout()` never returns.**

- **Cause:** vlib only makes sockets non-blocking under the `net_nonblocking_sockets` guard.
- **Fix:** build and test with `-d net_nonblocking_sockets`. The `make` targets already do this via `VFLAGS`. Only add it yourself if you invoke `v` directly.

**`import socks` fails to resolve (module not found).**

- **Cause:** V 0.4.8 only resolves `import socks` via a directory literally named `socks`, but the repo is `vlang-socks`.
- **Fix:** use `make test` / `make test-all`. They create an external `socks -> .` symlink and pass `-path @vlib:<dir>`.
- **Note:** do not create an in-tree self-symlink; it hits a V import-qualifier bug (type registers as both `socks.core` and `socks.socks.core`).

**`capi` tests fail with undefined global errors.**

- **Cause:** `capi/` uses globals, which V flags by default.
- **Fix:** test `capi/` with `-enable-globals`: `make test-capi`. Running `make test-all` already passes the flag when descending into `capi/`.

---

## Docker / permissions

**Error: `permission denied while trying to connect to the Docker daemon socket`.**

- **Cause:** your user is not in the `docker` group.
- **Fix:** prefix every Docker command with `sudo` (passwordless on this host):
  ```sh
  sudo make test-all
  sudo make lib
  ```

**`out/` or cache volume is owned by root, or files are inaccessible.**

- **Cause:** Docker runs as root, so output is root-owned.
- **Fix:** reset with:
  ```sh
  sudo make clean
  sudo docker volume rm vlang-socks-cache
  ```
  Or `chown` the files back if you need host read access.

**No Docker available, or you want to use the host toolchain.**

- **Fix:** run any target with `DOCKER=0`:
  ```sh
  make test-all DOCKER=0
  make lib DOCKER=0
  ```
  Your host must have `v` installed. For `lib-all`, you also need aarch64/mingw cross-toolchains.

---

## Platforms (tested)

If something fails on a non-Linux target, check here before filing a bug.

- **Linux amd64, Linux arm64:** fully tested, primary targets. All tests pass.
- **Windows amd64:** library is cross-built but not runtime-tested. Failures are expected-unknown, not regressions. Verify manually.
- **macOS:** unverified. picoev supports it, but this project is not tested on macOS.

---

## Build / compilation

**`VERSION` or SONAME comes out empty during library build.**

- **Cause:** `v.mod` is missing or malformed.
- **Fix:** ensure `v.mod` has a present, single-quoted `version: '...'` line. The Makefile greps it:
  ```
  version: '0.1.0'
  ```

**`lib-all` cross-build fails with missing toolchain errors.**

- **Cause:** aarch64/mingw toolchains are not installed on the host.
- **Fix:** either install them, or just use `DOCKER=1` (the default) so the pinned image provides them.

---

## UDP relay

**UDP datagrams to a hostname are silently dropped.**

- **Cause:** with `resolve_mode: .client_side`, domain-typed targets (ATYP=domain) are dropped because UDP has no per-datagram error channel.
- **Fix:** use server-side resolution (the default), or send IP-typed datagrams.

**UDP datagrams with `FRAG != 0` are rejected.**

- **Cause:** datagram fragmentation is unsupported by design.
- **Fix:** send unfragmented datagrams only.

**Association hijacked or relaying to wrong peer.**

- **Cause:** the first datagram on the UDP socket defines the client address. No independent verification.
- **Fix:** ensure your real client sends the first datagram. Anything from a different source is treated as target-to-client traffic.

---

See [README.md](README.md) and [LIMITATIONS.md](LIMITATIONS.md) for more context.
