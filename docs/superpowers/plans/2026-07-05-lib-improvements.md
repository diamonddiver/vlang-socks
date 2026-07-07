# vlang-socks: library-improvement implementation plan

Status: awaiting maintainer approval (plan-first). Produced 2026-07-05 from a
verified 7-dimension audit + a 4-workstream design pass. Every non-obvious
V/picoev/vlib claim below was checked by compiling/running probes against the
pinned V 0.4.8 toolchain (the `vlang-socks-dev` image), not reasoned on paper.

## Scope: four workstreams

- **A - Quick wins** (effort S): CI, dead error-code raise, buffer reuse, v.mod metadata.
- **B - V consumption** (effort M): flatten module to repo root so `v install` + `import socks` work; publishing metadata; public error helpers.
- **C - C-ABI + packaging** (effort M): make `libsocks.{so,a,dll}` actually callable from C/Python/Go/Rust.
- **D - Loop-stall + timeouts** (effort L): non-blocking relay writes + backpressure; idle_timeout; connect_timeout.

## Key verified findings (these de-risk the plan)

- **C / runtime init**: `v -shared` emits an `__attribute__((constructor)) _vinit_caller` that runs `_vinit()` automatically on dlopen — proven end-to-end (dlopen from bare C, drove a real SOCKS5 handshake). BUT `GC_INIT()` is only emitted inside V's dead `main()`, so a mandatory `socks_init()` must call `$if gcboehm ? { C.GC_INIT() }`.
- **C / symbol hygiene**: the `.so` exports 1846 mangled `socks__*` symbols. A `socks_*` version-script glob would still match them (mangling is `module__func`). Must enumerate exact symbols. Verified: enumerated list drops exports 1846 -> ~13.
- **C / pre-existing bug**: `build-lib.sh` never archives V's bundled `gc.c` into `libsocks.a`, so the static lib is currently unlinkable (missing `GC_malloc`, etc.). Plan fixes it; afterward only `-lpthread` is needed (not `-lgc -latomic -lm`) on glibc/x86_64.
- **C / no SONAME**: `.so` has no `DT_SONAME`; add via `-ldflags -Wl,-soname`. `v -shared -o` appends its own `.so` suffix, so the versioned-filename chain is built with `mv`+`ln -sf` after the build. Windows `.dll` PE exports are opt-in (already clean) — SONAME/version-script are ELF-only.
- **B / module resolution**: V resolves `import socks` by a literal child directory named `socks`, NOT by v.mod's `name`. Flattening to root breaks the CLI's own `import socks` unless a committed `socks -> .` self-symlink exists. `v install --git` derives the install dir from v.mod `name` ('socks'), so the repo can stay named `vlang-socks`.
- **B / vmod schema**: the parser only recognizes `name/version/description/dependencies/license/repo_url/author`. There is **no `vcs` or `tags`** key (they'd be silently ignored). So A4's `vcs`/`tags` are dropped.
- **B / error helper**: `as_socks_error` returning the pub alias hits the same documented V 0.4.8 cgen bug as `err as SocksError`. Only scalar-returning `error_kind()`/`error_detail()` are implementable.
- **D / the stall mechanism**: `TcpConn.write()` is not a single non-blocking syscall — on EAGAIN it calls a BLOCKING `select()` gated by the socket's (infinite) write deadline. That IS the loop stall. Fix binds raw `C.send(..., MSG_DONTWAIT|MSG_NOSIGNAL)` for byte-exact partial writes.
- **D / busy-spin trap**: picoev EPOLLOUT is level-triggered — write interest must be disarmed the instant a queue empties or the loop pegs 100% CPU. Re-arm/disarm via repeated `pv.add(fd, events, ...)` (does EPOLL_CTL_MOD).
- **D / connect_timeout honesty**: vlib has no cancellation primitive for a stuck `getaddrinfo`/`connect`. The timeout frees the worker-pool *slot* but the stuck OS thread keeps running until the kernel gives up. Documented as an accepted limitation.
- **A / CI**: `v symlink` needs root (fails on the runner) — add V to `$GITHUB_PATH`. Bootstrap V from the exact Dockerfile commit pins (V 0.4.8, VC_COMMIT 54beb1f...). Verified: bootstrap ~33s, `make vet/test-all DOCKER=0` green in ~8s.

## Rollout sequence (conflict-aware)

The two worst merge hazards are eliminated by *folding*, so `server.v` and
`resolver.v` each have exactly one owner:

- **A1** (shared 64KiB relay_buf + non-cloning `read_some`) folds INTO **D** (D owns `server.v`).
- **A3b** (resolver `classify()` else -> `internal_error`) folds INTO **D** (D owns `resolver.v`).
- **A4** (v.mod fields) folds INTO **B** (B owns `v.mod`, with the schema-correct field set).

Phases:

- **Phase 0 (integrator):** commit the current uncommitted working tree as `baseline` (it already contains handshake_timeout/max_connections/Dockerfile work from a prior session, so D must not re-implement it); `chown` `socks/server.v` off root:root so agents can edit it; confirm `make vet DOCKER=0 && make test-all DOCKER=0` green.
- **Phase 1 (2 parallel Sonnet worktrees, file-disjoint):**
  - **ws-A**: `.github/workflows/ci.yml`; `client.v` read_exact -> `.local_timeout`; `LIMITATIONS.md` bullet rescope.
  - **ws-D**: non-blocking `try_send` + per-direction outbound queues + backpressure + write-interest sync (with A1 folded); `idle_timeout` + `last_activity` + extended `sweep_timeouts`; `connect_timeout` + resolver `run_with_timeout` (with A3b folded); UDP write `no_timeout`; new `server_backpressure_test.v`.
  - Disjoint: A = client.v/.github/LIMITATIONS; D = server.v/server_udp.v/reexport.v/resolver/tests.
- **Phase 2 (serial):** **ws-B** flatten to root (glob `git mv` so it captures D's new test file), `socks -> .` symlink, Makefile/Dockerfile/build-lib.sh path args, v.mod `repo_url`+`author`, `error_kind`/`error_detail` + tests.
- **Phase 3 (serial):** **ws-C** `capi.v`, `scripts/libsocks.map` (exact symbols), `include/socks.h`, `socks.pc.in`, build-lib.sh (gc.c fix + soname/version-script + versioned chain), Makefile `install`/example targets, `examples/c` + `examples/python`, `capi_test.v`.

B is last because a content-free `git mv` on top of already-merged code is a
clean linear rename (blame preserved); flattening first would force the riskiest
work to be re-authored against moved paths. C is after B (needs the flat layout;
edits the same build-lib.sh/Makefile lines).

## Execution model (the "heavy workflow")

Opus integrator (main loop) drives; Sonnet agents implement. Phase 1's two
agents run concurrently in isolated worktrees; Phases 2-3 serial. Each agent's
acceptance GATE is real build/test, not self-report:

- ws-A: `make vet/test-all DOCKER=0` green; read_exact returns `.local_timeout` on a forced 50ms deadline; CI yaml lint-clean.
- ws-D: `make vet/test-all DOCKER=0` green incl. `test_slow_target_does_not_stall_other_connections` (2nd proxied conn < 500ms while 1st is stalled), idle_timeout sweep tests, connect_timeout pool-slot-free test, resolver->internal_error test, all `resolver.new()` call sites updated; MANUAL no-busy-spin CPU check.
- ws-B: vet/test-all green on the new layout + `make lib-all` + `make build && make run` boots + EXTERNAL-CONSUMER proof (a disjoint `import socks; import socks.core` program compiles via `$VMODULES`/`v install --git`) + `git log --follow` shows renames detected.
- ws-C: `nm -D` exports 1846 -> ~13 with zero `socks__`, SONAME=libsocks.so.0, `libsocks.a` links a C program with only `-lpthread`, `make install` + `pkg-config` works, `examples/c` + `examples/python` round-trip.

## Open decisions for the maintainer

1. **v.mod identity**: real `repo_url` (GitHub org/URL) + `author` (name/email). No git remote configured.
2. **`socks -> .` self-symlink**: the only confirmed mechanism to keep in-repo `import socks` resolving post-flatten. Accept the committed symlink?
3. **D behavior defaults**: `idle_timeout` (0/disabled proposed), `connect_timeout` (30s vs 0/disabled), `relay_hwm` 256KiB (no config knob in v1), and best-effort (non-queued) terminal SOCKS reply writes (a real change from "always eventually delivered, at the cost of loop hang" to "never hangs, may rarely truncate a graceful error reply").
4. **C public ABI**: `socks_*` names/signatures, `socks_init()`-first contract, u64 opaque handles, `socks_dial` raw-fd ownership transfer become a stability contract once released.
