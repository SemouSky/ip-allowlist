# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1](https://github.com/SemouSky/ip-allowlist/compare/v0.1.0...v0.1.1) (2026-09-18)


### Bug Fixes

* **install:** support the curl | sudo bash bootstrap ([601ce1e](https://github.com/SemouSky/ip-allowlist/commit/601ce1ee22a6868902b35d2212c0729e826e556c))

## [0.1.0](https://github.com/SemouSky/ip-allowlist/compare/v0.0.1...v0.1.0) (2026-09-18)


### Features

* implement ip-allowlist firewall allow-list manager ([1e3fd04](https://github.com/SemouSky/ip-allowlist/commit/1e3fd04131307caeb72d78eb9a7f9b149364ca10))

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
