# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: dev — the full V toolchain. Runs the tests and (stage 2) compiles
# the binary. Nothing from this stage ships in the runtime image.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS dev

# Build/run deps: gcc (V's cgen backend shells out to a C compiler), git (to
# fetch V + its C bootstrap), libc headers, CA certs. picoev and net are part
# of vlib — no extra packages needed (epoll on Linux).
#
# gcc-aarch64-linux-gnu / gcc-mingw-w64-x86-64: cross C toolchains so
# `make lib-all` can produce linux/arm64 and windows/amd64 library artifacts
# from this same linux/amd64 image (see scripts/build-lib.sh). V's `-os`/
# `-arch`/`-cc` flags drive the cross-compile; picoev and vlib/net compile
# cleanly under both — confirmed empirically, no macOS cross toolchain is
# available here (would need osxcross + the Apple SDK), so macOS is not a
# `make lib-all` target.
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc make git ca-certificates libc6-dev \
        gcc-aarch64-linux-gnu libc6-dev-arm64-cross gcc-mingw-w64-x86-64 \
    && rm -rf /var/lib/apt/lists/*

# Pin V to a known-good release so builds are reproducible and the spikes'
# outcomes are stable. Bump deliberately — never float to a moving tag.
ARG V_VERSION=0.4.8
# `make -C /opt/v` bootstraps V by compiling `vc` (github.com/vlang/vc — V's
# compiler pre-transpiled to C) into a `v1` binary, then uses that to build
# the real, pinned V source. The catch: vc has no version tags and its
# default branch always tracks vlang/v's HEAD, so an unpinned `fresh_vc`
# clone silently bootstraps from *whatever V looks like today*, not from
# V_VERSION. When today's vc is new enough to have dropped a legacy
# construct still used by an older pinned vlib (observed: the old `-native`
# backend and its `$if native` conditional), that mismatch breaks the build
# — nondeterministically, depending on when you happen to `docker build`.
# Fix: pin vc too, to the exact bot commit vc records as generated from this
# V_VERSION's release commit (each vc commit message is `[v:master] <sha> -
# V <version>`), and pass `local=1` so V's Makefile uses that pinned
# checkout as-is instead of `git pull`-ing it to HEAD. This makes the whole
# bootstrap chain self-consistent and reproducible, matching this file's own
# "never float" rule for V_VERSION.
ARG VC_COMMIT=54beb1f416b404a06b894e6883a0e2368d80bc3e
# `local=1` (below) also skips the *first-time* fetch of vlang/tccbin (V's
# bundled fast dev-mode C compiler), which otherwise happens unconditionally
# — so pre-seed it here ourselves, identically to what V's own `fresh_tcc`
# Makefile target would do, to keep that working.
RUN git clone --depth 1 --branch ${V_VERSION} https://github.com/vlang/v /opt/v \
    && git init -q /opt/v/vc \
    && git -C /opt/v/vc remote add origin https://github.com/vlang/vc \
    && git -C /opt/v/vc fetch -q --depth 1 origin ${VC_COMMIT} \
    && git -C /opt/v/vc checkout -q FETCH_HEAD \
    && git clone --filter=blob:none --quiet --branch thirdparty-linux-amd64 https://github.com/vlang/tccbin /opt/v/thirdparty/tcc \
    && make -C /opt/v local=1 \
    && /opt/v/v symlink \
    && v version

WORKDIR /src

# /opt/vmods/socks -> /src lets `import socks` resolve for any file that
# needs to reach this project as an installed module (cmd/vlang-socks/main.v),
# without a symlink *inside* the repo. An in-tree `ln -s . socks` (self-
# referential: the checkout contains a "socks" entry pointing back at itself)
# was tried first and rejected: V 0.4.8's import qualifier resolves `import
# socks.core` by walking back up the *importing file's own path* looking for
# a nested "socks" dir, and a self-referential symlink always offers one more
# match at any depth. Every hop through the in-tree symlink (root -> socks.X
# -> that package's own `import socks.core`) re-triggers the walk and adds
# another "socks." prefix, so the same core.SocksErrorCode type gets parsed
# and registered twice under "socks.core" and "socks.socks.core" (thrice for
# a file reached two hops deep) - a real V compiler bug, confirmed by
# instrumenting vlib/v/builder/builder.v's find_module_path in this image and
# observing the doubled/tripled module names. Breaks not just `v test .` but
# the real `cmd/vlang-socks` build.
# This symlink instead lives *outside* /src, so there is no self-reference:
# `ls /src` never contains a "socks" entry, so the walk never finds a second
# match. Created here (build time) as a symlink to the literal path "/src",
# so it resolves correctly once the Makefile bind-mounts real source there at
# `docker run` time (this stage never COPYs source itself).
RUN mkdir -p /opt/vmods && ln -s /src /opt/vmods/socks

# V caches compiled objects under ~/.cache; the Makefile mounts a volume there
# so repeat `docker run`s are fast. Source is bind-mounted at run time.
#
# -path "@vlib:/opt/vmods": adds /opt/vmods (see above) to V's module search
# path, alongside (not replacing, via the "@vlib:" prefix) the default vlib
# location, so `import socks` resolves via /opt/vmods/socks without needing
# an in-tree symlink.
#
# -d net_nonblocking_sockets: without this compile-time flag, vlib/net creates
# BLOCKING OS sockets (see vlib/net/udp.c.v: new_udp_socket only calls
# set_blocking(sockfd, false) under this exact `$if` guard). On a blocking
# socket, UdpConn.read()'s underlying recvfrom() never returns EWOULDBLOCK, so
# the wait_for_read()-based deadline logic that set_read_timeout()/
# set_read_deadline() rely on is never reached — those calls silently become
# no-ops and a read with no incoming data blocks forever. Confirmed empirically
# (Task 22): a UDP read with a 500ms timeout set hung indefinitely without this
# flag, and returned a timeout error at ~500ms with it. The plan's Task 22
# brief requires "every socket op is bounded by a short deadline"; this flag is
# required for that to actually be true for UDP (TCP sockets are unaffected
# either way, since their EWOULDBLOCK/EAGAIN path is reached regardless).
CMD ["v", "-d", "net_nonblocking_sockets", "-path", "@vlib:/opt/vmods", "test", "."]

# ---------------------------------------------------------------------------
# Stage 2: build — compile the CLI with the pinned toolchain.
# (Only succeeds once Task 23 creates cmd/vlang-socks/main.v.)
# ---------------------------------------------------------------------------
FROM dev AS build
COPY . /src
# See the CMD comment above for why -d net_nonblocking_sockets and
# -path "@vlib:/opt/vmods" are required (the latter so main.v's `import
# socks` resolves via /opt/vmods/socks -> /src, populated by the COPY above).
RUN mkdir -p /out && v -prod -d net_nonblocking_sockets -path "@vlib:/opt/vmods" -o /out/vlang-socks cmd/vlang-socks

# ---------------------------------------------------------------------------
# Stage 3: runtime — tiny image with just the binary + libc. No toolchain, no
# source. This is what you deploy/run.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --no-create-home socks
COPY --from=build /out/vlang-socks /usr/local/bin/vlang-socks
USER socks
EXPOSE 1080
ENTRYPOINT ["vlang-socks"]
CMD ["serve", "--addr", ":1080"]
