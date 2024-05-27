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

# Address sanitizer enables LSan which sets an atexit handler that
# calls the 'internal_clone' function that's not supported in QEMU, so
# disable LSan.
if [ "x$ASAN_OPTIONS" = x ]; then
    ASAN_OPTIONS=detect_leaks=0
    export ASAN_OPTIONS
else
    ASAN_OPTIONS=${ASAN_OPTIONS}:detect_leaks=0
fi

setarch "$setarch_arch" -R "qemu-$qemu_arch" -cpu "$qemu_cpu" -R 0 -L "$sysroot" "$*"

