# Custom cron scheduling

The installer automatically chooses a scheduler: systemd when available, otherwise a cron supervisor on Linux/BSD.
Use this document only when you do not want the one-click installer to manage scheduling.

## Basic setup

Download and install runtime scripts:

```sh
curl -fsSL https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main/cpu-limit.sh -o /usr/local/bin/cpu-limit.sh
curl -fsSL https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main/memory-limit.sh -o /usr/local/bin/memory-limit.sh
curl -fsSL https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main/bandwidth_occupier.sh -o /usr/local/bin/bandwidth_occupier.sh
curl -fsSL https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main/oalive-cron-runner.sh -o /usr/local/bin/oalive-cron-runner.sh
chmod +x /usr/local/bin/cpu-limit.sh /usr/local/bin/memory-limit.sh /usr/local/bin/bandwidth_occupier.sh /usr/local/bin/oalive-cron-runner.sh
mkdir -p /etc/oalive /var/log/oalive /var/lib/oalive
```

Minimal config example:

```sh
cat >/etc/oalive/oalive.conf <<'EOF'
OALIVE_LOG_DIR=/var/log/oalive
OALIVE_STATE_DIR=/var/lib/oalive
OALIVE_RUN_DIR=/tmp
OALIVE_LOG_MAX_BYTES=131072
CPU_QUOTA_PERCENT=25
CPU_CYCLE_SECONDS=10
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
CPU_SCRIPT=/usr/local/bin/cpu-limit.sh
MEMORY_SCRIPT=/usr/local/bin/memory-limit.sh
BANDWIDTH_SCRIPT=/usr/local/bin/bandwidth_occupier.sh
EOF
```

Enable tasks:

```sh
cat >/etc/oalive/enabled.conf <<'EOF'
CPU_ENABLED=1
MEMORY_ENABLED=1
BANDWIDTH_ENABLED=1
EOF
```

## Cron supervisor

Recommended single cron entry. It runs a lightweight check every minute: starts CPU/memory task when missing; triggers bandwidth task on minute-accurate `BANDWIDTH_INTERVAL_MINUTES`, with lock-based reentry prevention.

```cron
* * * * * /usr/local/bin/oalive-cron-runner.sh >/dev/null 2>&1
```

Install to current root crontab:

```sh
(crontab -l 2>/dev/null; printf '%s\n' '* * * * * /usr/local/bin/oalive-cron-runner.sh >/dev/null 2>&1') | crontab -
```

## Manual run

CPU daemon task:

```sh
sh /usr/local/bin/cpu-limit.sh
```

Memory daemon task:

```sh
sh /usr/local/bin/memory-limit.sh
```

Bandwidth one-shot task:

```sh
sh /usr/local/bin/bandwidth_occupier.sh
```

All tasks use atomic locks. If started twice, the new instance detects the existing one and exits safely.

## Stop tasks

Preferred method:

```sh
sh oalive.sh --uninstall
```

For fully manual deployment, stop by lock PID:

```sh
for name in cpu-limit memory-limit bandwidth; do
  lock="/tmp/oalive-$name.lock/pid"
  [ -r "$lock" ] && kill "$(sed -n '1p' "$lock")" 2>/dev/null || true
done
```

Do not use broad `ps | grep | kill` commands; they can kill unrelated processes.
