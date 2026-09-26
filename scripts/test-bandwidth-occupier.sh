#!/bin/sh
# Exercise bandwidth source selection and duration handling without external traffic.

set -eu

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/oalive-bandwidth-test.XXXXXX")

test_cleanup() {
  rm -rf "$test_root"
}

fail() {
  printf '%s\n' "bandwidth occupier regression test failed: $*" >&2
  exit 1
}

trap test_cleanup EXIT HUP INT TERM

mkdir -p "$test_root/run"
printf '%s\n' "test payload" >"$test_root/good"

OALIVE_LIBRARY_MODE=1
OALIVE_CONFIG=$test_root/no-config
export OALIVE_LIBRARY_MODE OALIVE_CONFIG
. "$repo_root/bandwidth_occupier.sh"
unset OALIVE_LIBRARY_MODE

RUN_DIR=$test_root/run
BANDWIDTH_PROBE_TIMEOUT=2
BANDWIDTH_PROBE_RATE=1024
BANDWIDTH_URL_CHECKS=0
BANDWIDTH_URLS="file://$test_root/missing,file://$test_root/good"
BANDWIDTH_URL=
BANDWIDTH_URL_FILE=
normalize_settings

selected=$(select_url) || fail "a reachable GET source was not selected"
[ "$selected" = "file://$test_root/good" ] || fail "unexpected selected source: $selected"

printf '%s\n' "# comment" "file://$test_root/missing" "file://$test_root/good" >"$test_root/urls"
BANDWIDTH_URLS=
BANDWIDTH_URL_FILE=$test_root/urls
selected=$(select_url) || fail "URL file source was not selected"
[ "$selected" = "file://$test_root/good" ] || fail "URL file selected: $selected"

BANDWIDTH_URL="file://$test_root/missing"
BANDWIDTH_URL_FILE=
if select_url >/dev/null 2>&1; then
  fail "an unreachable explicit URL was accepted"
fi

RUN_DIR=$test_root/run
run_with_timeout 1 sleep 3
[ "$RUN_TIMED_OUT" -eq 1 ] || fail "timeout was reported as an early failure"

start=$(date '+%s')
download_with_limit "file://$test_root/good" 1024 2 || fail "short-file download loop failed"
end=$(date '+%s')
[ $((end - start)) -ge 2 ] || fail "short file ended the run too early"

legacy_download_host=$(printf '%s%s%s' 'speed.' 'cloud' 'flare.com')
if grep -Fq "$legacy_download_host" "$repo_root/bandwidth_occupier.sh"; then
  fail "legacy special download endpoint is still present"
fi

printf '%s\n' "Bandwidth occupier regression passed"
