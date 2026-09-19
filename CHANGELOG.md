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
- Configurable allow-rule parameters `allow_ports`, `allow_protocol`,
  `enable_ipv4` and `enable_ipv6` (main defaults, per-source overrides) with
  nft, ufw and firewalld rendering
- Desired-state fingerprint so config-only changes (rule parameters, backend,
  chain name, table family, zone) rebuild on the next sync
- Chinese translations of all documentation (`*.zh-CN.md`)

### Fixed
- `upgrade --check` now reports without installing (the flag was never wired up)
- firewalld cleanup/stale-set deletion (`--get-ipsets` returns space separated
  names on one line)

### Changed
- **BREAKING**: config now uses the planned flat keys
  (`firewall_enabled`, `sources_dir`, `state_dir`, `allow_ports`,
  `allow_protocol`, `enable_ipv4/6`, `log_level`, `log_target`, `log_file`,
  `log_format`, `firewalld_zone`, `lock_file`, `lock_wait`, ...); unknown keys
  are rejected
- Source keys are now `urls` / `paths` (lists) with `format`, and a strict
  `^[a-z][a-z0-9_-]{0,15}$` name; unknown keys are rejected
- Source data is parsed strictly: an invalid entry fails the source
- `max_shrink_ratio` now rejects the result (keeping previous values) unless
  `--force` is given
- Zero active sources aborts unless `allow_empty_sources=true` / `--allow-empty`

### Added
- Post-apply firewall verification with snapshot rollback on failure
- fail2ban `-t` validation with drop-in restore, and `fail2ban_merge_existing`
- `sources.known` lifecycle list and `snapshot_retention`
- `--source`, `--allow-empty`, `check --offline`, `run` alias
- `stale` status marker surfaced by `status --check`
- nftables backend uses the planned `inet ip_allowlist` table with per-source
  `al_<name>_v4/v6` sets, per-source `al_<name>` chains and a base-chain `jump`;
  the pre-rename `inet ip-allowlist` table is removed automatically
- ufw version check (>= 0.34) and firewalld service readiness check
- boot service rebuilds with `apply-offline` after `nftables.service`, installed
  only for the nft backend
- `status` now reports the desired-state hash, read-only artifact verification,
  fail2ban status, and the latest known version (`--json` too)
- log records include a `component` field; `log_target` accepts a comma list and
  `none`
- periodic update check (`update_check_interval`, `repo`) surfaced in `status`;
  `version` shows the install source
- Makefile targets `test-unit`, `test-integration`, `test-images`, `hooks`
- repository layout: `config/sources.d/`, `config/logrotate.d/ip-allowlist`,
  `.github` PR/issue templates and `CODEOWNERS`
- `auto_update=true` now installs the newer release and re-executes the run
- crash recovery rolls sources back to the snapshot taken during the interrupted
  run, using the in-progress marker start time
- `upgrade --version/--from-dir/--from-tarball` delegate to install.sh for
  offline or pinned installs; a failed install leaves the previous version intact
- state files are written `0600`

## [0.0.0] - 2026-09-18

### Added
- Initial repository setup with MIT license
