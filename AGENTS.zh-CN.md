# Agent 说明

[English](AGENTS.md) | **简体中文**

本文件为参与 ip-allowlist 项目的 AI agent 提供指导。

## 项目概述

ip-allowlist 是一个 Linux Shell 脚本，用于从 Cloudflare 及其他 IP 来源管理防火墙允许列表。支持 nftables、ufw、firewalld 后端，并集成 fail2ban。

## 架构

- **入口点**：`ip-allowlist`（主脚本）
- **库**：`lib/` 目录，模块化组件
  - `common.sh` - 公共工具（日志、HTTP 获取、加锁、解析）
  - `source.sh` - 来源获取/解析/校验/规范化
  - `state.sh` - 状态管理（快照、哈希、运行中标记）
  - `fail2ban.sh` - fail2ban ignoreip 联合 drop-in 管理
  - `firewall/nft.sh` - nftables 后端（按来源的区间 set）
  - `firewall/ufw.sh` - ufw 后端（带注释的允许规则，同步时做差异比对）
  - `firewall/firewalld.sh` - firewalld 后端（hash:net ipset + 富规则）
- **配置**：`/etc/ip-allowlist/config.conf` + `sources.d/*.conf`
- **systemd**：定时器（15 分钟）+ service + 可选的启动 service
- **安装**：`install.sh`，采用原子暂存；卸载已内置到 CLI（`ip-allowlist uninstall`）

## 关键设计原则

1. **不使用 eval** - 仅使用严格的 key=value 解析器
2. **无额外依赖** - 仅需 bash 4.4+、coreutils、curl/wget
3. **原子操作** - 暂存变更，原子重命名
4. **崩溃恢复** - 快照回滚，运行中标记
5. **显式配置** - 不自动探测防火墙后端
6. **来源隔离** - 每个来源使用独立的 set/chain
7. **安全优先** - 输入校验、安全临时文件、固定 User-Agent

## 测试

- `make test` 运行 lint + 单元测试 + 集成测试（另有 `test-unit`、`test-integration`、`test-images`、`hooks`）
- 集成测试使用 Docker/podman 与各发行版镜像
- 测试运行器：`tests/run.sh`（自动探测 podman→docker）
- 单元测试使用 Bats（如果可用），集成测试为自定义实现

## 配置结构

主配置（`config.conf`）：
- `schema_version` - 配置版本，用于迁移
- `firewall_enabled` - true|false（默认：true）
- `fail2ban_enabled` - true|false（默认：true）
- `firewall_backend` - nft|ufw|firewalld（`firewall_enabled=true` 时必填）
- `allow_conflicting_firewall` - true|false（默认：false）
- `sources_dir` - 来源目录（默认：/etc/ip-allowlist/sources.d）
- `allow_empty_sources` - true|false（默认：false）
- `allow_ports` - 443 | 80,443 | 20000-40000 | all（默认：443）
- `allow_protocol` - tcp|udp|tcp+udp（默认：tcp+udp；`allow_ports=all` 时忽略）
- `enable_ipv4` / `enable_ipv6` - true|false（默认：true）
- `ipv6_required` - true|false（默认：false）
- `http_timeout` - 秒（默认：15）
- `http_retries` - 整数（默认：3）
- `user_agent` - HTTP User-Agent（默认：ip-allowlist）
- `min_entries` - 最少条目，空 -> 1
- `max_shrink_ratio` - 0..1（默认：0.5）
- `update_interval` - 时长（默认：1d）
- `timer_interval` - 时长（默认：15m）
- `update_on_boot` - true|false（默认：true）
- `auto_update` - true|false（默认：false）
- `update_check_interval` - 时长（默认：1d）
- `repo` - owner/name（默认：SemouSky/ip-allowlist）
- `fail2ban_ignoreip_file` - drop-in 路径（默认：/etc/fail2ban/jail.d/zz-ip-allowlist.local）
- `fail2ban_merge_existing` - true|false（默认：true）
- `firewalld_zone` - zone 名（默认：firewalld 默认）
- `state_dir` - 状态目录（默认：/var/lib/ip-allowlist）
- `snapshot_retention` - 整数（默认：3）
- `lock_file` - 锁路径（默认：/run/ip-allowlist.lock）
- `lock_wait` - 秒（默认：30）
- `log_level` - debug|info|warn|error（默认：info）
- `log_target` - auto|stdout|file|syslog|none，逗号分隔（默认：auto）
- `log_file` - `log_target` 含 file 时必填（默认：空）
- `log_format` - text|json（默认：text）

来源配置（`sources.d/*.conf`）：
- `name` - ^[a-z][a-z0-9_-]{0,15}$，全局唯一（必填）
- `enabled` - true|false（默认：true）
- `type` - http|file（必填）
- `urls` - 以空格/逗号分隔的 URL（http 类型）
- `paths` - 以空格分隔的路径（file 类型）
- `format` - text（v1 唯一取值）
- `firewall_enabled` / `fail2ban_enabled` - 继承
- `enable_ipv4` / `enable_ipv6` / `ipv6_required` - 继承
- `allow_ports` / `allow_protocol` - 继承
- `update_interval` - 继承（时长）
- `http_timeout` / `http_retries` / `user_agent` - 继承
- `min_entries` / `max_shrink_ratio` - 继承


## 开发流程

1. 修改库文件
2. 运行 `make lint` 检查语法
3. 运行 `make unit` 执行单元测试
4. 运行 `make integration` 执行集成测试
5. 提交前所有测试必须通过

## 常见任务

### 新增防火墙后端
1. 创建 `lib/firewall/<backend>.sh`
2. 实现所需函数（接口参考 nft.sh）
3. 更新主脚本以加载该后端
4. 添加测试

### 新增来源类型
1. 扩展 `lib/source.sh` 的解析函数
2. 在 `source_fetch()` 中添加获取逻辑
3. 添加校验
4. 更新文档

### 调试
- 在配置或环境变量中设置 `LOG_LEVEL=debug`
- 查看状态：`ip-allowlist status`
- 查看日志：`journalctl -u ip-allowlist -f`

## 文件路径

配置中的所有路径若为相对路径，则相对于配置文件所在目录，否则为绝对路径。
路径值不允许包含空格。

## 版本管理

版本记录在 `version.txt`，由 release-please（simple 类型）管理。
CHANGELOG.md 自动更新。
