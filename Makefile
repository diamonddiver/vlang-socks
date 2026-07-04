# Containerized V toolchain — the host needs only Docker, never V itself.
IMAGE      := vlang-socks-dev
RUNTIME    := vlang-socks
MODULE     ?= socks
CACHE_VOL  := vlang-socks-cache
DOCKER_RUN := sudo docker run --rm -v $(CURDIR):/src -v $(CACHE_VOL):/root/.cache -w /src

.PHONY: image test test-all vet fmt build run shell clean

image:            ## Build the pinned dev toolchain image (cached after first run)
	sudo docker build --target dev -t $(IMAGE) .

test: image       ## Test one module:  make test MODULE=socks/socks5
	$(DOCKER_RUN) $(IMAGE) v test $(MODULE)

test-all: image   ## Test every module
	$(DOCKER_RUN) $(IMAGE) sh -c 'v test socks/core && v test socks/socks5 && v test socks/socks4 && v test socks/resolver && v test socks && v test cmd/vlang-socks'

vet: image        ## What CI checks: fmt-verify + vet
	$(DOCKER_RUN) $(IMAGE) sh -c 'v fmt -verify socks cmd && v vet socks'

fmt: image        ## Auto-format in place
	$(DOCKER_RUN) $(IMAGE) v fmt -w socks cmd

build:            ## Build the slim runtime image (compiled CLI, no toolchain)
	sudo docker build --target runtime -t $(RUNTIME) .

run: build        ## Run the proxy:  make run ARGS="serve --addr :1080 --versions 5"
	sudo docker run --rm -it -p 1080:1080 $(RUNTIME) $(ARGS)

shell: image      ## Interactive toolchain shell for debugging
	$(DOCKER_RUN) -it $(IMAGE) bash

clean:            ## Remove images + cache volume
	-sudo docker rmi $(RUNTIME) $(IMAGE)
	-sudo docker volume rm $(CACHE_VOL)
