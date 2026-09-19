# 为 ip-allowlist 贡献代码

[English](CONTRIBUTING.md) | **简体中文**

感谢你有兴趣为本项目做出贡献！

## 行为准则

本项目遵循通用的行为准则。请保持尊重与建设性。

## 开发环境搭建

```bash
git clone https://github.com/SemouSky/ip-allowlist.git
cd ip-allowlist
make test
```

## 测试

运行全部测试：
```bash
make test              # lint + 单元 + 集成
```

其他目标：
```bash
make test-unit         # 仅单元测试
make test-integration  # 容器集成测试
make test-integration DISTRO=ubuntu-22.04
make test-images       # 预构建各发行版测试镜像
make lint
make hooks             # 安装 pre-commit 钩子（make lint test-unit）
```

## 代码风格

- Shell 脚本：遵循 [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- 使用 shellcheck（v0.8+），所有代码必须无告警通过
- 函数命名：小写加下划线
- 变量：全局用大写下划线，局部变量用小写
- 函数内变量一律使用 `local`
- 所有变量加引号：`"$VAR"`
- 条件判断用 `[[`，算术用 `((`
- 禁止 `eval`，禁止 source 不可信文件

## 提交信息

遵循 [Conventional Commits](https://www.conventionalcommits.org/)：

```
type(scope): description

[可选正文]

[可选脚注]
```

类型：feat、fix、docs、style、refactor、test、chore、perf

## Pull Request

1. Fork 本仓库
2. 创建功能分支：`git checkout -b feat/my-feature`
3. 修改代码并补充测试
4. 运行 `make test`，必须全部通过
5. 提交 PR，并写清说明

## 发布流程

发布通过 release-please 自动化完成：
1. 合并到 main 后触发 release PR
2. 审核并合并 release PR
3. 自动创建 tag 并发布 GitHub Release
4. 安装脚本获取最新 release

## 安全

请通过 GitHub Security Advisories 私下报告安全问题。
威胁模型与安全实践见 [SECURITY.md](SECURITY.md)。
