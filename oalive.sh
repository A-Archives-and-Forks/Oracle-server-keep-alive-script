#!/bin/sh
# by spiritlhl
# from https://github.com/spiritLHLS/Oracle-server-keep-alive-script

ver="2026.08.25.09.36"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

BASE_URL=${OALIVE_BASE_URL:-https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main}
INSTALL_DIR=${OALIVE_INSTALL_DIR:-/usr/local/bin}
CONFIG_DIR=${OALIVE_CONFIG_DIR:-/etc/oalive}
CONFIG_FILE=${OALIVE_CONFIG:-$CONFIG_DIR/oalive.conf}
ENABLED_FILE=${OALIVE_ENABLED_CONFIG:-$CONFIG_DIR/enabled.conf}
LOG_DIR=${OALIVE_LOG_DIR:-/var/log/oalive}
STATE_DIR=${OALIVE_STATE_DIR:-/var/lib/oalive}
RUN_DIR=${OALIVE_RUN_DIR:-/tmp}
SYSTEMD_DIR=${OALIVE_SYSTEMD_DIR:-/etc/systemd/system}
DOWNLOAD_TIMEOUT=${OALIVE_DOWNLOAD_TIMEOUT:-30}
CRON_BEGIN="# OALIVE BEGIN"
CRON_END="# OALIVE END"

CPU_ENABLED=0
MEMORY_ENABLED=0
BANDWIDTH_ENABLED=0
CPU_QUOTA_PERCENT=
MEMORY_TARGET_PERCENT=25
MEMORY_HOLD_SECONDS=300
MEMORY_REST_SECONDS=300
MEMORY_MAX_MB=0
BANDWIDTH_MODE=wget
BANDWIDTH_INTERVAL_MINUTES=45
BANDWIDTH_DURATION_MINUTES=6
BANDWIDTH_RATE_PERCENT=30
BANDWIDTH_RATE_MBPS=auto
BANDWIDTH_DEFAULT_MBPS=10
BANDWIDTH_SPEEDTEST_COUNT=10
BANDWIDTH_URL=
BANDWIDTH_URLS=
BANDWIDTH_URL_FILE=
BANDWIDTH_URL_CHECKS=0
BANDWIDTH_PROBE_TIMEOUT=5
BANDWIDTH_PROBE_RATE=16384
SPEEDTEST_GO_BIN=/etc/speedtest-cli/speedtest-go
SPEEDTEST_GO_RELEASE_VERSION=1.8.1
SCHEDULER=auto
PKG_MANAGER=
OS_NAME=
OS_KERNEL=
SCRIPT_DIR=.

if [ -n "${ZSH_VERSION:-}" ]; then
  setopt NO_NOMATCH 2>/dev/null || true
fi

