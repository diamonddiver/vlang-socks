# Containerized V toolchain — the host needs only Docker, never V itself.
IMAGE      := vlang-socks-dev
RUNTIME    := vlang-socks
MODULE     ?= .
CACHE_VOL  := vlang-socks-cache

# Always-Docker recipe prefix. Used directly by `shell` (which must always
# use Docker), and as the base of RUN below when DOCKER=1.
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

.PHONY: help image test test-all test-capi vet fmt build run shell clean lib lib-all all install

.DEFAULT_GOAL := help

help:               ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

# -d net_nonblocking_sockets: required so UDP (and TCP) read timeouts/deadlines
# actually take effect at runtime instead of silently no-op'ing — see the
# matching comment on the Dockerfile's dev-stage CMD for the full explanation
# (Task 22 found that UdpConn.set_read_timeout() blocks forever without this
# flag, since vlib/net only makes sockets non-blocking under this exact guard).
VFLAGS := -d net_nonblocking_sockets

# In-repo module resolution. The module is 'socks' but the checkout dir is
# 'vlang-socks', and V 0.4.8 resolves `import socks` only via a directory
# literally named `socks`. An in-tree `socks -> .` self-symlink triggers a V
# import-qualifier compounding bug (the same type registers twice, as
# socks.core AND socks.socks.core), so instead the module is exposed as `socks`
# via an EXTERNAL symlink placed OUTSIDE the source tree — no self-reference,
# and `v fmt/vet/test .` never recurses into it — added to V's module path with
# `-path @vlib:<dir>` (the @vlib: prefix keeps V's default path alongside it).
# Created fresh per run so it always points at the current checkout: under
# DOCKER=1 the dir is baked into the dev image (see Dockerfile); under DOCKER=0
# (host / CI) the recipe creates it beside the user's V cache.
ifeq ($(DOCKER),1)
  MODLINK_DIR   := /opt/vmods
  MODLINK_SETUP := true
else
  MODLINK_DIR   := $(HOME)/.cache/vlang-socks-modlink
  MODLINK_SETUP := mkdir -p $(MODLINK_DIR) && ln -sfn $(CURDIR) $(MODLINK_DIR)/socks
endif
MODPATH := -path @vlib:$(MODLINK_DIR)

# Library version, parsed from v.mod's `version: '...'` (single source of
# truth) — drives the SONAME/versioned-filename chain build-lib.sh produces
# and the pkg-config file `install` generates.
VERSION := $(shell sed -n "s/^[[:space:]]*version: *'\([^']*\)'.*/\1/p" v.mod)

image:            ## Build the pinned dev toolchain image (cached after first run)
	sudo docker build --target dev -t $(IMAGE) .

test: $(IMAGE_DEP)       ## Test one module:  make test MODULE=socks5  (DOCKER=0 for host v)
	$(RUN) $(RUN_IMG) sh -c '$(MODLINK_SETUP) && v $(VFLAGS) $(MODPATH) test $(MODULE)'

test-all: $(IMAGE_DEP)   ## Test every module  (DOCKER=0 for host v)
	$(RUN) $(RUN_IMG) sh -c '$(MODLINK_SETUP) && v $(VFLAGS) $(MODPATH) test core && v $(VFLAGS) $(MODPATH) test socks5 && v $(VFLAGS) $(MODPATH) test socks4 && v $(VFLAGS) $(MODPATH) test resolver && v $(VFLAGS) -enable-globals $(MODPATH) test . && v $(VFLAGS) $(MODPATH) test cmd/vlang-socks'

# `v test .`'s directory walk (used by test-all above) has no way to exclude
# a named subdirectory, so it always descends into capi/ too — hence -enable-
# globals on that one invocation, harmless for every other module (the flag
# only unlocks syntax, it doesn't change codegen for code that isn't using
# it). This target exists in addition so `capi` can be tested on its own.
test-capi: $(IMAGE_DEP)  ## Test the capi module (needs -enable-globals)  (DOCKER=0 for host v)
	$(RUN) $(RUN_IMG) sh -c '$(MODLINK_SETUP) && v $(VFLAGS) -enable-globals $(MODPATH) test capi'

