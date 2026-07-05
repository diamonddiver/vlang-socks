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

os_flag=""
[ -n "$v_os" ] && os_flag="-os $v_os"
arch_flag=""
[ -n "$v_arch" ] && arch_flag="-arch $v_arch"

out="/src/out/$name"
mkdir -p "$out"

# Shared library: `v -shared` drives its own correct link invocation for
# every target we support, so no manual gcc reconstruction is needed here.
v -prod $vflags $os_flag $arch_flag -cc "$cc" -shared -o "$out/libsocks.$ext" socks

# Static library: V refuses to emit an unlinked .o/.a for a non-main module
# (v -o out.a errors with "project must include a main module or be a
# shared library"), so re-run with -keepc to keep the C V already generated
# for the shared build, compile that to an object ourselves, and archive it.
# The objcc/defines/include-dir below were captured with
# `strace -f -e trace=execve` against V's own `v -shared` link command for
# each target; if V's libgc integration changes, re-trace and update here.
v -prod $vflags $os_flag $arch_flag -cc "$cc" -shared -keepc -o "$out/libsocks.$ext" socks >/dev/null
# Pick the newest match: some targets (observed for windows) leave a stray
# .tmp.so.c behind from the *first* (non-keepc) `v -shared` call above too,
# so more than one file can match here — the just-generated one is always
# the most recently modified.
cfile=$(ls -t /tmp/v_0/*.tmp.so.c | head -1)
stdatomic_dir=nix
[ "$v_os" = "windows" ] && stdatomic_dir=win
extra_flags=""
[ "$v_os" = "windows" ] && extra_flags="-municode"
"$objcc" -std=gnu11 -O3 -flto -w $extra_flags \
  -I /opt/v/thirdparty/libgc/include -I "/opt/v/thirdparty/stdatomic/$stdatomic_dir" \
  $gc_defines -c "$cfile" -o "$out/libsocks.o"
"$ar" rcs "$out/libsocks.a" "$out/libsocks.o"
rm -f "$out/libsocks.o"

# V's own compiled-module cache object, copied out to disk so it's usable
# outside the ~/.vmodules cache (e.g. as a prebuilt object for another V
# build of this module targeting the same platform).
#
# Skipped for windows: `v build-module -os windows` always tries to link a
# GUI-subsystem test executable (it cross-compiles fine, but then fails at
# link with "undefined reference to `wWinMain'") regardless of -cc — a
# V/mingw cross-compile limitation in this module-only (no main()) case,
# not something this script's flags control. The .dll and .a above are
# unaffected and are windows' distributable artifacts.
if [ "$v_os" != "windows" ]; then
  v $vflags $os_flag $arch_flag build-module socks >/dev/null
  cp "$(ls -t /root/.vmodules/cache/*/*.module.socks.o | head -1)" "$out/socks.module.o"
fi

# The container runs as root, so files it creates on the bind-mounted /src
# would otherwise land on the host owned by root. Hand them back to
# whichever host uid:gid invoked us (see the Makefile's HOST_UID/HOST_GID).
[ -n "${HOST_UID:-}" ] && chown -R "${HOST_UID}:${HOST_GID}" /src/out
