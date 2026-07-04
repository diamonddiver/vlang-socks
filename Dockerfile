# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: dev — the full V toolchain. Runs the tests and (stage 2) compiles
# the binary. Nothing from this stage ships in the runtime image.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS dev

# Build/run deps: gcc (V's cgen backend shells out to a C compiler), git (to
# fetch V + its C bootstrap), libc headers, CA certs. picoev and net are part
# of vlib — no extra packages needed (epoll on Linux).
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc make git ca-certificates libc6-dev \
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
# V caches compiled objects under ~/.cache; the Makefile mounts a volume there
# so repeat `docker run`s are fast. Source is bind-mounted at run time.
CMD ["v", "test", "socks"]

# ---------------------------------------------------------------------------
# Stage 2: build — compile the CLI with the pinned toolchain.
# (Only succeeds once Task 23 creates cmd/vlang-socks/main.v.)
# ---------------------------------------------------------------------------
FROM dev AS build
COPY . /src
RUN mkdir -p /out && v -prod -o /out/vlang-socks cmd/vlang-socks

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