vet: $(IMAGE_DEP)        ## What CI checks: fmt-verify + vet  (DOCKER=0 for host v)
	$(RUN) $(RUN_IMG) sh -c '$(MODLINK_SETUP) && v fmt -verify . cmd && v $(MODPATH) vet .'

fmt: $(IMAGE_DEP)        ## Auto-format in place  (DOCKER=0 for host v)
	$(RUN) $(RUN_IMG) v fmt -w . cmd

# The container runs as root; build-lib.sh chowns its output back to
# whichever host uid:gid ran `make`, so out/ doesn't end up root-owned.
ifeq ($(DOCKER),1)
  LIB_RUN := $(RUN) -e HOST_UID=$(shell id -u) -e HOST_GID=$(shell id -g)
else
  LIB_RUN :=
endif

# -enable-globals: the lib is built from the `capi` module (which pulls in
# `socks` transitively), not from `.` — capi's handle registry needs it, but
# plain V consumers doing `import socks` never link capi and never need it.
lib: $(IMAGE_DEP)        ## Build shared (.so) + static (.a) + module-cache object for linux/amd64 -> out/linux_amd64/
	$(LIB_RUN) $(RUN_IMG) sh -c '$(MODLINK_SETUP) && MODLINK_DIR=$(MODLINK_DIR) ./scripts/build-lib.sh linux_amd64 "$(VFLAGS) -enable-globals $(MODPATH)" $(VERSION)'

lib-all: $(IMAGE_DEP)    ## Same, for every supported target: linux/amd64, linux/arm64, windows/amd64 -> out/<target>/
	$(LIB_RUN) $(RUN_IMG) sh -c '$(MODLINK_SETUP) && for t in linux_amd64 linux_arm64 windows_amd64; do MODLINK_DIR=$(MODLINK_DIR) ./scripts/build-lib.sh $$t "$(VFLAGS) -enable-globals $(MODPATH)" $(VERSION); done'

all: lib-all      ## Alias for lib-all: every library artifact, every supported platform

PREFIX ?= /usr/local
DESTDIR ?=

install: lib      ## Install libsocks (.a/.so + header + pkg-config) from out/linux_amd64 into DESTDIR/PREFIX
	install -d "$(DESTDIR)$(PREFIX)/lib" "$(DESTDIR)$(PREFIX)/include" "$(DESTDIR)$(PREFIX)/lib/pkgconfig"
	install -m 644 out/linux_amd64/libsocks.a "$(DESTDIR)$(PREFIX)/lib/"
	cp -P out/linux_amd64/libsocks.so* "$(DESTDIR)$(PREFIX)/lib/"
	install -m 644 include/socks.h "$(DESTDIR)$(PREFIX)/include/"
	sed -e 's#@PREFIX@#$(PREFIX)#' -e 's#@LIBDIR@#$(PREFIX)/lib#' \
	    -e 's#@INCLUDEDIR@#$(PREFIX)/include#' -e 's#@VERSION@#$(VERSION)#' \
	    socks.pc.in > "$(DESTDIR)$(PREFIX)/lib/pkgconfig/socks.pc"

build:            ## Build the slim runtime image (compiled CLI, no toolchain)
	sudo docker build --target runtime -t $(RUNTIME) .

run: build        ## Run the proxy:  make run ARGS="serve --addr :1080 --versions 5"
	sudo docker run --rm -it -p 1080:1080 $(RUNTIME) $(ARGS)

shell: image      ## Interactive toolchain shell for debugging
	$(DOCKER_BASE) -it $(IMAGE) bash

clean:            ## Remove images + cache volume
	-sudo docker rmi $(RUNTIME) $(IMAGE)
	-sudo docker volume rm $(CACHE_VOL)
