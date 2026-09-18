# 运维

[English](operations.md) | **简体中文**

## 安装

```bash
sudo ./install.sh
```

安装程序会把程序安装到 `/usr/local/lib/ip-allowlist`，并在 `/usr/local/sbin/ip-allowlist` 创建符号链接；创建 `/etc/ip-allowlist` 及默认配置和 Cloudflare 来源；安装 systemd 单元与 logrotate 配置；并启用 `ip-allowlist.timer`。

## 命令

| 命令 | 说明 |
|---------|-------------|
| `ip-allowlist` / `sync` | 获取来源并应用允许列表 |
| `ip-allowlist check` | 获取并报告变更，但不应用 |
| `ip-allowlist apply-offline` | 使用缓存状态应用，不访问网络 |
| `ip-allowlist sources` | 列出已配置来源（`--json`） |
| `ip-allowlist status` | 显示状态（`--json`、`--check`） |
| `ip-allowlist cleanup` | 移除防火墙对象与 fail2ban drop-in |
| `ip-allowlist version` | 显示版本 |
| `ip-allowlist upgrade [--check]` | 检查/安装更新（`--check` 仅报告） |
| `ip-allowlist install` | 全系统安装 |
| `ip-allowlist uninstall [--purge]` | 卸载 |

常用参数：`--config FILE`、`--verbose`、`--quiet`、`--dry-run`、`--force`、`--json`、`--check`、`--purge`、`--yes`。

## 调度

`ip-allowlist.timer` 每 15 分钟运行一次 `ip-allowlist.service`，并在启动时（延迟 2 分钟）运行。脚本自身也会遵循按来源配置的 `update_interval`，因此定时器为 15 分钟、来源间隔为 1 小时时，实际每小时才重新获取一次。

```bash
systemctl list-timers ip-allowlist.timer
systemctl status ip-allowlist.service
journalctl -u ip-allowlist.service -f
```

启动 service 仅在 `/etc/ip-allowlist/update-on-boot` 存在时运行，该文件由安装程序根据 `update_on_boot` 创建。它执行 `sync --force`，因此开机时会获取所有来源。

## 监控

`status --check` 返回 Nagios 风格退出码：

- `0` OK
- `1` WARNING（没有启用的来源、后端未激活、运行被中断）
- `2` CRITICAL（某来源低于 `min_entries`，或没有已应用状态）

```bash
ip-allowlist status --check
ip-allowlist status --json
```

通过 `logging.format=json` 可输出 JSON 日志，便于结构化采集。

## 日志

`logging.target`：
- `auto` — 交互时输出到 stdout，非交互时写入日志文件
- `stdout` — 仅输出到 stdout/stderr（systemd journal）
- `file` — 追加到 `paths.log_file`
- `syslog` — 通过 `logger` 发送到 syslog（tag 为 `ip-allowlist`）；若 `logger` 不可用则回退到 stdout

logrotate 配置安装在 `/etc/logrotate.d/ip-allowlist`。

## 回滚与恢复

快照位于 `/var/lib/ip-allowlist/snapshots/`。若要手动回滚某来源，可将快照复制覆盖 `current/<name>.ips`，然后运行 `ip-allowlist apply-offline`。

若某次运行被中断，`in-progress` 标记会在下次运行时触发恢复流程：任何缺少 `current/` 文件的来源都会从最近的快照恢复，然后重新应用可用状态。

`ip-allowlist cleanup` 会移除所有 ip-allowlist 防火墙对象与受管的 fail2ban drop-in，而不卸载程序。它还会使已应用哈希失效，因此下次 `sync` 会重建允许列表。

## 后端

| 后端 | 对象 | 说明 |
|---------|---------|-------|
| `nft` | 一个表、按来源的区间 set、基础 `input` chain | 通过 `nft -f` 原子应用 |
| `ufw` | 每个条目一条带注释的允许规则 | 与 `ufw show added` 做差异比对；由于 ufw 每次变更都会重载，大列表会更慢 |
| `firewalld` | 每个来源/地址族一个 `hash:net` ipset + 富规则 | 先 `--permanent` 应用，再执行一次 `--reload` |

同一时间只能有一个管理器处于活跃状态。若正在运行的管理器与 `firewall_backend` 不一致，运行会报错停止。

修改 `firewall_backend` 会在新后端上触发重建，然后清理上一个后端的对象。修改 `firewall_firewalld_zone` 会清理旧 zone 的富规则，修改 `fail2ban_ignoreip_file` 会清理旧的 drop-in 文件。

## 卸载

```bash
sudo ./uninstall.sh            # 保留配置与状态
sudo ./uninstall.sh --purge    # 全部移除
```
