# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0](https://github.com/SemouSky/ip-allowlist/compare/v0.2.0...v0.3.0) (2026-09-19)


### ⚠ BREAKING CHANGES

* require an explicit command, native uninstall, real install help

### Features

* require an explicit command, native uninstall, real install help ([8398cf6](https://github.com/SemouSky/ip-allowlist/commit/8398cf6e61d7e3cb4eca43b4e8f53ea4155f2d0d))


### Bug Fixes

* **config:** strip inline comments from values ([57ecd83](https://github.com/SemouSky/ip-allowlist/commit/57ecd83d077c86b9f36f25c5be876e570efb40ea))

## [0.2.0](https://github.com/SemouSky/ip-allowlist/compare/v0.1.1...v0.2.0) (2026-09-19)


### ⚠ BREAKING CHANGES

* adopt the planned flat config schema

### Features

* adopt the planned flat config schema ([abb74a2](https://github.com/SemouSky/ip-allowlist/commit/abb74a21a873987c1b26faf836f771806f4ae031))
* auto_update execution and pre-run crash recovery ([acf8fbc](https://github.com/SemouSky/ip-allowlist/commit/acf8fbc6d715105b3dc129ff4b8d9417b54f9938))
* **cli:** per-command help and upgrade --sync ([df0fc08](https://github.com/SemouSky/ip-allowlist/commit/df0fc0851058275bb4425e61be40f13e1f6eabb3))
* **cli:** richer status, log components and planned repo layout ([a3313fa](https://github.com/SemouSky/ip-allowlist/commit/a3313fa7ce535b07499ddb257cca26698a5834ab))
* **config:** add allow_ports, allow_protocol and family switches ([35f4500](https://github.com/SemouSky/ip-allowlist/commit/35f4500bb03ef05567da1327dbe25d11c48da771))
* **firewall:** adopt the planned nft model and readiness checks ([d162efd](https://github.com/SemouSky/ip-allowlist/commit/d162efda67e71f74973be55be0d5b0ade429914e))
* **firewall:** file-level rollback and exact firewalld rules ([31d546b](https://github.com/SemouSky/ip-allowlist/commit/31d546b574ee0c68fea58e502b9ba2cf765384df))
* **nft:** apply source changes incrementally ([16e0bac](https://github.com/SemouSky/ip-allowlist/commit/16e0bacd164881de126d35dc32330fe68de9b7db))
* **upgrade:** offline paths, 0600 state files and docs polish ([7605f0a](https://github.com/SemouSky/ip-allowlist/commit/7605f0a16d956989df1fc4ecf92642a8165ae737))
* verify applied state, lifecycle list and fail2ban checks ([edbccf7](https://github.com/SemouSky/ip-allowlist/commit/edbccf73f625e246b4aac22729adda89c41822ba))


### Bug Fixes

* close the remaining plan gaps found in the re-audit ([7e7eeb2](https://github.com/SemouSky/ip-allowlist/commit/7e7eeb274c7e76d5315dae50e32a2909253616c1))
* fourth-pass audit gaps (snapshots, residual, boot unit, timer interval) ([653c359](https://github.com/SemouSky/ip-allowlist/commit/653c359010afa6fc6431a6e74c478f4d6e1f61bb))
* **systemd:** start even when optional paths are absent ([a6431ca](https://github.com/SemouSky/ip-allowlist/commit/a6431cae53cde299d4e9ccb27f03e2a08f24c76e))

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
- running `ip-allowlist` with no command now prints help instead of syncing
- `uninstall` is built into the CLI; the separate uninstall.sh is removed
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
- ufw/firewalld configuration directories are snapshotted before apply and
  restored as a last-resort rollback; firewalld records its exact rich rules
- veth/netns connectivity integration test; documented that nft `accept` is not
  final across base chains and that default-deny is out of scope
- nft applies per-source updates (flush set/chain, delete removed sources) in a
  single transaction when the table exists, falling back to full regeneration
  only on first run, backend switch, or a missing table
- `help [command]` prints per-command help; `upgrade --sync` runs a sync after
  upgrading
- snapshots are taken before removing a disabled/removed source; a missing old
  backend tool is recorded as `residual` instead of a hard failure; the boot
  service is enabled/disabled on backend switch; the systemd timer is generated
  from `timer_interval`; `version` records the build commit when available and
  resolves `state_dir` before the config is loaded
- unit tests ported to bats (`tests/bats/*.bats`, with `tests/unit.sh` as a
  fallback when bats is unavailable); integration scenarios moved to
  `tests/docker/scenarios/*.sh`

## [0.0.0] - 2026-09-18

### Added
- Initial repository setup with MIT license
