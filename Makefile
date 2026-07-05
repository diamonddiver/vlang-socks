# Containerized V toolchain — the host needs only Docker, never V itself.
IMAGE      := vlang-socks-dev
RUNTIME    := vlang-socks
MODULE     ?= socks
CACHE_VOL  := vlang-socks-cache
DOCKER_RUN := sudo docker run --rm -v $(CURDIR):/src -v $(CACHE_VOL):/root/.cache -w /src

.PHONY: image test test-all vet fmt build run shell clean lib lib-all all

# -d net_nonblocking_sockets: required so UDP (and TCP) read timeouts/deadlines
# actually take effect at runtime instead of silently no-op'ing — see the
# matching comment on the Dockerfile's dev-stage CMD for the full explanation
# (Task 22 found that UdpConn.set_read_timeout() blocks forever without this
# flag, since vlib/net only makes sockets non-blocking under this exact guard).
VFLAGS := -d net_nonblocking_sockets

image:            ## Build the pinned dev toolchain image (cached after first run)
	sudo docker build --target dev -t $(IMAGE) .

test: image       ## Test one module:  make test MODULE=socks/socks5
	$(DOCKER_RUN) $(IMAGE) v $(VFLAGS) test $(MODULE)

test-all: image   ## Test every module
	$(DOCKER_RUN) $(IMAGE) sh -c 'v $(VFLAGS) test socks/core && v $(VFLAGS) test socks/socks5 && v $(VFLAGS) test socks/socks4 && v $(VFLAGS) test socks/resolver && v $(VFLAGS) test socks && v $(VFLAGS) test cmd/vlang-socks'

vet: image        ## What CI checks: fmt-verify + vet
	$(DOCKER_RUN) $(IMAGE) sh -c 'v fmt -verify socks cmd && v vet socks'

fmt: image        ## Auto-format in place
	$(DOCKER_RUN) $(IMAGE) v fmt -w socks cmd

# The container runs as root; build-lib.sh chowns its output back to
# whichever host uid:gid ran `make`, so out/ doesn't end up root-owned.
LIB_RUN := $(DOCKER_RUN) -e HOST_UID=$(shell id -u) -e HOST_GID=$(shell id -g)

lib: image        ## Build shared (.so) + static (.a) + module-cache object for linux/amd64 -> out/linux_amd64/
	$(LIB_RUN) $(IMAGE) ./scripts/build-lib.sh linux_amd64 "$(VFLAGS)"

lib-all: image    ## Same, for every supported target: linux/amd64, linux/arm64, windows/amd64 -> out/<target>/
	$(LIB_RUN) $(IMAGE) sh -c 'for t in linux_amd64 linux_arm64 windows_amd64; do ./scripts/build-lib.sh $$t "$(VFLAGS)"; done'

all: lib-all      ## Alias for lib-all: every library artifact, every supported platform

build:            ## Build the slim runtime image (compiled CLI, no toolchain)
	sudo docker build --target runtime -t $(RUNTIME) .

run: build        ## Run the proxy:  make run ARGS="serve --addr :1080 --versions 5"
	sudo docker run --rm -it -p 1080:1080 $(RUNTIME) $(ARGS)

shell: image      ## Interactive toolchain shell for debugging
	$(DOCKER_RUN) -it $(IMAGE) bash

clean:            ## Remove images + cache volume
	-sudo docker rmi $(RUNTIME) $(IMAGE)
	-sudo docker volume rm $(CACHE_VOL)
