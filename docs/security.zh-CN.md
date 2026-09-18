# 安全

[English](security.md) | **简体中文**

顶层 [SECURITY.md](../SECURITY.md) 说明了漏洞报告与威胁模型。本文档详述实现层面的控制措施。

## 输入处理

- **任何地方都不使用 `eval`。** 配置由严格的读取器解析，只接受 `key=value` 行，绝不把值当作 shell 代码展开。
- **Token 校验。** 每个候选地址在使用前都会校验：
  - IPv4 各段必须在 0–255 之间，且不允许前导零。
  - IPv4 前缀必须在 0–32；IPv6 前缀必须在 0–128。
  - IPv6 地址会被完整展开后再压缩，因此非法形式（多个 `::`、组数过多、非法十六进制）都会被拒绝。
- **按 token 解析而非语法解析。** 响应被视为不可信的 token 流。非 IP token 会被丢弃；控制字符或 shell 元字符不会进入命令行。
- **URL scheme 白名单。** 仅接受 `http://` 与 `https://` 来源。
- **后端名白名单。** `firewall_backend` 必须是 `nft|ufw|firewalld` 之一；该值绝不会直接用于拼接路径。

## 文件与路径安全

- 配置中的路径值不允许包含空白字符。
- 相对路径相对于配置目录解析；绝对路径按原样使用。
- 临时文件使用 `mktemp` 创建（权限 0600），并通过退出 trap 注册清理。
- 所有写入先暂存到目标目录下的临时文件，再用原子 `rename` 安装，因此读取方不会看到不完整内容。
- `flock` 串行化运行，防止并发修改状态。

## 资源限制

- 每个 URL 的下载上限为 10 MiB（`curl --max-filesize`）。
- 连接超时、总超时与有限重试。
- 加锁超时，避免无限等待。

## 权限与暴露面

- 脚本必须以 root 运行，才能执行防火墙与 fail2ban 操作。
- `install.sh` 设置：
  - 配置 `0640` root:root
  - 状态目录 `0700` root:root
  - 日志文件由 logrotate 创建为 `0640` root:root
- systemd 单元使用 `ProtectSystem=strict`、`ProtectHome=true`、`PrivateTmp=true`、`NoNewPrivileges=true`，以及最小能力集（`CAP_NET_ADMIN`、`CAP_DAC_OVERRIDE`）；`ReadWritePaths` 仅限状态目录、日志文件与 `/etc/fail2ban`。

## fail2ban

- 受管的 drop-in 仅包含一行位于 `[DEFAULT]` 下的 `ignoreip`，内容是来源条目与用户条目的规范化联合。
- 收集用户 `ignoreip` 值时，drop-in 自身会通过 `readlink -f` 解析并排除，因此重复运行是幂等的，也不会自我放大。
- 当联合为空时，会移除 drop-in，而不是留下空的 `ignoreip`。

## 日志

- 日志绝不包含获取到的内容，只包含数量与来源名。
- JSON 输出会转义控制字符，保证记录格式正确。
- `run_id` 关联同一次执行的所有记录。

## 残余风险

- 未做 TLS 证书固定；HTTPS 校验依赖系统信任库。
- 未对获取到的 IP 段做签名校验；信任来源于来源 URL 以及 `min_entries`/`max_shrink_ratio` 防护。
- 防火墙基础 chain 以优先级 `-1` 接受匹配流量，早于其他 filter chain；这是有意为之，且范围限定在已配置的 set 内。
