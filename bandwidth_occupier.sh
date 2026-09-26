#!/bin/sh
# by spiritlhl
# from https://github.com/spiritLHLS/Oracle-server-keep-alive-script

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

init_locale() {
  utf8_locale=$(locale -a 2>/dev/null | awk 'tolower($0) ~ /utf-?8/ {print; exit}')
  if [ -n "$utf8_locale" ]; then
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
  fi
}

init_locale

OALIVE_CONFIG=${OALIVE_CONFIG:-/etc/oalive/oalive.conf}
[ -r "$OALIVE_CONFIG" ] && . "$OALIVE_CONFIG"

LOG_DIR=${OALIVE_LOG_DIR:-/var/log/oalive}
RUN_DIR=${OALIVE_RUN_DIR:-${TMPDIR:-/tmp}}
LOG_FILE=${BANDWIDTH_LOG_FILE:-$LOG_DIR/bandwidth_occupier.log}
LOCK_DIR=$RUN_DIR/oalive-bandwidth.lock
LOG_MAX_BYTES=${OALIVE_LOG_MAX_BYTES:-131072}

BANDWIDTH_MODE=${BANDWIDTH_MODE:-wget}
BANDWIDTH_INTERVAL_MINUTES=${BANDWIDTH_INTERVAL_MINUTES:-45}
BANDWIDTH_DURATION_MINUTES=${BANDWIDTH_DURATION_MINUTES:-6}
BANDWIDTH_RATE_PERCENT=${BANDWIDTH_RATE_PERCENT:-30}
BANDWIDTH_RATE_MBPS=${BANDWIDTH_RATE_MBPS:-auto}
BANDWIDTH_DEFAULT_MBPS=${BANDWIDTH_DEFAULT_MBPS:-10}
BANDWIDTH_SPEEDTEST_COUNT=${BANDWIDTH_SPEEDTEST_COUNT:-10}
BANDWIDTH_URL=${BANDWIDTH_URL:-}
BANDWIDTH_URLS=${BANDWIDTH_URLS:-}
BANDWIDTH_URL_FILE=${BANDWIDTH_URL_FILE:-}
BANDWIDTH_URL_CHECKS=${BANDWIDTH_URL_CHECKS:-0}
BANDWIDTH_PROBE_TIMEOUT=${BANDWIDTH_PROBE_TIMEOUT:-5}
BANDWIDTH_PROBE_RATE=${BANDWIDTH_PROBE_RATE:-16384}
SPEEDTEST_GO_BIN=${SPEEDTEST_GO_BIN:-/etc/speedtest-cli/speedtest-go}
RUN_PID=
TIMER_PID=
TIMEOUT_FILE=
RUN_TIMED_OUT=0
BANDWIDTH_SKIP_URLS=

