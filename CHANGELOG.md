# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial project scaffold
- Phase 1 MVP implementation (nft backend, Cloudflare source, fail2ban integration)
- Multi-source abstraction framework
- Systemd timer scheduling
- Atomic install/upgrade/uninstall
- Comprehensive test infrastructure
- ufw backend (comment-tagged allow rules, diffed on sync)
- firewalld backend (`hash:net` ipsets + rich rules, single reload)
- `cleanup` command to remove firewall objects and the fail2ban drop-in
- `logging.target=syslog` support via `logger` (tag `ip-allowlist`)
- Config `schema_version` validation and migration hook
- Backend-switch cleanup: changing `firewall_backend` removes the previous
  backend's objects; `firewall_firewalld_zone` and `fail2ban_ignoreip_file`
  changes clean up the old zone rules / drop-in
- Chinese translations of all documentation (`*.zh-CN.md`)

### Fixed
- `upgrade --check` now reports without installing (the flag was never wired up)

## [0.0.0] - 2026-09-18

### Added
- Initial repository setup with MIT license