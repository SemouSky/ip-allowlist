# 开发

[English](development.md) | **简体中文**

## 环境要求

- bash 4.4+，用于运行和单元测试
- shellcheck，用于 lint
- podman 或 docker，用于集成测试
- GNU coreutils

## 结构与约定

- 所有逻辑位于 `lib/`；`ip-allowlist` 入口只负责 CLI、配置与分发。
- 使用 `set -uo pipefail`，但不使用 `set -e`；错误显式处理，以便部分失败也能被记录并清晰上报。
- 不使用 `eval`。配置由严格的 `key=value` 读取器解析。
- 优先使用赋值式算术（`x=$((x+1))`），而非 `((x++))`，以避免返回非零。
- 函数命名为 `lower_snake_case`；全局变量为 `UPPER_SNAKE_CASE`。
- 变量加引号；条件判断使用 `[[ ]]`。

## 运行测试

```bash
make test          # lint + 集成测试（可用时使用容器）
make lint          # shellcheck + bash -n
make unit          # 主机单元测试（需要 bash 4.4+）
make integration   # 容器集成测试
make integration DISTRO=ubuntu-22.04
```

`tests/run.sh` 会优先探测 podman，其次 docker，并可用 `--local` 直接在容器内运行测试（CI 使用该方式）。

若主机缺少 bash 4.4+，单元测试会在主机上被跳过（退出码 77），应在容器中运行。

## 测试结构

- `tests/unit.sh` — 纯函数测试：IPv4/IPv6 校验、规范化、合并、规范化处理、fail2ban 规范化、配置解析、路径与 JSON 辅助函数、到期间隔逻辑。
- `tests/integration/run.sh` — 容器内端到端测试：真实 `nft` 表、幂等性、变更检测、非法条目过滤、`min_entries`、禁用与移除来源、status/sources 输出、fail2ban 联合与 drop-in 移除。
- `tests/integration/ufw.sh` — 容器内 ufw 后端测试。
- `tests/integration/firewalld.sh` — 容器内 firewalld 后端测试（需要 dbus）。
- `tests/docker/<distro>/Dockerfile` — 各发行版镜像。

## 新增防火墙后端

1. 创建 `lib/firewall/<backend>.sh`。
2. 实现 `backend_validate`、`apply`、`snapshot`、`cleanup`、`status` 对应函数（形态参考 `nft.sh`）。
3. 在入口脚本的 `load_backend`、`backend_validate`、`backend_apply`、`backend_snapshot`、`backend_cleanup`、`backend_status` 中接入。
4. 如有需要，在 `firewall_check_conflicts` 中添加冲突检测。
5. 添加测试。

## 新增来源类型

1. 在 `lib/source.sh` 中扩展 `source_load_config` 的校验。
2. 在 `source_fetch` 中添加分支。
3. 更新 `docs/sources.md` 与测试。

## 发布

发布通过 release-please（`simple` 类型）自动化：

1. 将变更合并到 `main`。
2. release-please 会创建一个 release PR，更新 `version.txt` 与 `CHANGELOG.md`。
3. 合并该 PR 会打 tag，并发布带源码压缩包的 GitHub Release。
4. `ip-allowlist upgrade` 会下载最新的 release 压缩包。
