#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS the QEMU unit tests and a qemu-img/qemu-io known-answer round trip built by
# mayhem/build.sh (build/plain, normal flags). Asserts values: every gtest result line is counted, and
# every image format must read back exactly the bytes written to it.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/build/plain"
UNIT_TESTS="check-qdict check-qlist check-qstring check-qjson check-qnull check-qfloat check-qint
            test-qemu-opts test-iov test-cutils test-bitops test-bitcnt test-hbitmap test-base64
            test-crypto-hash test-xbzrle test-mul64 test-shift128 test-int128
            test-string-input-visitor test-qobject-input-visitor test-qobject-output-visitor test-keyval"
for f in qemu-img qemu-io $(for t in $UNIT_TESTS; do echo "tests/$t"; done); do
  [ -x "$B/$f" ] || { echo "test.sh: $B/$f missing (mayhem/build.sh builds it)" >&2; emit_ctrf "qemu-unit+imgio" 0 1; exit 1; }
done

passed=0; failed=0
work="$(mktemp -d "${TMPDIR:-/tmp}/panda-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1) gtest unit tests (TAP output): count each "ok"/"not ok" line; a binary that exits non-zero or prints
#    no results counts as one failure, so a stubbed-out test binary cannot pass.
cd "$B"
for t in $UNIT_TESTS; do
  out="$(timeout 300 "tests/$t" -k 2>&1)"; rc=$?
  ok=$(printf '%s\n' "$out" | grep -c '^ok ')
  bad=$(printf '%s\n' "$out" | grep -c '^not ok ')
  if [ "$rc" -ne 0 ] || [ "$ok" -eq 0 ]; then bad=$(( bad + 1 )); fi
  passed=$(( passed + ok )); failed=$(( failed + bad ))
  echo "unit $t: ok=$ok failed=$bad rc=$rc"
  [ "$bad" -eq 0 ] || printf '%s\n' "$out" | tail -20
done
cd "$SRC"

# 2) Known-answer image round trip per format: write known byte patterns with qemu-io, convert to raw with
#    qemu-img and compare with a reference file built in shell, verify reads and `qemu-img check`.
pat() { head -c "$2" /dev/zero | tr '\0' "$1"; }
ref="$work/ref.raw"
{ pat '\132' 4096; pat '\000' 61440; pat '\303' 8192; pat '\000' 57344; pat '\021' 16384; } > "$ref"
pad=$(( 1048576 - $(stat -c %s "$ref") )); head -c "$pad" /dev/zero >> "$ref"
for fmt in qcow2 qcow qed vmdk vdi vhdx vpc parallels; do
  img="$work/t.$fmt"; raw="$work/t.$fmt.raw"; ok=1
  "$B/qemu-img" create -f "$fmt" "$img" 1M >/dev/null 2>&1 || ok=0
  vsize=1048576; [ "$fmt" = vpc ] && vsize=1079296   # vpc rounds the size to a CHS geometry
  "$B/qemu-img" info "$img" 2>/dev/null | grep -q "($vsize bytes)" || ok=0
  "$B/qemu-io" -f "$fmt" -c 'write -P 0x5a 0 4k' -c 'write -P 0xc3 64k 8k' -c 'write -P 0x11 128k 16k' "$img" 2>&1 \
     | grep -q 'wrote 4096/4096 bytes' || ok=0
  "$B/qemu-io" -f "$fmt" -c 'read -P 0x5a 0 4k' -c 'read -P 0xc3 64k 8k' -c 'read -P 0 4k 60k' "$img" 2>&1 \
     | grep -c 'read [0-9]*/[0-9]* bytes' | grep -qx 3 || ok=0
  "$B/qemu-io" -f "$fmt" -c 'read -P 0x77 0 4k' "$img" 2>&1 | grep -q 'Pattern verification failed' || ok=0
  "$B/qemu-img" convert -f "$fmt" -O raw "$img" "$raw" >/dev/null 2>&1 || ok=0
  cmp -s -n 1048576 "$ref" "$raw" || ok=0
  [ "$(stat -c %s "$raw")" = "$vsize" ] || ok=0
  "$B/qemu-img" check -f "$fmt" "$img" >/dev/null 2>&1; crc=$?
  [ "$crc" -eq 0 ] || [ "$crc" -eq 63 ] || ok=0   # 63 = format has no consistency check
  if [ "$ok" -eq 1 ]; then passed=$(( passed + 1 )); echo "roundtrip $fmt: ok"; else failed=$(( failed + 1 )); echo "roundtrip $fmt: FAILED"; fi
done

# 3) qcow2 compressed convert, snapshot and rebase keep the data (sha256 of the raw view).
want=$(sha256sum < "$ref" | cut -d' ' -f1)
ok=1
"$B/qemu-img" convert -c -f raw -O qcow2 "$ref" "$work/c.qcow2" >/dev/null 2>&1 || ok=0
"$B/qemu-img" snapshot -c s1 "$work/c.qcow2" >/dev/null 2>&1 || ok=0
"$B/qemu-img" convert -f qcow2 -O raw "$work/c.qcow2" "$work/c.raw" >/dev/null 2>&1 || ok=0
[ "$(sha256sum < "$work/c.raw" | cut -d' ' -f1)" = "$want" ] || ok=0
"$B/qemu-img" create -f qcow2 -b "$work/c.qcow2" "$work/o.qcow2" >/dev/null 2>&1 || ok=0
"$B/qemu-img" convert -f qcow2 -O raw "$work/o.qcow2" "$work/o.raw" >/dev/null 2>&1 || ok=0
cmp -s "$ref" "$work/o.raw" || ok=0
if [ "$ok" -eq 1 ]; then passed=$(( passed + 1 )); echo "qcow2 compress/snapshot/backing: ok"; else failed=$(( failed + 1 )); echo "qcow2 compress/snapshot/backing: FAILED"; fi

emit_ctrf "qemu-unit+imgio" "$passed" "$failed" 0