is_uint() {
  case ${1:-} in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

canonical_uint() {
  value=$1
  value=$(printf '%s\n' "$value" | sed 's/^0*//')
  [ -n "$value" ] || value=0
  printf '%s\n' "$value"
}

is_number() {
  awk -v n="${1:-}" 'BEGIN {exit (n ~ /^[0-9]+([.][0-9]+)?$/ ? 0 : 1)}'
}

now() {
  date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

epoch_seconds() {
  value=$(date '+%s' 2>/dev/null || true)
  is_uint "$value" || return 1
  printf '%s\n' "$value"
}

ensure_log_dir() {
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE=/dev/null
}

rotate_log() {
  [ "$LOG_FILE" = /dev/null ] && return 0
  [ -f "$LOG_FILE" ] || return 0
  size=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
  is_uint "$size" || size=0
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || : >"$LOG_FILE"
  fi
}

log() {
  ensure_log_dir
  rotate_log
  line="$(now) $*"
  printf '%s\n' "$line"
  [ "$LOG_FILE" = /dev/null ] || printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

pid_is_alive() {
  pid=${1:-}
  is_uint "$pid" || return 1
  kill -0 "$pid" 2>/dev/null
}

acquire_lock() {
  [ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi

  old_pid=
  [ -r "$LOCK_DIR/pid" ] && old_pid=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null)
  if pid_is_alive "$old_pid"; then
    log "带宽占用已在运行，PID: $old_pid / Bandwidth occupier is already running, PID: $old_pid"
    exit 0
  fi

  rm -rf "$LOCK_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi

  log "无法创建带宽锁目录 / Failed to create bandwidth lock directory: $LOCK_DIR"
  exit 1
}

cleanup() {
  trap - INT TERM EXIT
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" 2>/dev/null || true
  [ -n "${TIMER_PID:-}" ] && kill "$TIMER_PID" 2>/dev/null || true
  [ -n "${TIMEOUT_FILE:-}" ] && rm -f "$TIMEOUT_FILE" 2>/dev/null || true
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

terminate() {
  cleanup
  exit 0
}

normalize_settings() {
  is_uint "$BANDWIDTH_DURATION_MINUTES" || BANDWIDTH_DURATION_MINUTES=6
  is_uint "$BANDWIDTH_INTERVAL_MINUTES" || BANDWIDTH_INTERVAL_MINUTES=45
  is_uint "$BANDWIDTH_RATE_PERCENT" || BANDWIDTH_RATE_PERCENT=30
  is_uint "$BANDWIDTH_SPEEDTEST_COUNT" || BANDWIDTH_SPEEDTEST_COUNT=10
  is_uint "$BANDWIDTH_URL_CHECKS" || BANDWIDTH_URL_CHECKS=0
  is_uint "$BANDWIDTH_PROBE_TIMEOUT" || BANDWIDTH_PROBE_TIMEOUT=5
  is_uint "$BANDWIDTH_PROBE_RATE" || BANDWIDTH_PROBE_RATE=16384
  is_number "$BANDWIDTH_DEFAULT_MBPS" || BANDWIDTH_DEFAULT_MBPS=10
  [ "$BANDWIDTH_DURATION_MINUTES" -ge 1 ] || BANDWIDTH_DURATION_MINUTES=6
  [ "$BANDWIDTH_DURATION_MINUTES" -le 1440 ] || BANDWIDTH_DURATION_MINUTES=1440
  [ "$BANDWIDTH_INTERVAL_MINUTES" -ge 1 ] || BANDWIDTH_INTERVAL_MINUTES=45
  [ "$BANDWIDTH_RATE_PERCENT" -ge 1 ] || BANDWIDTH_RATE_PERCENT=30
  [ "$BANDWIDTH_RATE_PERCENT" -le 100 ] || BANDWIDTH_RATE_PERCENT=100
  [ "$BANDWIDTH_SPEEDTEST_COUNT" -ge 1 ] || BANDWIDTH_SPEEDTEST_COUNT=10
  [ "$BANDWIDTH_SPEEDTEST_COUNT" -le 100 ] || BANDWIDTH_SPEEDTEST_COUNT=100
  [ "$BANDWIDTH_URL_CHECKS" -le 100 ] || BANDWIDTH_URL_CHECKS=0
  [ "$BANDWIDTH_PROBE_TIMEOUT" -ge 1 ] || BANDWIDTH_PROBE_TIMEOUT=5
  [ "$BANDWIDTH_PROBE_TIMEOUT" -le 60 ] || BANDWIDTH_PROBE_TIMEOUT=60
  [ "$BANDWIDTH_PROBE_RATE" -ge 1024 ] || BANDWIDTH_PROBE_RATE=16384
  [ "$BANDWIDTH_PROBE_RATE" -le 1048576 ] || BANDWIDTH_PROBE_RATE=1048576
  BANDWIDTH_DURATION_MINUTES=$(canonical_uint "$BANDWIDTH_DURATION_MINUTES")
  BANDWIDTH_INTERVAL_MINUTES=$(canonical_uint "$BANDWIDTH_INTERVAL_MINUTES")
  BANDWIDTH_RATE_PERCENT=$(canonical_uint "$BANDWIDTH_RATE_PERCENT")
  BANDWIDTH_SPEEDTEST_COUNT=$(canonical_uint "$BANDWIDTH_SPEEDTEST_COUNT")
  BANDWIDTH_URL_CHECKS=$(canonical_uint "$BANDWIDTH_URL_CHECKS")
  BANDWIDTH_PROBE_TIMEOUT=$(canonical_uint "$BANDWIDTH_PROBE_TIMEOUT")
  BANDWIDTH_PROBE_RATE=$(canonical_uint "$BANDWIDTH_PROBE_RATE")
  case "$BANDWIDTH_MODE" in
    speedtest|speedtest-go|speedtest_go) BANDWIDTH_MODE=speedtest ;;
    *) BANDWIDTH_MODE=wget ;;
  esac
}

download_urls() {
  if [ -n "$BANDWIDTH_URL" ]; then
    printf '%s\n' "$BANDWIDTH_URL"
    return 0
  fi

  if [ -n "$BANDWIDTH_URL_FILE" ] && [ -r "$BANDWIDTH_URL_FILE" ]; then
    awk 'NF && $1 !~ /^#/ {print $1}' "$BANDWIDTH_URL_FILE"
    return 0
  fi

  if [ -n "$BANDWIDTH_URLS" ]; then
    printf '%s\n' "$BANDWIDTH_URLS" | awk '
      {
        count = split($0, parts, /[[:space:],]+/)
        for (i = 1; i <= count; i++) {
          if (parts[i] != "" && parts[i] !~ /^#/) print parts[i]
        }
      }
    '
    return 0
  fi

  # Ordinary static test files are less fragile than special download APIs.
  cat <<'URLS'
https://speedtest.tele2.net/1GB.zip
https://ash-speed.hetzner.com/100MB.bin
https://cachefly.cachefly.net/100mb.test
https://speedtest.london.linode.com/100MB-london.bin
https://speedtest.atlanta.linode.com/100MB-atlanta.bin
https://speedtest.frankfurt.linode.com/100MB-frankfurt.bin
https://speedtest.selectel.ru/100MB
https://proof.ovh.net/files/100Mb.dat
URLS
}

url_count() {
  download_urls | awk 'END {print NR}'
}

probe_url() {
  url=$1
  [ -n "$url" ] || return 1

  if command -v curl >/dev/null 2>&1; then
    probe_result=$(curl -fsSL --range 0-1023 \
      --connect-timeout "$BANDWIDTH_PROBE_TIMEOUT" \
      --limit-rate "$BANDWIDTH_PROBE_RATE" \
      --max-time "$BANDWIDTH_PROBE_TIMEOUT" \
      -o /dev/null -w '%{size_download}' "$url" 2>/dev/null) || true
    is_uint "$probe_result" || return 1
    [ "$probe_result" -gt 0 ]
    return $?
  fi

  if command -v wget >/dev/null 2>&1; then
    probe_file=$RUN_DIR/oalive-bandwidth-probe.$$
    rm -f "$probe_file" 2>/dev/null || true
    run_with_timeout "$BANDWIDTH_PROBE_TIMEOUT" wget -q \
      --timeout="$BANDWIDTH_PROBE_TIMEOUT" --tries=1 \
      --limit-rate="$BANDWIDTH_PROBE_RATE" \
      --header='Range: bytes=0-1023' -O "$probe_file" "$url" \
      >/dev/null 2>&1
    probe_size=$(wc -c <"$probe_file" 2>/dev/null || echo 0)
    rm -f "$probe_file" 2>/dev/null || true
    is_uint "$probe_size" || probe_size=0
    [ "$probe_size" -gt 0 ]
    return $?
  fi

  if command -v fetch >/dev/null 2>&1; then
    probe_file=$RUN_DIR/oalive-bandwidth-probe.$$
    rm -f "$probe_file" 2>/dev/null || true
    run_with_timeout "$BANDWIDTH_PROBE_TIMEOUT" fetch -q -o "$probe_file" -T "$BANDWIDTH_PROBE_TIMEOUT" "$url" \
      >/dev/null 2>&1
    probe_size=$(wc -c <"$probe_file" 2>/dev/null || echo 0)
    rm -f "$probe_file" 2>/dev/null || true
    is_uint "$probe_size" || probe_size=0
    [ "$probe_size" -gt 0 ]
    return $?
  fi
  return 1
}

url_at() {
  index=$1
  download_urls | awk -v n="$index" 'NR == n {print; exit}'
}

url_is_skipped() {
  [ -n "$BANDWIDTH_SKIP_URLS" ] || return 1
  printf '%s\n' "$BANDWIDTH_SKIP_URLS" | grep -Fqx "$1"
}

skip_url() {
  if [ -n "$BANDWIDTH_SKIP_URLS" ]; then
    BANDWIDTH_SKIP_URLS="$BANDWIDTH_SKIP_URLS
$1"
  else
    BANDWIDTH_SKIP_URLS=$1
  fi
}

select_url() {
  count=$(url_count)
  is_uint "$count" || count=0
  [ "$count" -gt 0 ] || return 1

  checks=$BANDWIDTH_URL_CHECKS
  [ "$checks" -gt 0 ] && [ "$checks" -lt "$count" ] || checks=$count
  minute=$(date '+%M' 2>/dev/null || echo 0)
  is_uint "$minute" || minute=0
  minute=$(canonical_uint "$minute")
  start=$((minute % count + 1))
  checked=0
  index=$start

  while [ "$checked" -lt "$checks" ]; do
    url=$(url_at "$index")
    if [ -n "$url" ] && ! url_is_skipped "$url" && probe_url "$url"; then
      printf '%s\n' "$url"
      return 0
    fi
    checked=$((checked + 1))
    index=$((index + 1))
    [ "$index" -le "$count" ] || index=1
  done

  return 1
}

speedtest_bin() {
  if command -v speedtest-cli >/dev/null 2>&1; then
    printf '%s\n' speedtest-cli
    return 0
  fi
  if [ -x "$SPEEDTEST_GO_BIN" ]; then
    printf '%s\n' "$SPEEDTEST_GO_BIN"
    return 0
  fi
  if command -v speedtest-go >/dev/null 2>&1; then
    printf '%s\n' speedtest-go
    return 0
  fi
  return 1
}

parse_download_mbps() {
  awk '
    tolower($0) ~ /download/ {
      for (i = 1; i <= NF; i++) {
        gsub(/[^0-9.]/, "", $i)
        if ($i ~ /^[0-9]+([.][0-9]+)?$/ && $i > 0) {
          print $i
          exit
        }
      }
    }
  '
}

measure_bandwidth_mbps() {
  if is_number "$BANDWIDTH_RATE_MBPS"; then
    printf '%s\n' "$BANDWIDTH_RATE_MBPS"
    return 0
  fi

  bin=$(speedtest_bin 2>/dev/null || true)
  if [ -n "$bin" ]; then
    if [ "$bin" = speedtest-cli ]; then
      value=$("$bin" --simple 2>/dev/null | parse_download_mbps | sed -n '1p')
    else
      value=$("$bin" 2>/dev/null | parse_download_mbps | sed -n '1p')
    fi
    if is_number "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
  fi

  printf '%s\n' "$BANDWIDTH_DEFAULT_MBPS"
}

rate_bytes_per_second() {
  mbps=$1
  awk -v mbps="$mbps" -v pct="$BANDWIDTH_RATE_PERCENT" 'BEGIN {
    rate = mbps * 1000000 / 8 * pct / 100
    if (rate < 1024) rate = 1024
    printf "%.0f\n", rate
  }'
}

run_with_timeout() {
  seconds=$1
  shift
  is_uint "$seconds" || seconds=1
  [ "$seconds" -ge 1 ] || seconds=1
  TIMEOUT_FILE=$RUN_DIR/oalive-bandwidth-timeout.$$
  rm -f "$TIMEOUT_FILE" 2>/dev/null || true
  RUN_TIMED_OUT=0
  "$@" &
  RUN_PID=$!
  (
    trap - EXIT HUP INT TERM
    sleep "$seconds"
    if kill -0 "$RUN_PID" 2>/dev/null; then
      : >"$TIMEOUT_FILE" 2>/dev/null || true
      kill "$RUN_PID" 2>/dev/null || true
    fi
  ) &
  TIMER_PID=$!
  rc=0
  wait "$RUN_PID" 2>/dev/null || rc=$?
  kill "$TIMER_PID" 2>/dev/null || true
  wait "$TIMER_PID" 2>/dev/null || true
  if [ -f "$TIMEOUT_FILE" ]; then
    RUN_TIMED_OUT=1
    rm -f "$TIMEOUT_FILE" 2>/dev/null || true
  fi
  RUN_PID=
  TIMER_PID=
  TIMEOUT_FILE=
  [ "$RUN_TIMED_OUT" -eq 1 ] && return 0
  return "$rc"
}

download_with_limit() {
  url=$1
  rate=$2
  seconds=$3

  if command -v curl >/dev/null 2>&1; then
    downloader=curl
  elif command -v wget >/dev/null 2>&1; then
    downloader=wget
  elif command -v fetch >/dev/null 2>&1; then
    downloader=fetch
    log "fetch不支持可靠限速，将仅按时长下载 / fetch has no reliable rate limit, using duration limit only"
  else
    log "未找到curl/wget/fetch，无法执行带宽占用 / curl/wget/fetch not found, cannot run bandwidth occupier"
    return 1
  fi

  start=$(epoch_seconds 2>/dev/null || echo 0)
  if is_uint "$start" && [ "$start" -gt 0 ]; then
    deadline=$((start + seconds))
  else
    deadline=0
  fi

  while :; do
    if [ "$deadline" -gt 0 ]; then
      current=$(epoch_seconds 2>/dev/null || echo 0)
      if ! is_uint "$current" || [ "$current" -ge "$deadline" ]; then
        return 0
      fi
      remaining=$((deadline - current))
      [ "$remaining" -ge 1 ] || return 0
    else
      remaining=$seconds
    fi

    case "$downloader" in
      curl)
        run_with_timeout "$remaining" curl -fsSL --connect-timeout 10 \
          --limit-rate "$rate" -o /dev/null "$url" 2>/dev/null
        ;;
      wget)
        run_with_timeout "$remaining" wget -q --timeout=10 --tries=1 \
          --limit-rate="$rate" -O /dev/null "$url"
        ;;
      fetch)
        run_with_timeout "$remaining" fetch -q -o /dev/null -T 10 "$url"
        ;;
    esac
    rc=$?
    [ "$RUN_TIMED_OUT" -eq 1 ] && return 0
    [ "$rc" -eq 0 ] || return "$rc"

    # A finite test file can finish before the requested duration. Restart it
    # while time remains so a 100 MB file does not shorten a six-minute run.
    [ "$deadline" -gt 0 ] || return 0
    sleep 1
  done
}

