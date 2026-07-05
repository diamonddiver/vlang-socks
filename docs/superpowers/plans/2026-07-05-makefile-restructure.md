# Makefile Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify the Makefile (optional Docker, deduplicated multi-arch lib build) without changing default behavior or output artifacts.

**Architecture:** Two independent changes to the same two files: (1) collapse `build-lib.sh`'s 8-positional-argument interface into a name-keyed `case` table inside the script, shrinking the Makefile's `lib`/`lib-all` recipes; (2) introduce a `DOCKER` make variable that switches `RUN`/`RUN_IMG`/`IMAGE_DEP` between "wrap every command in `sudo docker run`" (default) and "run directly on host" for source-only targets, while `image`/`build`/`run`/`shell`/`clean` stay hardcoded to Docker. A `help` target is added last since it only depends on existing `##` comments.

**Tech Stack:** POSIX `sh` (build-lib.sh), GNU Make (Makefile), Docker (via `sudo docker`, per this repo's CLAUDE.md).

## Global Constraints

- All Docker/Docker Compose commands must be prefixed with `sudo` (Docker daemon here is only reachable via sudo) — applies to Makefile recipes and to any verification commands run during this plan.
- Preserve exactly: static build support, ability to build via Docker (unchanged default), multi-arch library builds for `linux_amd64`, `linux_arm64`, `windows_amd64`.
- No change to the Dockerfile, image layering, or `out/<target>/` artifact layout/filenames (`libsocks.<ext>`, `libsocks.a`, `socks.module.o`).
- No new supported target platforms.
- Default behavior (`DOCKER` unset, i.e. `DOCKER=1`) must be identical to current behavior — this is a regression risk on every task.

---

### Task 1: Simplify `build-lib.sh` to a name-keyed interface

**Files:**
- Modify: `scripts/build-lib.sh`
- Modify: `Makefile:36-43` (the `lib` and `lib-all` recipes only — call-site update to match the new script signature; the surrounding `LIB_RUN`/`DOCKER_RUN` variables are untouched in this task and get restructured in Task 2)

**Interfaces:**
- Produces: `scripts/build-lib.sh <name> <vflags>` where `name` is one of `linux_amd64`, `linux_arm64`, `windows_amd64`. Replaces the old `build-lib.sh <name> <v_os> <v_arch> <cc> <objcc> <ar> <ext> <vflags> [gc_defines...]` signature. Task 2's Makefile changes call this same new signature — no further changes to the script needed there.

- [ ] **Step 1: Read the current script to confirm line numbers before editing**

Run: `cat -n scripts/build-lib.sh`

Confirm the file matches what's described below (21 lines of header/usage comment, `set -eu`, then the arg-parsing line `name=$1 v_os=$2 v_arch=$3 cc=$4 objcc=$5 ar=$6 ext=$7 vflags=$8` followed by `shift 8` and `gc_defines=$*`, then the build logic using `$os_flag`/`$arch_flag`/`$out`/etc.). If the file differs, stop and re-read this plan step against the actual content before proceeding.

- [ ] **Step 2: Replace the header comment and argument parsing**

Replace:
```sh
#!/bin/sh
# Cross-builds the `socks` module for one (os, arch) target, inside the
# vlang-socks-dev toolchain image, as three artifacts under out/<name>/:
#   libsocks.<ext>  - shared library (.so / .dll)
#   libsocks.a      - static library archive
#   socks.module.o  - V's own build-module compiled-object cache entry
#                     (not produced for the windows target, see below)
#
# Usage: build-lib.sh <name> <v_os> <v_arch> <cc> <objcc> <ar> <ext> <vflags> [gc_defines...]
#   name       output subdir under out/, e.g. linux_amd64
#   v_os       value for `v -os`   (empty string = host default)
#   v_arch     value for `v -arch` (empty string = host default)
#   cc         C compiler passed to `v -cc` for the shared-lib link
#   objcc      C compiler used to compile the static-lib object (differs
#              from `cc` only for the windows target, which needs the
#              -win32 mingw variant for the plain compile-to-object step)
#   ar         archiver for the static-lib step
#   ext        shared-library file extension (so | dll)
#   vflags     extra `v` flags (e.g. -d net_nonblocking_sockets)
#   gc_defines -D flags libgc needs for this target (varies by OS)
set -eu

name=$1 v_os=$2 v_arch=$3 cc=$4 objcc=$5 ar=$6 ext=$7 vflags=$8
shift 8
gc_defines=$*
```

With:
```sh
#!/bin/sh
# Cross-builds the `socks` module for one named target, inside the
# vlang-socks-dev toolchain image, as three artifacts under out/<name>/:
#   libsocks.<ext>  - shared library (.so / .dll)
#   libsocks.a      - static library archive
#   socks.module.o  - V's own build-module compiled-object cache entry
#                     (not produced for the windows target, see below)
#
# Usage: build-lib.sh <name> <vflags>
#   name    one of: linux_amd64 | linux_arm64 | windows_amd64
#   vflags  extra `v` flags (e.g. -d net_nonblocking_sockets)
set -eu

name=$1 vflags=$2

# Per-target build knobs. cc/objcc/ar are the C toolchain `v -shared` and the
# static-lib compile step use; gc_defines are the libgc -D flags each target
# needs (varies by OS — see the static-lib comment below for how these were
# captured).
case "$name" in
  linux_amd64)
    v_os="" v_arch="" cc=gcc objcc=gcc ar=ar ext=so
    gc_defines="-D GC_BUILTIN_ATOMIC=1 -D GC_THREADS=1"
    ;;
  linux_arm64)
    v_os=linux v_arch=arm64 cc=aarch64-linux-gnu-gcc objcc=aarch64-linux-gnu-gcc ar=aarch64-linux-gnu-ar ext=so
    gc_defines="-D GC_BUILTIN_ATOMIC=1 -D GC_THREADS=1"
    ;;
  windows_amd64)
    v_os=windows v_arch="" cc=x86_64-w64-mingw32-gcc objcc=x86_64-w64-mingw32-gcc-win32 ar=x86_64-w64-mingw32-ar ext=dll
    gc_defines="-D GC_NOT_DLL=1 -D GC_WIN32_THREADS=1 -D GC_BUILTIN_ATOMIC=1 -D GC_THREADS=1"
    ;;
  *)
    echo "build-lib.sh: unknown target '$name' (expected linux_amd64, linux_arm64, or windows_amd64)" >&2
    exit 1
    ;;
esac
```

Leave every line from `os_flag=""` through the end of the file (the `mkdir -p`, both `v -prod ... -shared` invocations, the `cfile=$(ls -t ...)` block, the `objcc` compile, `ar rcs`, the `build-module` block, and the final `chown`) exactly as-is — they already reference `$v_os`/`$v_arch`/`$cc`/`$objcc`/`$ar`/`$ext`/`$vflags`/`$gc_defines`/`$out`/`$name` by name, which are now set by the `case` table instead of by positional args, so no further edits are needed there.

- [ ] **Step 3: Update the Makefile call sites**

Read `Makefile` first to get current line numbers (the earlier `lib`/`lib-all` block may have shifted from other uncommitted changes). Find these two recipes:
```make
lib: image        ## Build shared (.so) + static (.a) + module-cache object for linux/amd64 -> out/linux_amd64/
	$(LIB_RUN) $(IMAGE) ./scripts/build-lib.sh linux_amd64 "" "" gcc gcc ar so "$(VFLAGS)" -D GC_BUILTIN_ATOMIC=1 -D GC_THREADS=1

lib-all: image    ## Same, for every supported target: linux/amd64, linux/arm64, windows/amd64 -> out/<target>/
	$(LIB_RUN) $(IMAGE) sh -c '\
	  ./scripts/build-lib.sh linux_amd64   ""      ""    gcc                    gcc                          ar                     so  "$(VFLAGS)" -D GC_BUILTIN_ATOMIC=1 -D GC_THREADS=1 && \
	  ./scripts/build-lib.sh linux_arm64   linux   arm64 aarch64-linux-gnu-gcc  aarch64-linux-gnu-gcc        aarch64-linux-gnu-ar   so  "$(VFLAGS)" -D GC_BUILTIN_ATOMIC=1 -D GC_THREADS=1 && \
	  ./scripts/build-lib.sh windows_amd64 windows ""    x86_64-w64-mingw32-gcc x86_64-w64-mingw32-gcc-win32 x86_64-w64-mingw32-ar dll "$(VFLAGS)" -D GC_NOT_DLL=1 -D GC_WIN32_THREADS=1 -D GC_BUILTIN_ATOMIC=1 -D GC_THREADS=1'
```

Replace with:
```make
lib: image        ## Build shared (.so) + static (.a) + module-cache object for linux/amd64 -> out/linux_amd64/
	$(LIB_RUN) $(IMAGE) ./scripts/build-lib.sh linux_amd64 "$(VFLAGS)"

lib-all: image    ## Same, for every supported target: linux/amd64, linux/arm64, windows/amd64 -> out/<target>/
	$(LIB_RUN) $(IMAGE) sh -c 'for t in linux_amd64 linux_arm64 windows_amd64; do ./scripts/build-lib.sh $$t "$(VFLAGS)"; done'
```

Do not touch `LIB_RUN`'s definition or any other target in this task — that's Task 2.

- [ ] **Step 4: Verify the script's syntax**

Run: `sh -n scripts/build-lib.sh`
Expected: no output, exit code 0 (confirms no shell syntax errors before running it inside Docker).

- [ ] **Step 5: Build the dev image if not already built, then build one target**

Run: `make image` (skip if already built — check with `sudo docker images vlang-socks-dev`)
Run: `make lib`
Expected: exits 0; final lines show the `chown` running with no error.

- [ ] **Step 6: Verify Task 1's output artifacts**

Run: `ls -la out/linux_amd64/`
Expected: `libsocks.so`, `libsocks.a`, `socks.module.o` all present, owned by your host user (not root) — confirms the case-table refactor produced the same artifact set as before for this target.

- [ ] **Step 7: Build every target and verify**

Run: `rm -rf out && make lib-all`
Expected: exits 0, no error from any of the three `build-lib.sh` invocations in the loop.

Run: `ls out/linux_amd64/ out/linux_arm64/ out/windows_amd64/`
Expected: `out/linux_amd64/` and `out/linux_arm64/` each show `libsocks.so libsocks.a socks.module.o`; `out/windows_amd64/` shows `libsocks.dll libsocks.a` only (no `socks.module.o` — this is the existing, documented windows limitation in the script, unchanged by this task).

- [ ] **Step 8: Commit**

```bash
git add scripts/build-lib.sh Makefile
git commit -m "refactor(build): collapse build-lib.sh to a name-keyed <name> <vflags> interface"
```

---

### Task 2: Make Docker optional via a `DOCKER` variable

**Files:**
- Modify: `Makefile` (top variable block, and the `test`/`test-all`/`vet`/`fmt`/`lib`/`lib-all`/`shell` recipes)

**Interfaces:**
- Consumes: the `lib`/`lib-all` recipes as left by Task 1 (`$(LIB_RUN) $(IMAGE) ./scripts/build-lib.sh <name> "$(VFLAGS)"` and the `for`-loop variant).
- Produces: `DOCKER` (make variable, default `1`), `RUN` (docker-run flags, empty when `DOCKER=0`), `RUN_IMG` (expands to `$(IMAGE)` when `DOCKER=1`, empty otherwise), `IMAGE_DEP` (expands to `image` when `DOCKER=1`, empty otherwise), `LIB_RUN` (as before, plus the `HOST_UID`/`HOST_GID` env, empty when `DOCKER=0`), `DOCKER_BASE` (the raw `sudo docker run ...` prefix, always available, used only by `shell`). Task 3's `help` target does not depend on any of these.

- [ ] **Step 1: Read the current Makefile top-of-file and target list**

Run: `cat -n Makefile`

Confirm the current variable block is:
```make
IMAGE      := vlang-socks-dev
RUNTIME    := vlang-socks
MODULE     ?= socks
CACHE_VOL  := vlang-socks-cache
DOCKER_RUN := sudo docker run --rm -v $(CURDIR):/src -v $(CACHE_VOL):/root/.cache -w /src
```
and that `LIB_RUN` (added by earlier uncommitted work) reads:
```make
LIB_RUN := $(DOCKER_RUN) -e HOST_UID=$(shell id -u) -e HOST_GID=$(shell id -g)
```
If line numbers or content differ from this, re-read the actual file and adjust the following steps' anchors accordingly before editing.

- [ ] **Step 2: Replace the variable block**

Replace:
```make
IMAGE      := vlang-socks-dev
RUNTIME    := vlang-socks
MODULE     ?= socks
CACHE_VOL  := vlang-socks-cache
DOCKER_RUN := sudo docker run --rm -v $(CURDIR):/src -v $(CACHE_VOL):/root/.cache -w /src
```

With:
```make
IMAGE      := vlang-socks-dev
RUNTIME    := vlang-socks
MODULE     ?= socks
CACHE_VOL  := vlang-socks-cache

# Always-Docker recipe prefix, used only by targets that are inherently
# Docker operations (shell) regardless of the DOCKER toggle below.
DOCKER_BASE := sudo docker run --rm -v $(CURDIR):/src -v $(CACHE_VOL):/root/.cache -w /src

# Set DOCKER=0 to run test/vet/fmt/lib targets directly against a
# host-installed `v` toolchain instead of the containerized one. The host
# must have `v` installed (and, for lib-all, the aarch64/mingw cross
# toolchains) when using DOCKER=0. Default (DOCKER=1) is unchanged: every
# target below runs inside the pinned dev image via Docker.
DOCKER ?= 1
ifeq ($(DOCKER),1)
  RUN       := $(DOCKER_BASE)
  RUN_IMG   := $(IMAGE)
  IMAGE_DEP := image
else
  RUN       :=
  RUN_IMG   :=
  IMAGE_DEP :=
endif
```

- [ ] **Step 3: Update `LIB_RUN`'s definition**

Replace:
```make
LIB_RUN := $(DOCKER_RUN) -e HOST_UID=$(shell id -u) -e HOST_GID=$(shell id -g)
```

With:
```make
ifeq ($(DOCKER),1)
  LIB_RUN := $(RUN) -e HOST_UID=$(shell id -u) -e HOST_GID=$(shell id -g)
else
  LIB_RUN :=
endif
```

- [ ] **Step 4: Update `test`, `test-all`, `vet`, `fmt` to use `$(RUN)`/`$(RUN_IMG)`/`$(IMAGE_DEP)`**

Replace:
```make
test: image       ## Test one module:  make test MODULE=socks/socks5
	$(DOCKER_RUN) $(IMAGE) v $(VFLAGS) test $(MODULE)

test-all: image   ## Test every module
	$(DOCKER_RUN) $(IMAGE) sh -c 'v $(VFLAGS) test socks/core && v $(VFLAGS) test socks/socks5 && v $(VFLAGS) test socks/socks4 && v $(VFLAGS) test socks/resolver && v $(VFLAGS) test socks && v $(VFLAGS) test cmd/vlang-socks'

vet: image        ## What CI checks: fmt-verify + vet
	$(DOCKER_RUN) $(IMAGE) sh -c 'v fmt -verify socks cmd && v vet socks'

fmt: image        ## Auto-format in place
	$(DOCKER_RUN) $(IMAGE) v fmt -w socks cmd
```

With:
```make
test: $(IMAGE_DEP)       ## Test one module:  make test MODULE=socks/socks5  (DOCKER=0 for host v)
	$(RUN) $(RUN_IMG) v $(VFLAGS) test $(MODULE)

test-all: $(IMAGE_DEP)   ## Test every module  (DOCKER=0 for host v)
	$(RUN) $(RUN_IMG) sh -c 'v $(VFLAGS) test socks/core && v $(VFLAGS) test socks/socks5 && v $(VFLAGS) test socks/socks4 && v $(VFLAGS) test socks/resolver && v $(VFLAGS) test socks && v $(VFLAGS) test cmd/vlang-socks'

vet: $(IMAGE_DEP)        ## What CI checks: fmt-verify + vet  (DOCKER=0 for host v)
	$(RUN) $(RUN_IMG) sh -c 'v fmt -verify socks cmd && v vet socks'

fmt: $(IMAGE_DEP)        ## Auto-format in place  (DOCKER=0 for host v)
	$(RUN) $(RUN_IMG) v fmt -w socks cmd
```

- [ ] **Step 5: Update `lib`/`lib-all` to use `$(IMAGE_DEP)`/`$(RUN_IMG)`**

Replace (the Task 1 result):
```make
lib: image        ## Build shared (.so) + static (.a) + module-cache object for linux/amd64 -> out/linux_amd64/
	$(LIB_RUN) $(IMAGE) ./scripts/build-lib.sh linux_amd64 "$(VFLAGS)"

lib-all: image    ## Same, for every supported target: linux/amd64, linux/arm64, windows/amd64 -> out/<target>/
	$(LIB_RUN) $(IMAGE) sh -c 'for t in linux_amd64 linux_arm64 windows_amd64; do ./scripts/build-lib.sh $$t "$(VFLAGS)"; done'
```

With:
```make
lib: $(IMAGE_DEP)        ## Build shared (.so) + static (.a) + module-cache object for linux/amd64 -> out/linux_amd64/  (DOCKER=0 for host v)
	$(LIB_RUN) $(RUN_IMG) ./scripts/build-lib.sh linux_amd64 "$(VFLAGS)"

lib-all: $(IMAGE_DEP)    ## Same, for every supported target: linux/amd64, linux/arm64, windows/amd64 -> out/<target>/  (DOCKER=0 for host v)
	$(LIB_RUN) $(RUN_IMG) sh -c 'for t in linux_amd64 linux_arm64 windows_amd64; do ./scripts/build-lib.sh $$t "$(VFLAGS)"; done'
```

- [ ] **Step 6: Update `shell` to use the always-Docker `DOCKER_BASE`**

Replace:
```make
shell: image        ## Interactive toolchain shell for debugging
	$(DOCKER_RUN) -it $(IMAGE) bash
```

With:
```make
shell: image        ## Interactive toolchain shell for debugging
	$(DOCKER_BASE) -it $(IMAGE) bash
```

`image`, `build`, `run`, `clean` need no changes — they never referenced `DOCKER_RUN`/`LIB_RUN` and already hardcode `sudo docker build`/`sudo docker run`/`sudo docker rmi`/`sudo docker volume rm`.

- [ ] **Step 7: Verify default behavior is unchanged**

Run: `make test`
Expected: exits 0, same as before this task (containerized `v test socks`).

Run: `make lib`
Expected: exits 0; `out/linux_amd64/libsocks.so` etc. rebuilt (same as Task 1's Step 5/6 check).

- [ ] **Step 8: Verify the `DOCKER=0` path takes the no-Docker branch**

Since this dev environment may not have a host `v` install, verify the *variable wiring* rather than a full host build:

Run: `make -n test DOCKER=0`
Expected: prints `v -d net_nonblocking_sockets test socks` with no `sudo docker run` prefix (the `-n` flag shows the recipe Make *would* run, without running it — proves `RUN`/`RUN_IMG` collapsed to empty under `DOCKER=0`).

Run: `make -n test`
Expected: prints `sudo docker run --rm -v .../src -v vlang-socks-cache:/root/.cache -w /src vlang-socks-dev v -d net_nonblocking_sockets test socks` (default path unchanged).

Run: `make -n lib DOCKER=0`
Expected: prints `./scripts/build-lib.sh linux_amd64 -d net_nonblocking_sockets` with no docker/`-e HOST_UID` prefix.

- [ ] **Step 9: Commit**

```bash
git add Makefile
git commit -m "feat(build): add DOCKER=0 toggle to run test/vet/fmt/lib targets on host v"
```

---

### Task 3: Add a self-documenting `help` target

**Files:**
- Modify: `Makefile` (the `.PHONY` line and the top of the target list)

**Interfaces:**
- Consumes: the existing `## ` doc-comment convention already present on every target line (no changes needed to those comments beyond what Tasks 1-2 already added).
- Produces: `help` target, `.DEFAULT_GOAL := help`.

- [ ] **Step 1: Read the current `.PHONY` line and first target**

Run: `sed -n '1,15p' Makefile`

Confirm the `.PHONY` line currently reads (after Task 2's edits):
```make
.PHONY: image test test-all vet fmt build run shell clean lib lib-all all
```
and that `image:` is the first target defined (making it the current default goal).

- [ ] **Step 2: Add `help` to `.PHONY`, set the default goal, and define `help`**

Replace:
```make
.PHONY: image test test-all vet fmt build run shell clean lib lib-all all
```

With:
```make
.PHONY: help image test test-all vet fmt build run shell clean lib lib-all all

.DEFAULT_GOAL := help

help:               ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'
```

- [ ] **Step 3: Verify bare `make` and `make help` both print the target list**

Run: `make`
Expected: prints one line per documented target (`help`, `image`, `test`, `test-all`, `vet`, `fmt`, `lib`, `lib-all`, `all`, `build`, `run`, `shell`, `clean`), each with its `## ` comment text, and does NOT build the dev image (confirms `.DEFAULT_GOAL` took effect).

Run: `make help`
Expected: identical output to bare `make`.

- [ ] **Step 4: Verify existing targets still run correctly (no default-goal regressions)**

Run: `make test`
Expected: exits 0 (explicit target invocation is unaffected by changing the default goal).

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "feat(build): add self-documenting help target as the default goal"
```
