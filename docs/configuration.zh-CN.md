# 配置

[English](configuration.md) | **简体中文**

## 主配置：`/etc/ip-allowlist/config.conf`

格式：严格 `key=value`，每行一项。`#` 为注释，值可加引号，**未知键会报错**。不做变量展开，也不使用 `eval`。不以 `/` 开头的路径相对于配置文件所在目录，且不允许包含空格。

### 目标开关

| 键 | 取值 | 默认 | 说明 |
|-----|--------|---------|-------------|
| `firewall_enabled` | 布尔 | `true` | 防火墙目标总开关 |
| `fail2ban_enabled` | 布尔 | `true` | fail2ban 目标总开关 |
| `firewall_backend` | `nft`\|`ufw`\|`firewalld` | 必填* | 后端（`firewall_enabled=true` 时必填） |
| `allow_conflicting_firewall` | 布尔 | `false` | 有其他管理器活跃时仍继续 |

`firewall_enabled=false` / `fail2ban_enabled=false` 表示该目标为 no-op：不下发，也**不清理**既有产物（需清理请用 `uninstall`）。

### 来源

| 键 | 取值 | 默认 | 说明 |
|-----|--------|---------|-------------|
| `sources_dir` | 路径 | `/etc/ip-allowlist/sources.d` | 来源配置目录 |
| `allow_empty_sources` | 布尔 | `false` | 活跃来源为 0 时允许清空全部 |

`sources_dir` 缺失或不可读为硬错误，且不执行任何清理。

### 默认放行规则（来源可逐项覆盖）

| 键 | 取值 | 默认 | 说明 |
|-----|--------|---------|-------------|
| `allow_ports` | `443`、`80,443`、`20000-40000`、`all` | `443` | 放行端口 |
| `allow_protocol` | `tcp`\|`udp`\|`tcp+udp` | `tcp+udp` | 协议（`allow_ports=all` 时忽略） |
| `enable_ipv4` / `enable_ipv6` | 布尔 | `true` | 地址族 |
| `ipv6_required` | 布尔 | `false` | 无 IPv6 条目时使来源失败 |
| `http_timeout` | 秒 | `15` | HTTP 连接/总超时 |
| `http_retries` | 整数 | `3` | HTTP 重试次数 |
| `user_agent` | 字符串 | `ip-allowlist` | HTTP User-Agent |
| `min_entries` | 整数 | 空 → `1` | 启用地址族的最少条目数 |
| `max_shrink_ratio` | 0..1 | `0.5` | 收缩超过该比例则拒绝本次结果 |

### 周期与自更新

| 键 | 取值 | 默认 | 说明 |
|-----|--------|---------|-------------|
| `update_interval` | 时长 | `1d` | 每个来源的默认获取周期 |
| `timer_interval` | 时长 | `15m` | systemd 定时器周期 |
| `update_on_boot` | 布尔 | `true` | 是否启用开机服务 |
| `auto_update` | 布尔 | `false` | 是否自动安装新版本 |
| `update_check_interval` | 时长 | `1d` | 检查新版本的周期 |
| `repo` | `owner/name` | `SemouSky/ip-allowlist` | `upgrade` 使用的仓库 |

时长可写裸数字（秒）或带 `s`/`m`/`h`/`d`/`w` 后缀。

### fail2ban / firewalld / 路径 / 日志

| 键 | 取值 | 默认 |
|-----|--------|---------|
| `fail2ban_ignoreip_file` | 路径 | `/etc/fail2ban/jail.d/zz-ip-allowlist.local` |
| `fail2ban_merge_existing` | 布尔 | `true` |
| `firewalld_zone` | zone 名 | firewalld 默认 |
| `state_dir` | 路径 | `/var/lib/ip-allowlist` |
| `snapshot_retention` | 整数 | `3` |
| `lock_file` | 路径 | `/run/ip-allowlist.lock` |
| `lock_wait` | 秒 | `30` |
| `log_level` | `debug`\|`info`\|`warn`\|`error` | `info` |
| `log_target` | `auto`\|`stdout`\|`file`\|`syslog`\|`none` 的逗号列表 | `auto` |
| `log_file` | 路径 | 空（`log_target` 含 `file` 时必填） |
| `log_format` | `text`\|`json` | `text` |
| `schema_version` | 整数 | `1` |

## 来源配置：`sources.d/*.conf`

| 键 | 取值 | 默认 |
|-----|--------|---------|
| `name` | `^[a-z][a-z0-9_-]{0,15}$`，全局唯一 | 必填 |
| `enabled` | 布尔 | `true` |
| `type` | `http`\|`file` | 必填 |
| `urls` | 以空格/逗号分隔的 URL | `http` 必填 |
| `paths` | 以空格分隔的路径 | `file` 必填 |
| `format` | `text`（v1 唯一取值） | `text` |
| `firewall_enabled` / `fail2ban_enabled` | 布尔 | 继承主配置 |
| `enable_ipv4` / `enable_ipv6` / `ipv6_required` | 布尔 | 继承 |
| `allow_ports` / `allow_protocol` | 同上 | 继承 |
| `update_interval` | 时长 | 继承 |
| `http_timeout` / `http_retries` / `user_agent` | 同上 | 继承 |
| `min_entries` / `max_shrink_ratio` | 同上 | 继承 |

来源文件中的未知键会报错；`urls` 与 `paths` 互斥。

## 规则参数语义

- `allow_ports=all` 放行所有端口，并**忽略** `allow_protocol`。
- 指定端口列表时，若 `allow_protocol` 保持默认，则同时使用 TCP 与 UDP。
- `enable_ipv4`/`enable_ipv6` 仅影响防火墙；fail2ban 仍使用完整并集。

各后端渲染（`allow_ports=443`、`allow_protocol=tcp`）：

- nft：`ip saddr @set tcp dport { 443 } accept`
- ufw：`allow from <cidr> to any port 443 proto tcp`
- firewalld：`rule ... source ipset="..." port port="443" protocol="tcp" accept`

## 优先级

CLI 参数 > 来源配置 > 主配置 > 内置默认。