run_wget_mode() {
  count=$(url_count)
  is_uint "$count" || count=0
  [ "$count" -gt 0 ] || {
    log "没有配置带宽下载源，跳过本轮 / No bandwidth download source is configured, skipping this run"
    return 0
  }

  BANDWIDTH_SKIP_URLS=
  url=$(select_url 2>/dev/null || true)
  if [ -z "$url" ]; then
    log "没有可用带宽下载源，跳过本轮并等待下次调度 / No usable bandwidth download source, skipping this run until the next schedule"
    return 0
  fi

  mbps=$(measure_bandwidth_mbps)
  rate=$(rate_bytes_per_second "$mbps")
  seconds=$((BANDWIDTH_DURATION_MINUTES * 60))
  run_start=$(epoch_seconds 2>/dev/null || echo 0)
  if is_uint "$run_start" && [ "$run_start" -gt 0 ]; then
    run_deadline=$((run_start + seconds))
  else
    run_deadline=0
  fi
  attempt=1
  while [ "$attempt" -le "$count" ]; do
    if [ "$run_deadline" -gt 0 ]; then
      run_now=$(epoch_seconds 2>/dev/null || echo 0)
      if ! is_uint "$run_now" || [ "$run_now" -ge "$run_deadline" ]; then
        break
      fi
      attempt_seconds=$((run_deadline - run_now))
      [ "$attempt_seconds" -ge 1 ] || break
    else
      attempt_seconds=$seconds
    fi

    log "开始带宽占用：${BANDWIDTH_DURATION_MINUTES}分钟，测速=${mbps}Mbps，限速=${rate}B/s，URL=$url / Starting bandwidth occupier: ${BANDWIDTH_DURATION_MINUTES} minutes, measured=${mbps}Mbps, limit=${rate}B/s"
    if download_with_limit "$url" "$rate" "$attempt_seconds"; then
      log "带宽占用结束 / Bandwidth occupier finished"
      return 0
    fi

    skip_url "$url"
    log "下载源失败，将尝试下一个 / Download source failed, trying the next source: $url"
    attempt=$((attempt + 1))
    if [ "$run_deadline" -gt 0 ]; then
      run_now=$(epoch_seconds 2>/dev/null || echo 0)
      if ! is_uint "$run_now" || [ "$run_now" -ge "$run_deadline" ]; then
        break
      fi
    fi
    url=$(select_url 2>/dev/null || true)
    [ -n "$url" ] || break
  done

  log "没有可用带宽下载源，跳过本轮并等待下次调度 / No usable bandwidth download source, skipping this run until the next schedule"
  return 0
}

