#!/bin/sh
# Cross-builds the `capi` module (which pulls in `socks` transitively) for
# one named target, inside the vlang-socks-dev toolchain image, as artifacts
# under out/<name>/:
#   libsocks.<ext>[.<version>]  - shared library (.so / .dll), ELF targets
#                                 also get the versioned file + the
#                                 .so -> .so.<major> -> .so.<version> symlink
#                                 chain (see the SONAME block below)
#   libsocks.a                  - static library archive, self-contained
#                                 (module object + libgc's gc.o, so linking
#                                 it needs only -lpthread, no -lgc)
#   socks.module.o              - V's own build-module compiled-object cache
#                                 entry for the plain `socks` module (not
#                                 produced for the windows target, see below)
#   socks.h                     - copy of the hand-written C header
#
# Usage: build-lib.sh <name> <vflags> <version>
#   name    one of: linux_amd64 | linux_arm64 | windows_amd64
#   vflags  extra `v` flags (e.g. -d net_nonblocking_sockets -enable-globals)
#   version the library version (e.g. 0.1.0), from v.mod
set -eu

name=$1 vflags=$2 version=$3
major=${version%%.*}

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

os_flag=""
[ -n "$v_os" ] && os_flag="-os $v_os"
arch_flag=""
[ -n "$v_arch" ] && arch_flag="-arch $v_arch"

out="/src/out/$name"
mkdir -p "$out"

# ELF targets only (not windows: PE exports are opt-in via @[export] already
# and need no extra linker help): pin the SONAME to libsocks.so.<major> and
# restrict the dynamic symbol table to just the enumerated socks_* API via
# the version-script, hiding all 1800+ mangled socks__* internals.
#
# Built via `set --` (a POSIX-sh-safe stand-in for an array), NOT a plain
# "$ldflags" string later word-split by an unquoted expansion: the
# -ldflags VALUE itself contains a space (between the two -Wl,... chunks)
# that must survive as a single argv element, while $vflags/$os_flag/
# $arch_flag below are the opposite — deliberately unquoted so each of
# their space-separated flags becomes its own argv element, same as before.
set -- -prod $vflags $os_flag $arch_flag -cc "$cc" -shared
if [ "$ext" = "so" ]; then
  set -- "$@" -ldflags "-Wl,-soname,libsocks.so.${major} -Wl,--version-script=$(pwd)/scripts/libsocks.map"
fi

# Shared library: `v -shared` drives its own correct link invocation for
# every target we support, so no manual gcc reconstruction is needed here.
v "$@" -o "$out/libsocks.$ext" capi

# Static library: V refuses to emit an unlinked .o/.a for a non-main module
# (v -o out.a errors with "project must include a main module or be a
# shared library"), so re-run with -keepc to keep the C V already generated
# for the shared build, compile that to an object ourselves, and archive it.
# The objcc/defines/include-dir below were captured with
# `strace -f -e trace=execve` against V's own `v -shared` link command for
# each target; if V's libgc integration changes, re-trace and update here.
v "$@" -keepc -o "$out/libsocks.$ext" capi >/dev/null
# Pick the newest match: some targets (observed for windows) leave a stray
# .tmp.so.c behind from the *first* (non-keepc) `v -shared` call above too,
# so more than one file can match here — the just-generated one is always
# the most recently modified.
cfile=$(ls -t /tmp/v_0/*.tmp.so.c | head -1)
stdatomic_dir=nix
[ "$v_os" = "windows" ] && stdatomic_dir=win
extra_flags=""
[ "$v_os" = "windows" ] && extra_flags="-municode"
cc_flags="-std=gnu11 -O3 -flto -w $extra_flags -I /opt/v/thirdparty/libgc/include -I /opt/v/thirdparty/stdatomic/$stdatomic_dir $gc_defines"
# shellcheck disable=SC2086
"$objcc" $cc_flags -c "$cfile" -o "$out/libsocks.o"
# The static archive must be self-contained: V's own static-lib recipe never
# compiles/archives its bundled GC, so without this a C program linking
# libsocks.a needs `-lgc` from somewhere else (usually absent) on top of it.
# Compiling libgc's own amalgamated gc.c with the identical flags and
# archiving it alongside the module object fixes that — linking libsocks.a
# then needs only -lpthread.
# shellcheck disable=SC2086
"$objcc" $cc_flags -c /opt/v/thirdparty/libgc/gc.c -o "$out/gc.o"
"$ar" rcs "$out/libsocks.a" "$out/libsocks.o" "$out/gc.o"
rm -f "$out/libsocks.o" "$out/gc.o"

# SONAME + versioned-filename chain (ELF targets only): `v -shared -o NAME`
# appends its own .so suffix and knows nothing about sonames, so build the
# chain ourselves, after the real build above already produced a correct,
# SONAME-tagged libsocks.so.
if [ "$ext" = "so" ]; then
  mv "$out/libsocks.$ext" "$out/libsocks.$ext.$version"
  ln -sf "libsocks.$ext.$version" "$out/libsocks.$ext.$major"
  ln -sf "libsocks.$ext.$major" "$out/libsocks.$ext"
fi

cp /src/include/socks.h "$out/socks.h"

# V's own compiled-module cache object, copied out to disk so it's usable
# outside the ~/.vmodules cache (e.g. as a prebuilt object for another V
# build of this module targeting the same platform). Built from the plain
# `socks` module (not `capi`): this is the artifact a normal V consumer's
# `import socks` uses, and it must stay free of -enable-globals.
#
# Skipped for windows: `v build-module -os windows` always tries to link a
# GUI-subsystem test executable (it cross-compiles fine, but then fails at
# link with "undefined reference to `wWinMain'") regardless of -cc — a
# V/mingw cross-compile limitation in this module-only (no main()) case,
# not something this script's flags control. The .dll and .a above are
# unaffected and are windows' distributable artifacts.
if [ "$v_os" != "windows" ]; then
  # `v build-module` (unlike `import`) treats its argument as a literal
  # filesystem path, not a name resolved via -path/module search — and the
  # cache filename it produces is derived from that literal argument, not
  # from v.mod's `name`. Passing "." here would produce
  # `*.module..o` (empty name component); passing the absolute
  # /opt/vmods/socks path produces `*.module.opt.vmods.socks.o`. Only running
  # with "socks" as a *relative* argument, from the one directory where that
  # name actually resolves (/opt/vmods, see the Dockerfile), reproduces the
  # expected `*.module.socks.o` cache filename this script's glob below relies
  # on. cd in a subshell so $out (already absolute) is unaffected. MODLINK_DIR
  # is where the Makefile placed the external `socks` symlink (/opt/vmods under
  # DOCKER=1, the host cache dir under DOCKER=0).
  (cd "${MODLINK_DIR:-/opt/vmods}" && v $vflags $os_flag $arch_flag build-module socks) >/dev/null
  cp "$(ls -t /root/.vmodules/cache/*/*.module.socks.o | head -1)" "$out/socks.module.o"
fi

# The container runs as root, so files it creates on the bind-mounted /src
# would otherwise land on the host owned by root. Hand them back to
# whichever host uid:gid invoked us (see the Makefile's HOST_UID/HOST_GID).
[ -n "${HOST_UID:-}" ] && chown -R "${HOST_UID}:${HOST_GID}" /src/out
