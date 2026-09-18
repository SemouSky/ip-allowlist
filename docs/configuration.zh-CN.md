# 配置

[English](configuration.md) | **简体中文**

## 主配置：`/etc/ip-allowlist/config.conf`

格式：严格的 `key=value`，每行一项。`#` 表示注释。值可选加引号。不做变量展开，也不使用 `eval`。

| 键 | 取值 | 默认值 | 说明 |
|-----|--------|---------|-------------|
| `schema_version` | 整数 | `1` | 配置结构版本 |
| `firewall_backend` | `nft`\|`ufw`\|`firewalld` | 必填 | 使用的后端（不自动探测） |
| `firewall_chain_name` | 标识符 | `ip-allowlist` | nft 表名 / 基础 chain 前缀 |
| `firewall_table_family` | `inet`\|`ip`\|`ip6` | `inet` | nft 表 family |
| `firewall_firewalld_zone` | zone 名 | firewalld 默认 | firewalld 后端的目标 zone |
| `allow_ports` | `any` 或端口列表 | `any` | 允许来源地址访问的端口 |
| `allow_protocol` | `any`\|`tcp`\|`udp`\|`tcp+udp` | `any` | 允许来源地址使用的协议 |
| `enable_ipv4` | 布尔 | `true` | 是否应用 IPv4 条目 |
| `enable_ipv6` | 布尔 | `true` | 是否应用 IPv6 条目 |
| `fail2ban_enabled` | 布尔 | `true` | 是否管理 ignoreip drop-in |
| `fail2ban_ignoreip_file` | 路径 | `/etc/fail2ban/ip-allowlist.conf` | 要管理的 drop-in |
| `paths.state_dir` | 路径 | `/var/lib/ip-allowlist` | 状态目录 |
| `paths.sources_dir` | 路径 | `/etc/ip-allowlist/sources.d` | 来源配置目录 |
| `paths.log_file` | 路径 | `/var/log/ip-allowlist.log` | 日志文件（file 目标） |
| `logging.level` | `debug`\|`info`\|`warn`\|`error` | `info` | 最低日志级别 |
| `logging.target` | `auto`\|`stdout`\|`file`\|`syslog` | `auto` | 日志输出目标 |
| `logging.format` | `text`\|`json` | `text` | 日志记录格式 |
| `update_interval` | 秒 | `900` | 每个来源的默认最小间隔 |
| `update_on_boot` | 布尔 | `true` | 是否启用开机 oneshot service |

路径可以是绝对路径，也可以是相对于 `config.conf` 所在目录的相对路径。路径值不允许包含空格。

## 结构版本（schema_version）

`schema_version` 表示该配置文件所对应的配置结构版本。当前支持的版本为 `1`。

- 缺少 `schema_version` 时按当前版本处理。
- 低于当前版本时进入迁移流程（目前尚未定义任何迁移，该处用于将来添加）。
- 高于当前版本时报错拒绝，避免旧版本程序误读新版本配置。

## 布尔值

真值：`true`、`1`、`yes`、`on`。
假值：`false`、`0`、`no`、`off`。

## 来源配置：`sources.d/*.conf`

每个来源一个文件。`name` 键是状态与防火墙对象的标识，必须唯一，且匹配 `[A-Za-z0-9_-]+`。

| 键 | 取值 | 默认值 | 说明 |
|-----|--------|---------|-------------|
| `enabled` | 布尔 | `true` | 来源是否启用 |
| `name` | 标识符 | 必填 | 唯一来源名 |
| `type` | `http`\|`file` | 必填 | 来源类型 |
| `urls` | 逗号分隔的 URL | — | `type=http` 时必填 |
| `file_path` | 路径 | — | `type=file` 时必填 |
| `min_entries` | 整数 | `1` | 规范化条目少于该值时失败 |
| `max_shrink_ratio` | 0..1 | `0.5` | 条目收缩超过该比例时告警 |
| `update_interval` | 秒 | 全局值 | 按来源覆盖 |
| `allow_ports` | `any` 或端口列表 | 全局值 | 覆盖主配置 `allow_ports` |
| `allow_protocol` | `any`\|`tcp`\|`udp`\|`tcp+udp` | 全局值 | 覆盖主配置 `allow_protocol` |
| `enable_ipv4` | 布尔 | 全局值 | 覆盖主配置 `enable_ipv4` |
| `enable_ipv6` | 布尔 | 全局值 | 覆盖主配置 `enable_ipv6` |

对于 `type=file`，相对的 `file_path` 会相对于配置目录解析。对于 `type=http`，仅接受 `http://` 与 `https://` URL。

### 禁用与删除的区别

- 设置 `enabled=false` 会在下次运行时把该来源从防火墙/fail2ban 中移除，但保留其配置文件和状态历史。
- 删除配置文件会在下次运行时移除该来源及其残留状态。

## 规则参数

`allow_ports`、`allow_protocol`、`enable_ipv4`、`enable_ipv6` 控制某来源可访问什么。优先级：来源配置 > 主配置 > 内置默认。

- `allow_ports=any`（默认）表示允许来源地址访问所有端口。写成列表（`443`、`443,8443`、`8000-8080`）可收窄到指定端口。指定端口时默认同时使用 TCP 与 UDP，除非 `allow_protocol` 另有说明。
- `allow_protocol=any`（默认）在 `allow_ports=any` 时表示匹配所有协议。`tcp`、`udp`、`tcp+udp` 可限制匹配；当指定端口且协议为 `any` 时，会同时生成 TCP 与 UDP。
- `enable_ipv4` / `enable_ipv6` 会把该地址族从防火墙中排除（fail2ban 仍然使用完整并集）。

各后端渲染：

- nft：全放行时为 `ip saddr @set accept`；否则 `ip saddr @set meta l4proto tcp accept` 或 `ip saddr @set tcp dport { 443 } accept`。
- ufw：`allow from <cidr>`、`allow from <cidr> proto tcp`，或 `allow from <cidr> to any port 443 proto tcp`。
- firewalld：`rule ... source ipset="..." accept`、`... protocol value="tcp" accept`，或 `... port port="443" protocol="tcp" accept`。

## 校验

配置非法时启动会以明确信息失败。来源文件缺少 `name`/`type`、`type` 未知、缺少 `urls`/`file_path`，或数值越界，都会被拒绝。`max_shrink_ratio` 必须在 0 到 1（含）之间。

## 示例

```ini
firewall_backend=nft
firewall_table_family=inet
fail2ban_enabled=true
logging.level=info
update_interval=900
update_on_boot=true
```
