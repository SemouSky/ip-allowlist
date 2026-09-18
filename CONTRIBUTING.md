# Contributing to ip-allowlist

**English** | [简体中文](CONTRIBUTING.zh-CN.md)

Thank you for your interest in contributing!

## Code of Conduct

This project follows a standard code of conduct. Be respectful and constructive.

## Development Setup

```bash
git clone https://github.com/SemouSky/ip-allowlist.git
cd ip-allowlist
make test
```

## Testing

Run all tests:
```bash
make test
```

Run only lint:
```bash
make lint
```

Run unit tests:
```bash
make unit
```

Run integration tests (requires Docker or podman):
```bash
make integration
# Or specific distro:
make integration DISTRO=ubuntu-22.04
```

## Code Style

- Shell scripts: Follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- Use shellcheck (v0.8+) - all code must pass without warnings
- Functions: lowercase_with_underscores
- Variables: UPPER_SNAKE_CASE for globals, lowercase for locals
- Always use `local` for function variables
- Quote all variables: `"$VAR"`
- Use `[[` for conditionals, `((` for arithmetic
- No `eval`, no `source` of untrusted files

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): description

[optional body]

[optional footer]
```

Types: feat, fix, docs, style, refactor, test, chore, perf

## Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Make changes with tests
4. Run `make test` - all must pass
5. Submit PR with clear description

## Release Process

Releases are automated via release-please:
1. Changes merged to main trigger release PR
2. Review and merge release PR
3. Tag created, GitHub Release published automatically
4. Install script fetches latest release

## Security

Report security issues privately via GitHub Security Advisories.
See [SECURITY.md](SECURITY.md) for threat model and security practices.