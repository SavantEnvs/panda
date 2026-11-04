#!/usr/bin/env bash
#
# mayhem/build.sh — builds PANDA's QEMU-2.9.1 net/qobject/qemu-opts code for fuzzing, plus the unit tests.
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem; offline and re-runnable.
#   1) build/asan  : QEMU "tools" build with $SANITIZER_FLAGS + $DEBUG_FLAGS + SanCov (fuzzer-no-link);
#                    mayhem/fuzz.mk links the harnesses (libFuzzer and -standalone) against its objects
#   2) build/plain : the same tree with NORMAL flags: qemu-img, qemu-io and gtest unit tests for test.sh
# Build dirs live under the upstream-gitignored /build, so a `git clean -ffdX` tree rebuilds from scratch.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

TARGETS="fuzz_net_eth fuzz_qobject_json fuzz_qemu_opts"
UNIT_TESTS="check-qdict check-qlist check-qstring check-qjson check-qnull check-qfloat check-qint
            test-qemu-opts test-iov test-cutils test-bitops test-bitcnt test-hbitmap test-base64
            test-crypto-hash test-xbzrle test-mul64 test-shift128 test-int128
            test-string-input-visitor test-qobject-input-visitor test-qobject-output-visitor test-keyval"

# Common configure: only the tools (qobject, QemuOpts, net helpers) are needed; one softmmu target
# is required by PANDA's Makefile. No network or submodules: glib/pixman/fdt/libarchive/openssl come from apt.
configure_qemu() {
  local dir=$1; shift
  mkdir -p "$dir"
  (cd "$dir" && "$SRC/configure" --disable-werror --disable-docs --disable-guest-agent --disable-capstone \
      --target-list=i386-softmmu --cc="$CC" --host-cc="$CC" "$@" >configure.log 2>&1) \
    || { tail -30 "$dir/configure.log" >&2; exit 1; }
}

export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"   # configure's probe programs only

# lsan_off.c defines __lsan_is_turned_off(); fuzz.mk compiles it with the sanitizer flags and links it
# into every fuzz and -standalone binary (LeakSanitizer off, ASan/UBSan stay on).
export LSAN_OFF_SRC="$SRC/mayhem/lsan_off.c"

# 1) Fuzz build. QEMU's own code is compiled with the sanitizers; -fno-sanitize=function,alignment
#    relax two checks QEMU 2.9 violates by design (indirect calls through casted handler types, and
#    packed-struct loads), which would otherwise abort runs; kept from the earlier block-driver build.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=function,alignment -Wno-error"
configure_qemu "$SRC/build/asan" --extra-cflags="$FUZZ_CFLAGS" --extra-ldflags="$SANITIZER_FLAGS"
make -C "$SRC/build/asan" -j"$MAYHEM_JOBS" -f Makefile -f "$SRC/mayhem/fuzz.mk" \
     $(for t in $TARGETS; do echo "$t" "$t-standalone"; done) 2>&1 | grep -v -E "multiple common|real_vfork" || true
for t in $TARGETS; do
  [ -x "$SRC/build/asan/$t" ] && [ -x "$SRC/build/asan/$t-standalone" ] || { echo "build.sh: $t missing" >&2; exit 1; }
  cp "$SRC/build/asan/$t" "$SRC/$t"
  cp "$SRC/build/asan/$t-standalone" "$SRC/$t-standalone"
done

# 2) Test build: normal flags, left in build/plain for mayhem/test.sh.
configure_qemu "$SRC/build/plain" --extra-cflags="-Wno-error $COVERAGE_FLAGS" --extra-ldflags="$COVERAGE_FLAGS"
make -C "$SRC/build/plain" -j"$MAYHEM_JOBS" qemu-img qemu-io $(for t in $UNIT_TESTS; do echo "tests/$t"; done) \
     2>&1 | grep -v -E "multiple common" || true
for t in $UNIT_TESTS; do
  [ -x "$SRC/build/plain/tests/$t" ] || { echo "build.sh: tests/$t missing" >&2; exit 1; }
done
[ -x "$SRC/build/plain/qemu-img" ] && [ -x "$SRC/build/plain/qemu-io" ] || { echo "build.sh: qemu-img/qemu-io missing" >&2; exit 1; }
