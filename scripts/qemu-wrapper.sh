#!/bin/bash

if [ $# -lt 5 ]; then
    echo "Usage: $0 setarch_arch qemu_arch qemu_cpu sysroot program [args...]"
    exit 1
fi

setarch_arch="$1"
qemu_arch="$2"
qemu_cpu="$3"
sysroot="$4"
shift 4

# Address sanitizer also enables LSan which sets an atexit handler
# that calls the 'internal_clone' function that's not supported in
# QEMU (see StopTheWorld() in
# libsanitizer/sanitizer_common/sanitizer_stoptheworld_linux_libcdep.cpp.
# So we want to disable LSan.
#
# However, libsanitizer reads its environment by parsing
# /proc/self/environ, which means it reads QEMU's environment (using
# QEMU's -E flag or QEMU_SET_ENV does not work).
#
# This means we have to set ASAN_OPTIONS in QEMU's environment thus
# affecting both QEMU and the target/guest program (in case both are
# built with sanitizers, both will use the same runtime flags).
if [ "$ASAN_OPTIONS" = "" ]; then
    export ASAN_OPTIONS=detect_leaks=0
else
    ASAN_OPTIONS=${ASAN_OPTIONS}:detect_leaks=0
fi

exec setarch "$setarch_arch" -R "qemu-$qemu_arch" -cpu "$qemu_cpu" -R 0 -L "$sysroot" "$@"
