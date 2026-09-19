# 来源

[English](sources.md) | **简体中文**

来源（source）是一个具名的 IP 段提供方。每个来源在防火墙中作为独立的对象/set 应用，从而保持来源之间相互独立；所有来源会汇总后用于 fail2ban。

## Cloudflare

默认来源使用 Cloudflare 公布的 IP 段：

```ini
enabled=true
name=cloudflare
type=http
urls=https://www.cloudflare.com/ips-v4,https://www.cloudflare.com/ips-v6
min_entries=5
max_shrink_ratio=0.5
```

## HTTP 来源

`type=http` 会获取 `urls` 中的每个 URL（逗号分隔）并拼接响应内容。内容按以空白/逗号分隔的 token 流解析；任何合法的 IPv4/IPv6 地址或 CIDR 都会被保留，其余内容忽略。因此纯文本的逐行列表和简单 JSON 数组都可以在不需要 JSON 解析器的情况下工作。

获取优先使用 `curl`，否则使用 `wget`，并带有：
- 连接超时 30 秒，总超时 90 秒
- 最多重试 3 次
- 10 MiB 下载上限
- User-Agent 为 `ip-allowlist/<version>`

仅接受 `http://` 与 `https://` URL。

## File 来源

`type=file` 读取本地文件，适用于隔离网络的主机或测试：

```ini
enabled=true
name=internal
type=file
paths=/etc/ip-allowlist/internal-ranges.txt
min_entries=1
```

相对的 `paths` 会相对于主配置目录解析。

## 目标开关

每个来源可用 `firewall_enabled` / `fail2ban_enabled` 选择性地退出某个目标；它们与主开关是逻辑与，省略即继承主配置的值：

```ini
firewall_enabled=false   # 该来源不进入防火墙
fail2ban_enabled=true    # 但仍参与 ignoreip 并集
```

被排除在防火墙之外的来源会在下次同步时移除其对象，但条目仍保留在缓存中以供 fail2ban 使用；被排除在 fail2ban 之外的来源仍可下发到防火墙。完整对照见[配置](configuration.zh-CN.md#目标开关的作用逻辑)。

## 规则参数

来源可以覆盖主配置的放行规则参数：

```ini
allow_ports=443
allow_protocol=tcp+udp
enable_ipv4=true
enable_ipv6=false
```

默认是 `any`，即允许来源地址访问所有端口与协议。各选项语义见[配置](configuration.zh-CN.md#规则参数)。

## 规范化

所有来源都经过同一条流水线：

1. 按空白和逗号切分 token。
2. 校验每个 token 是否为 IPv4/IPv6 地址或 CIDR。
3. 规范化：IPv4 取网络地址，IPv6 取规范压缩形式；裸地址变为 `/32` 或 `/128`。
4. 去重。
5. 排序（IPv4 按数值，IPv6 按展开后的十六进制）。
6. 将重叠/相邻的 IPv4 区间合并为最小 CIDR 集合。

非法 token 会被丢弃并记录 debug 日志。若某来源在规范化后没有任何条目，`min_entries`（默认 1）会使该来源失败。

## 安全阈值

- `min_entries`：规范化条目数低于该值时硬失败。
- `max_shrink_ratio`：相对上次应用的条目数，收缩比例超过该值时告警。

这些阈值用于防止上游故障、响应被截断，或用意外空文件替换掉可用的允许列表。

## 模板

`sources.d/example.conf.example` 是完整注释模板，涵盖 `http` 与 `file` 两种类型：复制为 `/etc/ip-allowlist/sources.d/<name>.conf` 后修改即可。`sources.d/cloudflare.conf.example` 是现成的 Cloudflare 来源（默认禁用）。

## 添加来源

1. 创建 `/etc/ip-allowlist/sources.d/<name>.conf`。
2. 设置唯一的 `name` 与合适的 `type`。
3. 使用 `ip-allowlist check` 校验（不会应用变更）。
4. 使用 `ip-allowlist sync` 应用。

新增 HTTP/file 来源无需修改代码。
