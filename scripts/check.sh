#!/bin/sh
# Local static checks for Oracle-server-keep-alive-script.

set -eu

scripts="oalive.sh cpu-limit.sh memory-limit.sh bandwidth_occupier.sh oalive-cron-runner.sh"
units="cpu-limit.service memory-limit.service bandwidth_occupier.service bandwidth_occupier.timer"

printf '%s\n' "== POSIX shell syntax =="
sh -n $scripts

if command -v dash >/dev/null 2>&1; then
  printf '%s\n' "== dash syntax =="
  dash -n $scripts
fi

if command -v bash >/dev/null 2>&1; then
  printf '%s\n' "== bash syntax =="
  bash -n $scripts
fi

if command -v shellcheck >/dev/null 2>&1; then
  printf '%s\n' "== shellcheck =="
  shellcheck -s sh -e SC1090,SC2329 $scripts
  shellcheck -s sh -e SC1091,SC2034,SC2329 scripts/test-installer-download.sh scripts/test-bandwidth-occupier.sh
fi

printf '%s\n' "== runtime check commands =="
sh cpu-limit.sh --check
sh memory-limit.sh --check
sh bandwidth_occupier.sh --check
sh oalive-cron-runner.sh --check
sh oalive.sh --status >/dev/null

printf '%s\n' "== remote installer download regression =="
sh scripts/test-installer-download.sh

printf '%s\n' "== bandwidth source and timeout regression =="
sh scripts/test-bandwidth-occupier.sh

printf '%s\n' "== source reference check =="
legacy_source_host=$(printf '%s%s' 'git' 'lab.com')
if grep -n "$legacy_source_host/spiritysdx/Oracle-server-keep-alive-script" \
  README.md README_EN.md README_CRON.md README_CRON_EN.md oalive.sh; then
  printf '%s\n' "Legacy source references must be migrated to GitHub Raw" >&2
  exit 1
fi

printf '%s\n' "== unsafe pattern scan =="
if grep -En '#!/bin/bash|#!/usr/bin/env bash|\\[\\[|\\]\\]|grep -P|shuf|nproc|fallocate|ExecStart=/bin/bash|/bin/bash|pgrep dd|ps -ef|kill \\$\\(' $scripts $units >/tmp/oalive-check-patterns.$$ 2>/dev/null; then
  cat /tmp/oalive-check-patterns.$$
  rm -f /tmp/oalive-check-patterns.$$
  exit 1
fi
rm -f /tmp/oalive-check-patterns.$$

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '%s\n' "== git whitespace check =="
  git diff --check
fi

printf '%s\n' "All checks passed / 所有检查通过"
