# 安全策略

[English](SECURITY.md) | **简体中文**

## 支持的版本

| 版本   | 是否支持            |
| ------ | ------------------ |
| 1.x.x  | :white_check_mark: |
| < 1.0  | :x:                |

## 报告漏洞

请通过 [GitHub Security Advisories](https://github.com/SemouSky/ip-allowlist/security/advisories/new) 私下报告安全漏洞。

请勿为安全漏洞创建公开 issue。

## 威胁模型

### 保护的资产
- 防火墙规则完整性（允许列表正确性）
- 系统可用性（避免误锁死）
- 配置机密性（不泄露秘密）
- fail2ban ignoreip 完整性

### 威胁主体
- **网络攻击者**：伪造 IP 段、恶意来源内容
- **本地攻击者**：被篡改的来源文件、配置篡改
- **供应链**：恶意发布、被污染的依赖

### 攻击面与缓解措施

| 攻击面 | 缓解措施 |
|--------|----------|
| 来源中的恶意 IP 段 | `min_entries`、`max_shrink_ratio` 校验；按来源做规范化 |
| 配置注入 | 严格的 key=value 解析器（无 eval）；输入校验 |
| 路径穿越 | 绝对路径解析；路径不允许空格 |
| 临时文件竞争 | `mktemp` 安全权限；原子重命名 |
| 权限提升 | 仅在防火墙/fail2ban 操作时以 root 运行；最小能力集 |
| 回滚失败 | 应用前快照；运行中标记用于崩溃恢复 |
| 供应链 | release-please 自动化；签名发布；可校验的安装脚本 |

### 信任边界

```
互联网（不可信）→ HTTP 获取 → 校验 → 防火墙（可信）
                                   ↓
                          fail2ban drop-in（可信）
```

- 网络来源：不可信，使用前必须校验
- 本地文件来源：若配置可信则可信
- 配置文件：可信（root 所有，0640）
- 状态目录：可信（root 所有，0700）

## 安全实践

### 输入校验
- 所有 IP 均校验为合法 CIDR（IPv4/IPv6）
- CIDR 规范化（合并重叠、排序）
- 来源 `min_entries` 防止空允许列表
- 来源 `max_shrink_ratio` 在数量骤降时告警

### 安全操作
- 不使用 `eval`，不动态执行代码
- 所有临时文件使用 `mktemp`
- 使用 `flock` 对配置/状态加锁
- 所有写入使用原子 `mv`
- 固定 User-Agent：`ip-allowlist/<version>`

### 最小权限
- 脚本以 root 运行（防火墙操作所需）
- 配置/状态：root:root，0640/0700
- 日志文件：root:root，0640
- systemd：`ProtectSystem=strict`，限制 `ReadWritePaths`

### 审计追踪
- 结构化日志（可选 JSON）
- 每次执行都有 run ID
- 带时间戳的状态快照
- 所有防火墙变更均记录日志

## 加固建议

1. **限制配置访问**：`chmod 640 /etc/ip-allowlist/config.conf`
2. **监控日志**：对 `ERROR` 级别或收缩比例告警
3. **固定版本**：使用具体 release 压缩包，而非 `main` 分支
4. **校验下载**：可用时校验 release 签名
5. **先测试再应用**：`sync` 前先用 `ip-allowlist check`

## 已知限制

- HTTP 来源未做 TLS 证书固定
- 未对来源内容做 GPG 校验
- 单一 User-Agent（可被指纹识别）
- 防火墙操作需要 root

## 后续改进

- [ ] HTTP 来源证书固定
- [ ] GPG 签名的来源校验
- [ ] 基于 capability 的沙箱
- [ ] SELinux/AppArmor 策略
