# 架构

[English](architecture.md) | **简体中文**

## 概述

`ip-allowlist` 从配置的来源获取 IP 段，进行规范化处理，然后应用到主机防火墙与 fail2ban。它由一组 bash 脚本构成，除 bash 4.4+、coreutils、curl/wget 以及所选防火墙后端外，没有其他运行时依赖。

## 组件结构

```
ip-allowlist            主入口与 CLI 分发
lib/
  common.sh             日志、KV 解析、路径、加锁、HTTP、哈希
  source.sh             IP 校验、规范化、合并、获取、处理
  state.sh              状态目录结构、哈希、快照、状态、标记
  fail2ban.sh           ignoreip 联合与 drop-in 管理
  firewall/
    nft.sh              nftables 后端（按来源的区间 set）
    ufw.sh              ufw 后端（带注释的允许规则，做差异比对）
    firewalld.sh        firewalld 后端（hash:net ipset + 富规则）
config/
  config.conf.example   主配置模板
sources.d/
  cloudflare.conf.example  来源模板
systemd/                定时器 + service + 启动 service
install.sh              原子暂存安装/升级
uninstall.sh            卸载（--purge 清除数据）
tests/                  单元测试 + 容器集成测试
```

## 数据流

```
sources.d/*.conf
      |
      v
 source_fetch (http/file) --- 原始文本
      |                            |
      |                            v
      |                    canonicalize_stream
      |              校验 -> 规范化 -> 去重
      |              -> 排序 -> 合并（IPv4）
      |                            |
      v                            v
 阈值检查                  state/current/<name>.ips
 (min_entries,                    |
  max_shrink_ratio)               v
                          backend_apply（nft/ufw/firewalld）
                                  |
                                  v
                          fail2ban 联合 + drop-in
```

## 状态目录结构

```
/var/lib/ip-allowlist/
  in-progress                 运行进行中的标记
  backend                     上次应用的后端名称
  firewall.firewalld-zone     上次应用的 firewalld zone（用于清理）
  fail2ban.ignoreip-file      上次应用的 drop-in 路径（用于清理）
  .lock                       flock 目标
  current/<source>.ips        当前已应用的规范化条目
  rules/<source>.conf         生效的规则参数（端口/协议/地址族）
  applied/<source>.hash       已应用条目 + 规则参数的哈希
  desired.hash                整个期望防火墙状态的指纹
  sources.known               曾应用过的来源（用于清理）
  status/<source>.last_run    上次成功获取的 Unix 时间戳
  status/<source>.stale       上次获取失败时存在（保留旧值）
  snapshots/<source>/*.ips    每个来源最近 10 个规范化快照
  snapshots/backend/          最近 5 个后端状态转储
  fail2ban/union.ips          所有来源 + 用户条目的联合结果
  fail2ban/applied.hash       联合 drop-in 内容的 SHA-256
```

## nftables 模型

使用固定的单表 `inet ip_allowlist`，每个来源包含：

- 每个地址族一个区间 set（`al_<source>_v4`、`al_<source>_v6`）
- 一个普通 chain `al_<source>`，存放放行规则
- 基础 `input` chain 中的一条 `jump al_<source>`
  （`type filter hook input priority filter; policy accept;`）

规则形如 `ip saddr @al_<source>_v4 tcp dport { 443 } accept`；当 `allow_ports=all` 时为 `ip saddr @al_<source>_v4 accept`。

整表重新生成，并通过一次 `nft -f` 原子应用，使用如下幂等写法：

```
table inet ip_allowlist {}
delete table inet ip_allowlist
table inet ip_allowlist { ... }
```

`policy accept` 意味着该表本身不会丢包。基础 chain 使用 `filter` 优先级，因此与其他管理器（如 Docker）的相对顺序不保证，详见 README。另需注意：nftables 的 `accept` 在不同表的 base chain 之间不是终结判定，主机的 default-deny 策略需要同时放行这些来源网段。采用计划命名之前版本创建的表（`inet ip-allowlist`）会被自动清理。