run_speedtest_mode() {
  bin=$(speedtest_bin 2>/dev/null || true)
  if [ -z "$bin" ]; then
    log "未找到speedtest工具，无法执行speedtest模式 / speedtest tool not found, cannot run speedtest mode"
    return 1
  fi

  i=1
  log "开始speedtest带宽占用，共${BANDWIDTH_SPEEDTEST_COUNT}次 / Starting speedtest bandwidth occupier, count=${BANDWIDTH_SPEEDTEST_COUNT}"
  while [ "$i" -le "$BANDWIDTH_SPEEDTEST_COUNT" ]; do
    if [ "$bin" = speedtest-cli ]; then
      "$bin" --simple >/dev/null 2>&1 || true
    else
      "$bin" >/dev/null 2>&1 || true
    fi
    i=$((i + 1))
  done
  log "speedtest带宽占用结束 / Speedtest bandwidth occupier finished"
}

if [ "${OALIVE_LIBRARY_MODE:-0}" != 1 ]; then
  case ${1:-} in
    --help|-h)
      printf '%s\n' "Usage: sh bandwidth_occupier.sh"
      printf '%s\n' "配置 / Config: BANDWIDTH_MODE, BANDWIDTH_DURATION_MINUTES, BANDWIDTH_RATE_PERCENT, BANDWIDTH_RATE_MBPS, BANDWIDTH_SPEEDTEST_COUNT, BANDWIDTH_URL, BANDWIDTH_URLS, BANDWIDTH_URL_FILE, BANDWIDTH_URL_CHECKS"
      exit 0
      ;;
    --check)
      normalize_settings
      if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || command -v fetch >/dev/null 2>&1; then
        printf '%s\n' "Bandwidth script OK / 带宽脚本检查通过"
        exit 0
      fi
      printf '%s\n' "No downloader found / 未找到下载工具"
      exit 1
      ;;
  esac

  normalize_settings
  acquire_lock
  trap terminate INT TERM
  trap cleanup EXIT

  case "$BANDWIDTH_MODE" in
    speedtest) run_speedtest_mode ;;
    *) run_wget_mode ;;
  esac
fi
