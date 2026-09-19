# ip-allowlist

[English](README.md) | **简体中文**

[![CI](https://github.com/SemouSky/ip-allowlist/actions/workflows/ci.yml/badge.svg)](https://github.com/SemouSky/ip-allowlist/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一个 Linux Shell 脚本，用于定期获取 Cloudflare 等来源的 IP 段（IPv4/IPv6），并应用到防火墙允许列表（nftables、ufw、firewalld）以及 fail2ban 的 ignoreip。

## 功能特性

- **多来源支持**：从多个 HTTP/file 来源获取 IP 段
- **多后端**：nftables（按来源划分 set）、ufw（带注释的规则）、firewalld（ipset + 富规则）
- **fail2ban 集成**：自动汇总所有来源并生成 ignoreip drop-in
- **来源隔离**：每个来源维护各自独立的防火墙对象
- **systemd 定时器**：默认每 15 分钟自动更新
- **崩溃恢复**：快照回滚与运行中标记
- **原子操作**：暂存变更后原子重命名
- **安全优先**：不使用 eval、严格输入校验、安全的临时文件

## 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/SemouSky/ip-allowlist/main/install.sh | sudo bash
```

或手动安装：

```bash
git clone https://github.com/SemouSky/ip-allowlist.git
cd ip-allowlist
sudo ./install.sh
```

## 配置

主配置：`/etc/ip-allowlist/config.conf`
来源配置：`/etc/ip-allowlist/sources.d/*.conf`

Cloudflare 来源示例（`/etc/ip-allowlist/sources.d/cloudflare.conf`）：

```ini
enabled=true
name=cloudflare
type=http
urls=https://www.cloudflare.com/ips-v4,https://www.cloudflare.com/ips-v6
min_entries=5
max_shrink_ratio=0.5
update_interval=3600
```

## 命令

```bash
ip-allowlist                 # 同步所有来源（默认命令，别名 run）
ip-allowlist sync            # 显式同步
ip-allowlist --source NAME   # 将 sync/check/status 限定到某来源（可重复）
ip-allowlist --allow-empty   # 活跃来源为 0 时允许清空全部
ip-allowlist check           # 校验并报告变更，不应用
ip-allowlist check --offline # 仅校验配置，不访问网络
ip-allowlist apply-offline   # 使用缓存状态应用，不访问网络
ip-allowlist sources         # 列出已配置来源（--json）
ip-allowlist status          # 显示状态（--json，--check 为 Nagios 格式）
ip-allowlist cleanup         # 移除防火墙对象与 fail2ban drop-in
ip-allowlist version         # 显示版本
ip-allowlist upgrade         # 检查/安装更新
ip-allowlist upgrade --version 0.3.0 --from-dir DIR  # 离线/指定版本安装
ip-allowlist install         # 全系统安装
ip-allowlist uninstall       # 卸载（--purge 同时清除数据）
```

`allow_ports` 默认 `443`、`allow_protocol` 默认 `tcp+udp`；设为 `allow_ports=all` 可放行来源地址的所有端口。

## 防火墙注意事项

- nft 表使用 `policy accept`，只添加放行规则，不修改基础策略或其他规则。若主机启用 default-deny，需要在其自身策略中同时放行这些来源网段。
- 在 nftables 中，`accept` 判定在不同表的 base chain 之间**不是终结**，因此独立的 default-deny 链仍可能丢弃已被放行的流量。
- Docker 可能绕过 ufw/firewalld，详见各后端文档。

## 系统要求

- Linux，bash 4.4+
- coreutils、curl/wget、tar、gzip
- 以下之一：nftables、ufw、firewalld
- fail2ban（可选，用于 ignoreip 集成）
- systemd（用于定时器）

## 文档

- [架构](docs/architecture.zh-CN.md)
- [配置](docs/configuration.zh-CN.md)
- [来源](docs/sources.zh-CN.md)
- [运维](docs/operations.zh-CN.md)
- [开发](docs/development.zh-CN.md)
- [安全](docs/security.zh-CN.md)

## 许可证

MIT License，详见 [LICENSE](LICENSE)。