setup_script_dir() {
  case $0 in
    */*) SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" 2>/dev/null && pwd -P || printf '%s\n' ".") ;;
    *) SCRIPT_DIR=$(pwd -P 2>/dev/null || pwd) ;;
  esac
}

color() {
  code=$1
  shift
  if [ -t 1 ]; then
    printf '\033[%sm%s\033[0m\n' "$code" "$*"
  else
    printf '%s\n' "$*"
  fi
}

info() { color "32;1" "$1 / $2"; }
warn() { color "33;1" "$1 / $2"; }
err() { color "31;1" "$1 / $2" >&2; }
note() { color "36;1" "$1 / $2"; }

is_uint() {
  case ${1:-} in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_number() {
  awk -v n="${1:-}" 'BEGIN {exit (n ~ /^[0-9]+([.][0-9]+)?$/ ? 0 : 1)}'
}

sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

cron_escape() {
  printf '%s' "$1" | sed 's/%/\\%/g'
}

need_root() {
  uid=$(id -u 2>/dev/null || echo 1)
  if [ "$uid" != 0 ]; then
    err "请使用 root 用户运行本脚本" "Please run this script as root"
    exit 1
  fi
}

init_locale() {
  utf8_locale=$(locale -a 2>/dev/null | awk 'tolower($0) ~ /utf-?8/ {print; exit}')
  if [ -n "$utf8_locale" ]; then
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
  elif locale -a 2>/dev/null | grep -q '^C.UTF-8$'; then
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    export LANGUAGE=C.UTF-8
  fi
}

ask() {
  zh=$1
  en=$2
  default=${3:-}
  if [ -n "$default" ]; then
    printf '%s / %s [%s]: ' "$zh" "$en" "$default"
  else
    printf '%s / %s: ' "$zh" "$en"
  fi
  IFS= read -r REPLY_VALUE || REPLY_VALUE=
  [ -n "$REPLY_VALUE" ] || REPLY_VALUE=$default
}

ask_yn() {
  zh=$1
  en=$2
  default=$3
  while :; do
    if [ "$default" = y ]; then
      suffix="[Y/n]"
    else
      suffix="[y/N]"
    fi
    printf '%s / %s %s: ' "$zh" "$en" "$suffix"
    IFS= read -r answer || answer=
    [ -n "$answer" ] || answer=$default
    case $answer in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) warn "请输入 y 或 n" "Please enter y or n" ;;
    esac
  done
}

ask_choice() {
  zh=$1
  en=$2
  min=$3
  max=$4
  default=$5
  while :; do
    ask "$zh" "$en" "$default"
    if is_uint "$REPLY_VALUE" && [ "$REPLY_VALUE" -ge "$min" ] && [ "$REPLY_VALUE" -le "$max" ]; then
      return 0
    fi
    warn "请输入 $min 到 $max 之间的数字" "Please enter a number from $min to $max"
  done
}

ask_uint() {
  zh=$1
  en=$2
  default=$3
  min=$4
  max=$5
  while :; do
    ask "$zh" "$en" "$default"
    if is_uint "$REPLY_VALUE" && [ "$REPLY_VALUE" -ge "$min" ] && [ "$REPLY_VALUE" -le "$max" ]; then
      return 0
    fi
    warn "请输入 $min 到 $max 之间的整数" "Please enter an integer from $min to $max"
  done
}

ask_number() {
  zh=$1
  en=$2
  default=$3
  while :; do
    ask "$zh" "$en" "$default"
    if is_number "$REPLY_VALUE"; then
      return 0
    fi
    warn "请输入数字" "Please enter a number"
  done
}

ask_positive_number() {
  zh=$1
  en=$2
  default=$3
  while :; do
    ask_number "$zh" "$en" "$default"
    if awk -v n="$REPLY_VALUE" 'BEGIN {exit (n > 0 ? 0 : 1)}'; then
      return 0
    fi
    warn "请输入大于0的数字" "Please enter a number greater than 0"
  done
}

detect_os() {
  OS_KERNEL=$(uname -s 2>/dev/null || echo unknown)
  if [ -r /etc/os-release ]; then
    OS_NAME=$(awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)
    [ -n "$OS_NAME" ] || OS_NAME=$(awk -F= '/^NAME=/{gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)
  fi
  [ -n "$OS_NAME" ] || OS_NAME=$OS_KERNEL
}

detect_package_manager() {
  for pm in apt-get dnf yum microdnf zypper apk pacman pkg pkg_add pkgin emerge xbps-install; do
    if command -v "$pm" >/dev/null 2>&1; then
      PKG_MANAGER=$pm
      return 0
    fi
  done
  PKG_MANAGER=none
  return 1
}

pkg_update() {
  case $PKG_MANAGER in
    apt-get) apt-get update ;;
    dnf) dnf -y makecache ;;
    yum) yum -y makecache ;;
    microdnf) microdnf -y makecache ;;
    zypper) zypper --non-interactive refresh ;;
    apk) apk update ;;
    pacman) pacman -Sy --noconfirm ;;
    pkg) pkg update -f ;;
    pkgin) pkgin -y update ;;
    xbps-install) xbps-install -S ;;
    emerge) emerge --sync ;;
    *) warn "未检测到可用包管理器，跳过更新" "No supported package manager detected, skipping update"; return 1 ;;
  esac
}

pkg_install() {
  [ "$#" -gt 0 ] || return 0
  case $PKG_MANAGER in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf -y install "$@" ;;
    yum) yum -y install "$@" ;;
    microdnf) microdnf -y install "$@" ;;
    zypper) zypper --non-interactive install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    pacman) pacman -Sy --noconfirm --needed "$@" ;;
    pkg) pkg install -y "$@" ;;
    pkg_add) pkg_add -I "$@" ;;
    pkgin) pkgin -y install "$@" ;;
    xbps-install) xbps-install -y "$@" ;;
    emerge) emerge "$@" ;;
    *) return 1 ;;
  esac
}

pkg_remove() {
  [ "$#" -gt 0 ] || return 0
  case $PKG_MANAGER in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@" ;;
    dnf) dnf -y remove "$@" ;;
    yum) yum -y remove "$@" ;;
    microdnf) microdnf -y remove "$@" ;;
    zypper) zypper --non-interactive remove -y "$@" ;;
    apk) apk del "$@" ;;
    pacman) pacman -Rsc --noconfirm "$@" ;;
    pkg) pkg delete -y "$@" ;;
    pkg_add|pkg_delete) pkg_delete "$@" ;;
    pkgin) pkgin -y remove "$@" ;;
    xbps-install) xbps-remove -Ry "$@" ;;
    emerge) emerge --depclean "$@" ;;
    *) return 1 ;;
  esac
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null || {
    err "无法创建安装目录" "Failed to create install directories"
    exit 1
  }
}

refresh_paths_from_config() {
  LOG_DIR=${OALIVE_LOG_DIR:-$LOG_DIR}
  STATE_DIR=${OALIVE_STATE_DIR:-$STATE_DIR}
  RUN_DIR=${OALIVE_RUN_DIR:-$RUN_DIR}
}

download_to() {
  download_url=$1
  download_dest=$2
  is_uint "$DOWNLOAD_TIMEOUT" || DOWNLOAD_TIMEOUT=30
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time "$DOWNLOAD_TIMEOUT" "$download_url" -o "$download_dest"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=10 --tries=3 -O "$download_dest" "$download_url"
    return $?
  fi
  if command -v fetch >/dev/null 2>&1; then
    fetch -q -T "$DOWNLOAD_TIMEOUT" -o "$download_dest" "$download_url"
    return $?
  fi
  return 1
}

install_file() {
  name=$1
  dest=$2
  mode=$3
  tmp=$dest.tmp.$$
  if [ -f "$SCRIPT_DIR/$name" ]; then
    cp "$SCRIPT_DIR/$name" "$tmp" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
  else
    download_to "$BASE_URL/$name" "$tmp" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
  fi
  chmod "$mode" "$tmp" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  mv "$tmp" "$dest" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
}

get_cores() {
  cores=
  if command -v getconf >/dev/null 2>&1; then
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
  fi
  if ! is_uint "$cores" || [ "$cores" -lt 1 ]; then
    cores=$(sysctl -n hw.ncpu 2>/dev/null || true)
  fi
  if ! is_uint "$cores" || [ "$cores" -lt 1 ]; then
    cores=$(awk '/^processor[[:space:]]*:/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null || true)
  fi
  if ! is_uint "$cores" || [ "$cores" -lt 1 ]; then
    cores=1
  fi
  printf '%s\n' "$cores"
}

default_cpu_quota() {
  cores=$(get_cores)
  case $cores in
    2|3|4) printf '%s\n' $((cores * 20)) ;;
    *) printf '%s\n' 25 ;;
  esac
}

detect_scheduler() {
  case ${OALIVE_SCHEDULER:-auto} in
    systemd) SCHEDULER=systemd; return 0 ;;
    cron) SCHEDULER=cron; return 0 ;;
  esac
  if [ "$OS_KERNEL" = Linux ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    SCHEDULER=systemd
  else
    SCHEDULER=cron
  fi
}

write_config() {
  sq_install_dir=$(sq "$INSTALL_DIR")
  sq_log_dir=$(sq "$LOG_DIR")
  sq_state_dir=$(sq "$STATE_DIR")
  sq_run_dir=$(sq "$RUN_DIR")
  sq_speedtest=$(sq "$SPEEDTEST_GO_BIN")
  sq_bandwidth_url=$(sq "$BANDWIDTH_URL")
  sq_bandwidth_urls=$(sq "$BANDWIDTH_URLS")
  sq_bandwidth_url_file=$(sq "$BANDWIDTH_URL_FILE")
  sq_cpu_script=$(sq "$INSTALL_DIR/cpu-limit.sh")
  sq_memory_script=$(sq "$INSTALL_DIR/memory-limit.sh")
  sq_bandwidth_script=$(sq "$INSTALL_DIR/bandwidth_occupier.sh")
  cat >"$CONFIG_FILE" <<EOF
# Oracle-server-keep-alive-script runtime config.
# This file is POSIX shell syntax and is loaded by /bin/sh.
INSTALL_DIR=$sq_install_dir
OALIVE_LOG_DIR=$sq_log_dir
OALIVE_STATE_DIR=$sq_state_dir
OALIVE_RUN_DIR=$sq_run_dir
OALIVE_LOG_MAX_BYTES=131072
CPU_QUOTA_PERCENT=$CPU_QUOTA_PERCENT
CPU_CYCLE_SECONDS=10
MEMORY_TARGET_PERCENT=$MEMORY_TARGET_PERCENT
MEMORY_HOLD_SECONDS=$MEMORY_HOLD_SECONDS
MEMORY_REST_SECONDS=$MEMORY_REST_SECONDS
MEMORY_MAX_MB=$MEMORY_MAX_MB
BANDWIDTH_MODE=$BANDWIDTH_MODE
BANDWIDTH_INTERVAL_MINUTES=$BANDWIDTH_INTERVAL_MINUTES
BANDWIDTH_DURATION_MINUTES=$BANDWIDTH_DURATION_MINUTES
BANDWIDTH_RATE_PERCENT=$BANDWIDTH_RATE_PERCENT
BANDWIDTH_RATE_MBPS=$BANDWIDTH_RATE_MBPS
BANDWIDTH_DEFAULT_MBPS=$BANDWIDTH_DEFAULT_MBPS
BANDWIDTH_SPEEDTEST_COUNT=$BANDWIDTH_SPEEDTEST_COUNT
BANDWIDTH_URL=$sq_bandwidth_url
BANDWIDTH_URLS=$sq_bandwidth_urls
BANDWIDTH_URL_FILE=$sq_bandwidth_url_file
BANDWIDTH_URL_CHECKS=$BANDWIDTH_URL_CHECKS
BANDWIDTH_PROBE_TIMEOUT=$BANDWIDTH_PROBE_TIMEOUT
BANDWIDTH_PROBE_RATE=$BANDWIDTH_PROBE_RATE
SPEEDTEST_GO_BIN=$sq_speedtest
CPU_SCRIPT=$sq_cpu_script
MEMORY_SCRIPT=$sq_memory_script
BANDWIDTH_SCRIPT=$sq_bandwidth_script
EOF
  chmod 600 "$CONFIG_FILE"

  cat >"$ENABLED_FILE" <<EOF
CPU_ENABLED=$CPU_ENABLED
MEMORY_ENABLED=$MEMORY_ENABLED
BANDWIDTH_ENABLED=$BANDWIDTH_ENABLED
EOF
  chmod 600 "$ENABLED_FILE"
}

install_runtime_files() {
  install_file cpu-limit.sh "$INSTALL_DIR/cpu-limit.sh" 755 || return 1
  install_file memory-limit.sh "$INSTALL_DIR/memory-limit.sh" 755 || return 1
  install_file bandwidth_occupier.sh "$INSTALL_DIR/bandwidth_occupier.sh" 755 || return 1
  install_file oalive-cron-runner.sh "$INSTALL_DIR/oalive-cron-runner.sh" 755 || return 1
}

systemd_stop_disable() {
  unit=$1
  systemctl stop "$unit" >/dev/null 2>&1 || true
  systemctl disable "$unit" >/dev/null 2>&1 || true
}

systemd_enable_restart() {
  unit=$1
  systemctl daemon-reload
  systemctl enable "$unit" >/dev/null 2>&1 || true
  systemctl restart "$unit"
}

install_systemd() {
  mkdir -p "$SYSTEMD_DIR" || return 1
  install_file cpu-limit.service "$SYSTEMD_DIR/cpu-limit.service" 644 || return 1
  install_file memory-limit.service "$SYSTEMD_DIR/memory-limit.service" 644 || return 1
  install_file bandwidth_occupier.service "$SYSTEMD_DIR/bandwidth_occupier.service" 644 || return 1
  install_file bandwidth_occupier.timer "$SYSTEMD_DIR/bandwidth_occupier.timer" 644 || return 1

  mkdir -p "$SYSTEMD_DIR/cpu-limit.service.d" "$SYSTEMD_DIR/bandwidth_occupier.timer.d" || return 1
  cat >"$SYSTEMD_DIR/cpu-limit.service.d/quota.conf" <<EOF
[Service]
CPUQuota=${CPU_QUOTA_PERCENT}%
EOF
  [ -s "$SYSTEMD_DIR/cpu-limit.service.d/quota.conf" ] || return 1
  cat >"$SYSTEMD_DIR/bandwidth_occupier.timer.d/interval.conf" <<EOF
[Timer]
OnUnitActiveSec=
OnUnitActiveSec=${BANDWIDTH_INTERVAL_MINUTES}min
EOF
  [ -s "$SYSTEMD_DIR/bandwidth_occupier.timer.d/interval.conf" ] || return 1

  if [ "$CPU_ENABLED" = 1 ]; then
    systemd_enable_restart cpu-limit.service || warn "CPU服务启动失败，请查看日志" "Failed to start CPU service, please check logs"
  else
    systemd_stop_disable cpu-limit.service
  fi

  if [ "$MEMORY_ENABLED" = 1 ]; then
    systemd_enable_restart memory-limit.service || warn "内存服务启动失败，请查看日志" "Failed to start memory service, please check logs"
  else
    systemd_stop_disable memory-limit.service
  fi

  if [ "$BANDWIDTH_ENABLED" = 1 ]; then
    systemctl daemon-reload
    systemctl enable bandwidth_occupier.timer >/dev/null 2>&1 || true
    systemctl restart bandwidth_occupier.timer || warn "带宽定时器启动失败，请查看日志" "Failed to start bandwidth timer, please check logs"
  else
    systemd_stop_disable bandwidth_occupier.timer
    systemd_stop_disable bandwidth_occupier.service
  fi

  systemctl daemon-reload
}

remove_cron_block() {
  command -v crontab >/dev/null 2>&1 || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/oalive-cron.XXXXXX") || return 1
  new=$(mktemp "${TMPDIR:-/tmp}/oalive-cron-new.XXXXXX") || {
    rm -f "$tmp"
    return 1
  }
  crontab -l >"$tmp" 2>/dev/null || : >"$tmp"
  awk -v begin="$CRON_BEGIN" -v end="$CRON_END" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$tmp" >"$new"
  crontab "$new" 2>/dev/null || true
  rm -f "$tmp" "$new"
}

install_cron() {
  if ! command -v crontab >/dev/null 2>&1; then
    warn "未找到 crontab，将只启动当前进程，重启后需手动运行" "crontab not found; starting now only, manual restart is required after reboot"
    /bin/sh "$INSTALL_DIR/oalive-cron-runner.sh" >/dev/null 2>&1 || true
    return 0
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/oalive-cron.XXXXXX") || return 1
  new=$(mktemp "${TMPDIR:-/tmp}/oalive-cron-new.XXXXXX") || {
    rm -f "$tmp"
    return 1
  }
  crontab -l >"$tmp" 2>/dev/null || : >"$tmp"
  awk -v begin="$CRON_BEGIN" -v end="$CRON_END" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$tmp" >"$new"
  cron_runner_cmd=$(cron_escape "/bin/sh $(sq "$INSTALL_DIR/oalive-cron-runner.sh") >/dev/null 2>&1")
  {
    printf '%s\n' "$CRON_BEGIN"
    printf '%s\n' "* * * * * $cron_runner_cmd"
    printf '%s\n' "$CRON_END"
  } >>"$new"
  if ! crontab "$new"; then
    rm -f "$tmp" "$new"
    warn "cron任务安装失败，将只启动当前进程" "Failed to install cron job; starting current process only"
    /bin/sh "$INSTALL_DIR/oalive-cron-runner.sh" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "$tmp" "$new"
  /bin/sh "$INSTALL_DIR/oalive-cron-runner.sh" >/dev/null 2>&1 || true
}

service_status() {
  unit=$1
  if [ "$SCHEDULER" = systemd ] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      printf '%s\n' active
    else
      printf '%s\n' inactive
    fi
  else
    printf '%s\n' cron
  fi
}

install_speedtest_go_linux() {
  [ "$OS_KERNEL" = Linux ] || return 1
  if [ -x "$SPEEDTEST_GO_BIN" ] &&
      "$SPEEDTEST_GO_BIN" --version 2>&1 | grep -Fq "v$SPEEDTEST_GO_RELEASE_VERSION"; then
    return 0
  fi
  command -v tar >/dev/null 2>&1 || pkg_install tar >/dev/null 2>&1 || true
  arch=$(uname -m 2>/dev/null || echo x86_64)
  case $arch in
    x86_64|amd64|x64) asset_arch=x86_64 ;;
    i386|i686) asset_arch=i386 ;;
    aarch64|arm64|armv7l|armv8|armv8l) asset_arch=arm64 ;;
    s390x) asset_arch=s390x ;;
    riscv64) asset_arch=riscv64 ;;
    ppc64le) asset_arch=ppc64le ;;
    ppc64) asset_arch=ppc64 ;;
    *) return 1 ;;
  esac
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/oalive-speedtest.XXXXXX") || return 1
  url="https://github.com/showwin/speedtest-go/releases/download/v${SPEEDTEST_GO_RELEASE_VERSION}/speedtest-go_${SPEEDTEST_GO_RELEASE_VERSION}_Linux_${asset_arch}.tar.gz"
  if download_to "$url" "$tmpdir/speedtest-go.tar.gz" && mkdir -p "$(dirname "$SPEEDTEST_GO_BIN")" && tar -zxf "$tmpdir/speedtest-go.tar.gz" -C "$tmpdir"; then
    speedtest_path=$(find "$tmpdir" -type f -name speedtest-go 2>/dev/null | sed -n '1p')
    if [ -n "$speedtest_path" ]; then
      cp "$speedtest_path" "$SPEEDTEST_GO_BIN"
      chmod 755 "$SPEEDTEST_GO_BIN"
      rm -rf "$tmpdir"
      return 0
    fi
  fi
  rm -rf "$tmpdir"
  return 1
}

ensure_speedtest_tool() {
  command -v speedtest-cli >/dev/null 2>&1 && return 0
  if [ -x "$SPEEDTEST_GO_BIN" ]; then
    install_speedtest_go_linux && return 0
  fi
  command -v speedtest-go >/dev/null 2>&1 && return 0

  pkg_install speedtest-cli >/dev/null 2>&1 && command -v speedtest-cli >/dev/null 2>&1 && return 0
  pkg_install speedtest-go >/dev/null 2>&1 && command -v speedtest-go >/dev/null 2>&1 && return 0
  install_speedtest_go_linux && return 0

  return 1
}

ensure_basic_tools() {
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1 && ! command -v fetch >/dev/null 2>&1; then
    warn "未找到下载工具，尝试安装 curl" "No downloader found, trying to install curl"
    pkg_install curl >/dev/null 2>&1 || pkg_install wget >/dev/null 2>&1 || true
  fi
}

install_boinc() {
  if [ "$OS_KERNEL" != Linux ]; then
    warn "BOINC Docker模式仅支持Linux，已跳过CPU占用" "BOINC Docker mode only supports Linux; CPU occupier skipped"
    CPU_ENABLED=0
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    warn "未找到Docker，尝试安装" "Docker not found, trying to install it"
    pkg_install docker docker.io docker-ce docker-cli >/dev/null 2>&1 || true
  fi
  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker安装失败，已改用本机CPU占用模式" "Docker install failed, falling back to native CPU occupier"
    CPU_ENABLED=1
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  docker rm -f boinc >/dev/null 2>&1 || true
  docker run -d --restart unless-stopped --name boinc -v /var/lib/boinc:/var/lib/boinc -e "BOINC_CMD_LINE_OPTIONS=--allow_remote_gui_rpc --cpu_usage_limit=20" boinc/client >/dev/null 2>&1 || {
    warn "BOINC容器启动失败，已改用本机CPU占用模式" "BOINC container failed to start, falling back to native CPU occupier"
    CPU_ENABLED=1
    return 0
  }
  CPU_ENABLED=0
  info "BOINC容器已启动" "BOINC container started"
}

pre_check() {
  detect_package_manager || true
  if ask_yn "是否更新包管理器缓存" "Update package manager cache" n; then
    pkg_update || warn "包管理器缓存更新失败，继续安装" "Package cache update failed, continuing"
  fi
  ensure_basic_tools
}

configure_install() {
  CPU_QUOTA_PERCENT=$(default_cpu_quota)

  note "当前系统：$OS_NAME ($OS_KERNEL)，调度器：$SCHEDULER，包管理器：$PKG_MANAGER" "System: $OS_NAME ($OS_KERNEL), scheduler: $SCHEDULER, package manager: $PKG_MANAGER"
  note "CPU默认目标：${CPU_QUOTA_PERCENT}%单核配额" "Default CPU target: ${CPU_QUOTA_PERCENT}% of one-core quota"

  printf '%s\n' "选择CPU占用模式 / Choose CPU occupier mode:"
  printf '%s\n' "1. 本机POSIX占用，支持Linux/BSD [推荐] / Native POSIX occupier for Linux/BSD [recommended]"
  printf '%s\n' "2. BOINC Docker模式，仅Linux可用 / BOINC Docker mode, Linux only"
  printf '%s\n' "3. 不启用CPU占用 / Disable CPU occupier"
  ask_choice "你的选择" "Your choice" 1 3 1
  case $REPLY_VALUE in
    1)
      CPU_ENABLED=1
      ask_uint "CPU目标百分比（单核配额）" "CPU target percent of one-core quota" "$CPU_QUOTA_PERCENT" 1 400
      CPU_QUOTA_PERCENT=$REPLY_VALUE
      ;;
    2)
      install_boinc
      ;;
    3)
      CPU_ENABLED=0
      ;;
  esac

  if ask_yn "是否启用内存占用" "Enable memory occupier" y; then
    MEMORY_ENABLED=1
    ask_uint "目标内存使用百分比" "Target memory usage percent" "$MEMORY_TARGET_PERCENT" 1 90
    MEMORY_TARGET_PERCENT=$REPLY_VALUE
    ask_uint "每轮保持秒数" "Hold seconds per cycle" "$MEMORY_HOLD_SECONDS" 1 86400
    MEMORY_HOLD_SECONDS=$REPLY_VALUE
    ask_uint "每轮释放后休息秒数" "Rest seconds per cycle" "$MEMORY_REST_SECONDS" 1 86400
    MEMORY_REST_SECONDS=$REPLY_VALUE
  else
    MEMORY_ENABLED=0
  fi

  if ask_yn "是否启用带宽占用" "Enable bandwidth occupier" y; then
    BANDWIDTH_ENABLED=1
    printf '%s\n' "选择带宽占用模式 / Choose bandwidth mode:"
    printf '%s\n' "1. speedtest模式，按次数跑测速 / speedtest mode, run speed tests by count"
    printf '%s\n' "2. 受控下载模式，可按速率和时长限制 [推荐] / Controlled download mode with rate and duration limits [recommended]"
    ask_choice "你的选择" "Your choice" 1 2 2
    if [ "$REPLY_VALUE" = 1 ]; then
      BANDWIDTH_MODE=speedtest
      ask_uint "每轮speedtest次数" "Speedtest count per run" "$BANDWIDTH_SPEEDTEST_COUNT" 1 100
      BANDWIDTH_SPEEDTEST_COUNT=$REPLY_VALUE
      ensure_speedtest_tool || warn "未安装speedtest工具，运行时会失败；请查看README手动安装" "No speedtest tool installed; runtime may fail, see README for manual install"
    else
      BANDWIDTH_MODE=wget
      if ask_yn "是否自定义带宽参数" "Customize bandwidth parameters" n; then
        ask_positive_number "下载速率Mbps" "Download rate in Mbps" 10
        BANDWIDTH_RATE_MBPS=$REPLY_VALUE
        BANDWIDTH_RATE_PERCENT=100
        ask_uint "每轮下载时长（分钟）" "Download duration per run (minutes)" "$BANDWIDTH_DURATION_MINUTES" 1 1440
        BANDWIDTH_DURATION_MINUTES=$REPLY_VALUE
        ask_uint "触发间隔（分钟）" "Trigger interval (minutes)" "$BANDWIDTH_INTERVAL_MINUTES" 1 10080
        BANDWIDTH_INTERVAL_MINUTES=$REPLY_VALUE
      else
        BANDWIDTH_RATE_MBPS=auto
        BANDWIDTH_RATE_PERCENT=30
        BANDWIDTH_DURATION_MINUTES=6
        BANDWIDTH_INTERVAL_MINUTES=45
        ensure_speedtest_tool || warn "未安装speedtest工具，将使用默认10Mbps估算值限速" "No speedtest tool installed; default 10Mbps estimate will be used"
      fi
    fi
  else
    BANDWIDTH_ENABLED=0
  fi
}

install_all() {
  need_root
  ensure_dirs
  pre_check
  configure_install
  write_config
  install_runtime_files || {
    err "运行脚本安装失败" "Failed to install runtime scripts"
    exit 1
  }

  if [ "$SCHEDULER" = systemd ]; then
    install_systemd || {
      warn "systemd安装失败，回退到cron调度" "systemd install failed, falling back to cron"
      SCHEDULER=cron
      install_cron
    }
  else
    install_cron
  fi

  info "安装完成，配置文件：$CONFIG_FILE，日志目录：$LOG_DIR" "Install complete, config: $CONFIG_FILE, logs: $LOG_DIR"
}

stop_by_lock() {
  name=$1
  for dir in "$RUN_DIR/oalive-$name.lock" "/tmp/oalive-$name.lock"; do
    [ -r "$dir/pid" ] || continue
    pid=$(sed -n '1p' "$dir/pid" 2>/dev/null || true)
    if is_uint "$pid" && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -rf "$dir" 2>/dev/null || true
  done
}

kill_script_path() {
  script=$1
  [ -n "$script" ] || return 0
  (ps -eo pid= -o args= 2>/dev/null || ps ax -o pid= -o command= 2>/dev/null) |
    awk -v s="$script" -v self="$$" '
      $1 == self {next}
      index($0, s) {
        command = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command)
        pos = index(command, s)
        if (pos > 0) {
          before = pos == 1 ? " " : substr(command, pos - 1, 1)
          after = substr(command, pos + length(s), 1)
          if ((before == " " || before == "\t") && (after == "" || after == " " || after == "\t")) print $1
        }
      }
    ' |
    while IFS= read -r pid; do
    is_uint "$pid" && kill "$pid" 2>/dev/null || true
  done
}

uninstall() {
  need_root
  [ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
  refresh_paths_from_config

  if command -v systemctl >/dev/null 2>&1; then
    systemd_stop_disable cpu-limit.service
    systemd_stop_disable memory-limit.service
    systemd_stop_disable bandwidth_occupier.timer
    systemd_stop_disable bandwidth_occupier.service
    rm -rf "$SYSTEMD_DIR/cpu-limit.service" \
      "$SYSTEMD_DIR/memory-limit.service" \
      "$SYSTEMD_DIR/bandwidth_occupier.service" \
      "$SYSTEMD_DIR/bandwidth_occupier.timer" \
      "$SYSTEMD_DIR/cpu-limit.service.d" \
      "$SYSTEMD_DIR/bandwidth_occupier.timer.d"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  remove_cron_block
  stop_by_lock cpu-limit
  stop_by_lock memory-limit
  stop_by_lock bandwidth
  kill_script_path "$INSTALL_DIR/cpu-limit.sh"
  kill_script_path "$INSTALL_DIR/memory-limit.sh"
  kill_script_path "$INSTALL_DIR/bandwidth_occupier.sh"
  docker rm -f boinc >/dev/null 2>&1 || true

  rm -f "$INSTALL_DIR/cpu-limit.sh" \
    "$INSTALL_DIR/memory-limit.sh" \
    "$INSTALL_DIR/bandwidth_occupier.sh" \
    "$INSTALL_DIR/oalive-cron-runner.sh"
  rm -rf "$CONFIG_DIR" "$STATE_DIR"

  info "卸载完成" "Uninstall complete"
}

status() {
  detect_scheduler
  [ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
  [ -r "$ENABLED_FILE" ] && . "$ENABLED_FILE"
  refresh_paths_from_config
  note "当前脚本版本：$ver" "Current script version: $ver"
  note "系统：$OS_NAME ($OS_KERNEL)" "System: $OS_NAME ($OS_KERNEL)"
  note "调度器：$SCHEDULER" "Scheduler: $SCHEDULER"
  note "配置文件：$CONFIG_FILE" "Config file: $CONFIG_FILE"

  if [ "$SCHEDULER" = systemd ]; then
    note "CPU服务：$(service_status cpu-limit.service)" "CPU service: $(service_status cpu-limit.service)"
    note "内存服务：$(service_status memory-limit.service)" "Memory service: $(service_status memory-limit.service)"
    note "带宽定时器：$(service_status bandwidth_occupier.timer)" "Bandwidth timer: $(service_status bandwidth_occupier.timer)"
  else
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "$CRON_BEGIN"; then
      note "cron任务：已安装" "cron job: installed"
    else
      note "cron任务：未安装" "cron job: not installed"
    fi
    note "CPU启用：$CPU_ENABLED" "CPU enabled: $CPU_ENABLED"
    note "内存启用：$MEMORY_ENABLED" "Memory enabled: $MEMORY_ENABLED"
    note "带宽启用：$BANDWIDTH_ENABLED" "Bandwidth enabled: $BANDWIDTH_ENABLED"
  fi
}

checkver() {
  tmp=$(mktemp "${TMPDIR:-/tmp}/oalive-update.XXXXXX") || exit 1
  if ! download_to "$BASE_URL/oalive.sh" "$tmp"; then
    rm -f "$tmp"
    err "下载新版脚本失败" "Failed to download updated script"
    exit 1
  fi
  new_ver=$(awk -F= '/^ver=/{gsub(/"/, "", $2); print $2; exit}' "$tmp")
  if [ -n "$new_ver" ] && [ "$new_ver" != "$ver" ]; then
    chmod 755 "$tmp"
    case $0 in
      */*) update_target=$0 ;;
      *) update_target=$SCRIPT_DIR/oalive.sh ;;
    esac
    if cp "$tmp" "$update_target" 2>/dev/null; then
      rm -f "$tmp"
      info "脚本已更新：$ver -> $new_ver，请重新运行" "Script updated: $ver -> $new_ver, please run it again"
    else
      mv "$tmp" "$SCRIPT_DIR/oalive.sh.new"
      info "新版脚本已保存到 $SCRIPT_DIR/oalive.sh.new" "Updated script saved to $SCRIPT_DIR/oalive.sh.new"
    fi
  else
    rm -f "$tmp"
    info "当前已是最新脚本" "Current script is already up to date"
  fi
}

