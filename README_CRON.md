# 自定义定时任务

默认情况不需要看这个文件。

安装脚本会自动选调度器：有 systemd 就用 systemd；没有就用 cron 监督器（Linux/BSD）。

只有你不想让一键安装器管定时，才需要手动按这里的命令做。

英文版见 [README_CRON_EN.md](README_CRON_EN.md)。

## 基本准备

下载并安装运行脚本：

```sh
curl -fsSL https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main/cpu-limit.sh -o /usr/local/bin/cpu-limit.sh
curl -fsSL https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main/memory-limit.sh -o /usr/local/bin/memory-limit.sh
curl -fsSL https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main/bandwidth_occupier.sh -o /usr/local/bin/bandwidth_occupier.sh
curl -fsSL https://raw.githubusercontent.com/spiritLHLS/Oracle-server-keep-alive-script/main/oalive-cron-runner.sh -o /usr/local/bin/oalive-cron-runner.sh
chmod +x /usr/local/bin/cpu-limit.sh /usr/local/bin/memory-limit.sh /usr/local/bin/bandwidth_occupier.sh /usr/local/bin/oalive-cron-runner.sh
mkdir -p /etc/oalive /var/log/oalive /var/lib/oalive
```

最小配置示例：

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

选择要启用的任务：

```sh
cat >/etc/oalive/enabled.conf <<'EOF'
CPU_ENABLED=1
MEMORY_ENABLED=1
BANDWIDTH_ENABLED=1
EOF
```

## cron 监督器

推荐只加一条 cron。

它每分钟轻量检查一次：CPU/内存任务不在就拉起；带宽任务按 `BANDWIDTH_INTERVAL_MINUTES` 精确到分钟触发，并由锁避免重入。

```cron
* * * * * /usr/local/bin/oalive-cron-runner.sh >/dev/null 2>&1
```

安装到当前 root crontab：

```sh
(crontab -l 2>/dev/null; printf '%s\n' '* * * * * /usr/local/bin/oalive-cron-runner.sh >/dev/null 2>&1') | crontab -
```

## 手动运行

CPU 长驻任务：

```sh
sh /usr/local/bin/cpu-limit.sh
```

内存长驻任务：

```sh
sh /usr/local/bin/memory-limit.sh
```

带宽单次任务：

```sh
sh /usr/local/bin/bandwidth_occupier.sh
```

所有任务都有原子锁。重复运行时，新的实例会发现旧实例并安全退出。

## 停止任务

优先使用一键卸载：

```sh
sh oalive.sh --uninstall
```

如果你是完全手动部署，可以按锁文件中的 PID 停止：

```sh
for name in cpu-limit memory-limit bandwidth; do
  lock="/tmp/oalive-$name.lock/pid"
  [ -r "$lock" ] && kill "$(sed -n '1p' "$lock")" 2>/dev/null || true
done
```

不要使用 `kill $(ps ... | grep ...)` 这类模糊匹配命令，容易误杀无关进程。