被禁用或从配置中删除的来源，其 `current/<name>.ips` 会被删除，从而在重新生成的表中被移除。

## ufw 模型

ufw 没有原生的分组机制，因此每个规范化条目都会安装为一条单独的允许规则，并带有 `ip-allowlist:<source>` 形式的注释。同步时会从 `ufw show added` 读回受管规则并做规范化，然后仅应用差异（`comm` 比较期望集合与当前集合）：新增条目会被添加，过期条目会被删除。被禁用的来源其 `current/<name>.ips` 会被移除，因此其规则会在下次同步时删除。

## firewalld 模型

每个来源、每个地址族会创建一个 firewalld ipset（`hash:net`），命名为 `ia-<source>-v4|v6-<hash>`，并由目标 zone（`firewalld_zone`，默认 firewalld 默认 zone）中的富规则引用：

```
rule family="ipv4" source ipset="ia-<source>-v4-<hash>" accept
```

同步会先移除 ip-allowlist 的富规则、用当前条目重建所需的 ipset、重新添加富规则、删除过期的 ipset，最后执行一次 `firewall-cmd --reload`。所有变更先以 `--permanent` 写入，运行时切换在 reload 时完成。

## 后端配置与冲突

后端是显式配置的（`firewall_backend`），不做自动探测。应用前，如果当前活跃的是其他防火墙管理器（例如 `firewall_backend=nft` 但 ufw 处于活跃状态），工具会报错终止；如果 ufw 与 firewalld 同时活跃，也会报错终止。

当配置的后端与状态中记录的后端不一致时，运行会强制重建，使新后端获得该允许列表，然后清理上一个后端遗留的对象（例如从 nft 切换到 ufw 时删除旧的 nft 表）。firewalld zone 与 fail2ban drop-in 路径也会被记录，因此变更其中任一项时，会清理旧 zone 的富规则或旧的 drop-in 文件。

仅配置变更也会被检测：`desired.hash` 会对后端、表/链/地址族、fail2ban 设置，以及每个来源的条目与规则参数取指纹。因此修改 `allow_ports`、`allow_protocol`、`enable_ipv4/6`、`firewalld_zone` 时，即使来源数据未变，下次 `sync` 也会触发重建。

## 崩溃恢复

一次运行会在处理前创建 `state/in-progress`（含起始时间），并在成功后删除。若下次运行发现残留标记，会把每个来源回滚到那次中断运行期间拍摄的快照（快照 mtime 不早于标记的起始时间），然后正常继续。按来源的快照也支持手动回滚。

## 失败处理

- 获取/校验失败的来源会被记录、标记为 stale 并跳过；其先前的 `current/` 文件会保留，从而防火墙继续可用。下次运行会立即重试。
- 收缩超过 `max_shrink_ratio` 的结果会被拒绝并保留上次值（`--force` 可绕过）。
- 任一来源失败都会使 `sync` 以非零（2）退出，便于定时器/监控感知。
- 防火墙应用后会做自检（set/ipset/规则存在且数量匹配）。自检失败时，会从运行前快照恢复各来源并重新应用上一状态；若仍失败，则从运行前拍摄的文件快照恢复 ufw/firewalld 配置目录；若依然失败，`sync` 以 2 退出。
- firewalld 会记录本次写入的确切 rich rule 字符串，便于后续精确删除（同时保留前缀扫描作为兜底）。
- fail2ban drop-in 只有在 `fail2ban-client -t` 通过后才保留，否则恢复上一份。
- `flock` 防止并发运行。

## 退出码

| 退出码 | 含义 |
|--------|------|
| 0      | 成功 / 状态 OK |
| 1      | 状态 WARNING（`status --check`） |
| 2      | 严重 / 运行失败 |
| 3      | 状态 UNKNOWN |
| 64     | 用法错误 |
| 77     | 测试被跳过（非运行时退出码） |
