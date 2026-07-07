# Makefile restructure: optional Docker + lib-all simplification

## Goal

Make the Makefile simpler to read and less error-prone, following classical
Make conventions, while preserving:

- static build support
- ability to build via Docker (unchanged default)
- multi-arch library builds (V module cache object, linux lib, windows lib)

## Non-goals

- No change to the Dockerfile, image layering, or `out/<target>/` artifact
  layout.
- No change to which artifacts `lib`/`lib-all` produce (`libsocks.<ext>`,
  `libsocks.a`, `socks.module.o`).
- Not adding new supported target platforms.

## 1. Docker becomes optional via a `DOCKER` variable

```make
DOCKER ?= 1
ifeq ($(DOCKER),1)
  RUN := sudo docker run --rm -v $(CURDIR):/src -v $(CACHE_VOL):/root/.cache -w /src $(IMAGE)
  IMAGE_DEP := image
else
  RUN :=
  IMAGE_DEP :=
endif
```

- `make test` -> containerized, identical to current behavior (default
  unchanged).
- `make test DOCKER=0` -> runs `v $(VFLAGS) test $(MODULE)` directly against
  a host-installed `v` toolchain. The host is responsible for having `v`
  (and, for `lib-all`, the aarch64/mingw cross toolchains) installed when
  using `DOCKER=0`.
- Targets that switch on `DOCKER`: `test`, `test-all`, `vet`, `fmt`, `lib`,
  `lib-all`, `all`. These only run `v`/scripts against the source tree and
  have no inherent dependency on Docker.
- Targets that stay Docker-only, unaffected by `DOCKER`: `image`, `build`,
  `run`, `shell`, `clean`. These build, run, or remove Docker images
  themselves, so a "no Docker" mode does not apply — `DOCKER=0` is ignored
  for these targets (no error, just a no-op override).
- `LIB_RUN` (used by `lib`/`lib-all`) is redefined in terms of the new `RUN`
  plus the existing `HOST_UID`/`HOST_GID` env vars, so the ownership-fixup
  behavior is unchanged in both Docker and host mode. In host mode
  (`DOCKER=0`), `HOST_UID`/`HOST_GID` become irrelevant (nothing runs as
  root), and `build-lib.sh`'s chown step is skipped since `HOST_UID` is
  unset.

## 2. Self-documenting `help` target

```make
.DEFAULT_GOAL := help
help:              ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'
```

- Running bare `make` prints the target list instead of running `image`
  (the current first target, and thus current default goal).
- The `## ` comment convention already used on every target's doc-comment is
  reused verbatim — no changes needed to existing target comments.
- The `DOCKER` variable and its default/override behavior is documented in
  a comment directly above the `DOCKER ?= 1` line (per this repo's existing
  convention of comments-above-the-relevant-line, e.g. the `VFLAGS` comment).

## 3. `build-lib.sh` argument simplification

Current: `build-lib.sh <name> <v_os> <v_arch> <cc> <objcc> <ar> <ext> <vflags> [gc_defines...]`,
invoked 3 times inline in `lib-all` (24 positional args total spread across
the Makefile).

New: `build-lib.sh <name> <vflags>`, where `name` is one of `linux_amd64`,
`linux_arm64`, `windows_amd64`. The script gains a `case "$name" in ... esac`
table that sets `v_os`/`v_arch`/`cc`/`objcc`/`ar`/`ext`/`gc_defines` for that
name — this is the same data that's currently spread across the Makefile's
`lib`/`lib-all` recipes, moved into the one place that already understands
per-target build mechanics.

Makefile shrinks to:

```make
lib: $(IMAGE_DEP)      ## Build for linux/amd64 -> out/linux_amd64/
	$(LIB_RUN) ./scripts/build-lib.sh linux_amd64 "$(VFLAGS)"

lib-all: $(IMAGE_DEP)  ## Build for every supported target -> out/<target>/
	$(LIB_RUN) sh -c 'for t in linux_amd64 linux_arm64 windows_amd64; do ./scripts/build-lib.sh $$t "$(VFLAGS)"; done'

all: lib-all           ## Alias for lib-all
```

The list of target names (`linux_amd64 linux_arm64 windows_amd64`) appears
in exactly one place in the Makefile (the `lib-all` loop) instead of being
implied by 3 separate inline invocations.

## 4. Unchanged

- `VFLAGS`, `IMAGE`/`RUNTIME`/`MODULE`/`CACHE_VOL` variable definitions.
- `image`, `build`, `run`, `shell`, `clean` target bodies.
- Dockerfile.
- `out/<target>/` artifact layout and filenames.
- `build-lib.sh`'s internal build steps (shared lib, static lib via
  `-keepc`, module-cache object, chown-back-to-host-uid).

## Testing plan

- `make help` (and bare `make`) prints the target list.
- `make test`, `make vet`, `make lib` still work containerized, producing
  the same results as before this change (regression check).
- `make lib-all` produces the same `out/*/libsocks.*` file set as before the
  `build-lib.sh` argument refactor.
- `make test DOCKER=0` runs against host `v` if available in the dev
  environment; if host `v` isn't installed here, this is a dev-environment
  constraint to note, not a code defect.
