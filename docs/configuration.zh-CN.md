# 配置

[English](configuration.md) | **简体中文**

## 主配置：`/etc/ip-allowlist/config.conf`

格式：严格 `key=value`，每行一项。`#` 为注释（也可写在值之后），值可加引号，**未知键会报错**。若值内需要字面 `#`，请加引号（例如 `urls="https://example/#/list"`）。不做变量展开，也不使用 `eval`。不以 `/` 开头的路径相对于配置文件所在目录，且不允许包含空格。

### 目标开关

| 键 | 取值 | 默认 | 说明 |
|-----|--------|---------|-------------|
| `firewall_enabled` | 布尔 | `true` | 防火墙目标总开关 |
| `fail2ban_enabled` | 布尔 | `false` | fail2ban 目标总开关 |
| `firewall_backend` | `nft`\|`ufw`\|`firewalld` | 必填* | 后端（`firewall_enabled=true` 时必填）；安装器会优先选择正在运行的 ufw/firewalld，其次是已启用的，否则 nft（若所选后端未在运行会给出告警） |
| `allow_conflicting_firewall` | 布尔 | `false` | 有其他管理器活跃时仍继续 |

### 目标开关的作用逻辑

`firewall_enabled` 与 `fail2ban_enabled` 是**总开关**，二者本身都不会清理任何产物：

| 主开关 | 作用 |
|---|---|
| `firewall_enabled=true` | 将允许列表下发到 `firewall_backend`。只有 `enabled=true` **且** 来源级 `firewall_enabled=true` 的来源会被下发。 |
| `firewall_enabled=false` | 防火墙目标为 no-op：不下发，且**保留**既有 ip-allowlist 防火墙对象。如需清理用 `ip-allowlist cleanup`（或 `uninstall`）。此时 `firewall_backend` 可省略。 |
| `fail2ban_enabled=true` | 用“来源级 `fail2ban_enabled=true` 的来源并集”管理 `fail2ban_ignoreip_file` 中的 `[DEFAULT] ignoreip`；当 `fail2ban_merge_existing=true` 时并入用户自身的 `ignoreip`。 |
| `fail2ban_enabled=false` | fail2ban 目标为 no-op：**保留**既有 drop-in。如需清理用 `ip-allowlist cleanup`。 |

来源级开关与主开关是**逻辑与**，且来源省略该键时**继承主配置的值**：

- 来源 `firewall_enabled=false`：该来源被排除在防火墙之外（若之前已应用则移除其对象），但其条目仍会被获取与缓存，供 fail2ban 并集使用。
- 来源 `fail2ban_enabled=false`：该来源被排除在 ignoreip 并集之外，但仍可下发到防火墙。
- 两个开关都参与来源的有效哈希，改动后下次 `sync` 会重建该来源。

若两个目标都被关闭，或所选后端工具缺失/未运行且 fail2ban 不可用，`sync` 为 no-op 并以 0 退出。

### 来源

| 键 | 取值 | 默认 | 说明 |
|-----|--------|---------|-------------|
| `sources_dir` | 路径 | `/etc/ip-allowlist/sources.d` | 来源配置目录 |
| `allow_empty_sources` | 布尔 | `false` | 活跃来源为 0 时允许清空全部 |

`sources_dir` 缺失或不可读为硬错误，且不执行任何清理。

### 默认放行规则（来源可逐项覆盖）

| 键 | 取值 | 默认 | 说明 |
|-----|--------|---------|-------------|
| `allow_ports` | `443`、`80,443`、`20000-40000`、`all` | `80,443` | 放行端口 |
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

## 日志目标

`log_target` 选择一个或多个目标（逗号分隔）：

- `auto` — 仅输出到 stdout/stderr。在 systemd 下即服务日志（`journalctl -u ip-allowlist.service -f`）；在终端交互运行时即终端。**`auto` 不写文件。**
- `stdout` — 与 `auto` 相同的目标，显式写法。
- `file` — 追加到 `log_file`（必填）；同时使用随包 logrotate 配置。
- `syslog` — 通过 `logger` 发送到 syslog（tag `ip-allowlist`）。
- `none` — 不输出日志。

可组合以同时输出，例如 `log_target=stdout,file` 会同时写 journal/终端与日志文件。

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
