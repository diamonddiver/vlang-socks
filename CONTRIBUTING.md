# Contributing to vlang-socks

## Platform Support

This library is actively developed and tested on **Linux** (amd64 and arm64). The library architecture supports Windows (amd64), but runtime behavior is not verified on Windows — contributions that test or fix Windows-specific issues are welcome but should be clearly marked.

macOS is untested. If you encounter issues on macOS, please open an issue with details.

## Local Setup

### With Docker (recommended, no local V needed)

```sh
make test-all       # run full test suite
make vet            # run fmt-verify + vet (what CI checks)
make fmt            # auto-format code
make shell          # interactive dev shell
```

The host needs only Docker (and `sudo` — the daemon is not in the docker group on this host).

### Without Docker (DOCKER=0, requires V + cross-toolchain)

```sh
make test-all DOCKER=0
make vet DOCKER=0
make lib DOCKER=0
```

You need V 0.4.8+ with the C/aarch64/mingw toolchains for cross-compilation. See the `Dockerfile` dev stage for the exact build dependencies.

## Testing

- **Run one module:** `make test MODULE=socks5`
- **Run all modules:** `make test-all`
- **Run C ABI tests:** `make test-capi`
- **Run fuzzer:** `make test MODULE=. && make test MODULE=cmd/vlang-socks` (includes fuzz_test.v)

All tests must pass locally before opening a PR.

## Code Style

V code is auto-formatted via `make fmt`. Run this before committing. The CI checks `v fmt -verify` and `v vet`.

## Commit Messages

Follow conventional commits:
- `feat: ...` for new features
- `fix: ...` for bug fixes
- `refactor: ...` for code reorganization without behavior change
- `chore: ...` for build/config/metadata changes
- `docs: ...` for documentation

Example: `fix(server): handle UDP idle timeout correctly`

## Reporting Issues

Before opening an issue, check [LIMITATIONS.md](LIMITATIONS.md) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — they document known scope limits and common problems.

When reporting a bug:
- State the platform (Linux/amd64, Linux/arm64, Windows, macOS)
- Include the output of `v version`
- Provide a minimal reproduction case
- Mention whether you're testing the V library, C ABI, or both

## Pull Requests

- Reference any related issues
- Include a short description of what changed and why
- Ensure `make vet` and `make test-all` pass
- Keep PRs focused — one feature or fix per PR

## Security

See [LIMITATIONS.md](LIMITATIONS.md) for the library's security model and hardening gaps. The library is designed for well-behaved clients on trusted networks. Report security issues privately (do not open public issues for vulnerabilities).