usage() {
  printf '%s\n' "Oracle-server-keep-alive-script $ver"
  printf '%s\n' "Usage: sh oalive.sh [--install|--uninstall|--status|--update|--help]"
}

main_menu() {
  status
  printf '%s\n' ""
  printf '%s\n' "选择你的选项 / Choose an option:"
  printf '%s\n' "1. 安装或重装保活服务 / Install or reinstall keep-alive services"
  printf '%s\n' "2. 卸载保活服务 / Uninstall keep-alive services"
  printf '%s\n' "3. 更新安装引导脚本 / Update installer script"
  printf '%s\n' "4. 退出 / Exit"
  ask_choice "你的选择" "Your choice" 1 4 1
  case $REPLY_VALUE in
    1) install_all ;;
    2) uninstall ;;
    3) checkver ;;
    4) info "退出程序" "Exit"; exit 0 ;;
  esac
}

if [ "${OALIVE_LIBRARY_MODE:-0}" != 1 ]; then
  setup_script_dir
  init_locale
  detect_os
  detect_package_manager || true
  detect_scheduler

  case ${1:-} in
    --install|install) install_all ;;
    --uninstall|uninstall) uninstall ;;
    --status|status) status ;;
    --update|update) checkver ;;
    --help|-h|help) usage ;;
    '') main_menu ;;
    *) usage; exit 1 ;;
  esac
fi
