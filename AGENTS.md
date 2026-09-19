# Agent Instructions

**English** | [简体中文](AGENTS.zh-CN.md)

This file provides guidance for AI agents working on the ip-allowlist project.

## Project Overview

ip-allowlist is a Linux shell script for managing firewall allow-lists from Cloudflare and other IP sources. It supports nftables, ufw, and firewalld backends with fail2ban integration.

## Architecture

- **Entry point**: `ip-allowlist` (main script)
- **Libraries**: `lib/` directory with modular components
  - `common.sh` - Shared utilities (logging, HTTP fetch, locking, parsing)
  - `source.sh` - Source fetch/parse/validate/canonicalize
  - `state.sh` - State management (snapshots, hashes, in-progress marker)
  - `fail2ban.sh` - Fail2ban ignoreip union drop-in management
  - `firewall/nft.sh` - nftables backend (per-source interval sets)
  - `firewall/ufw.sh` - ufw backend (commented allow rules, diffed on sync)
  - `firewall/firewalld.sh` - firewalld backend (hash:net ipsets + rich rules)
- **Config**: `/etc/ip-allowlist/config.conf` + `sources.d/*.conf`
- **Systemd**: Timer (15min) + service + optional boot service
- **Install**: `install.sh` with atomic staging; uninstall is built into the CLI (`ip-allowlist uninstall`)

## Key Design Principles

1. **No eval** - Strict key=value parser only
2. **No external deps** - bash 4.4+, coreutils, curl/wget only
3. **Atomic operations** - Staged changes, atomic rename
4. **Crash recovery** - Snapshot rollback, in-progress marker
5. **Explicit config** - No auto-detection of firewall backend
6. **Per-source isolation** - Separate sets/chains per source
7. **Security first** - Input validation, safe temp files, fixed User-Agent

## Testing

- `make test` runs lint + unit + integration (`test-unit`, `test-integration`,
  `test-images`, `hooks` are also available)
- Integration tests use Docker/podman with per-distro images
- Test runner: `tests/run.sh` (auto-detects podman→docker)
- Bats for unit tests (if available), custom for integration

## Configuration Schema

Main config (`config.conf`):
- `schema_version` - Config version for migration
- `firewall_enabled` - true|false (default: true)
- `fail2ban_enabled` - true|false (default: true)
- `firewall_backend` - nft|ufw|firewalld (required when firewall_enabled=true)
- `allow_conflicting_firewall` - true|false (default: false)
- `sources_dir` - Sources directory (default: /etc/ip-allowlist/sources.d)
- `allow_empty_sources` - true|false (default: false)
- `allow_ports` - 443 | 80,443 | 20000-40000 | all (default: 443)
- `allow_protocol` - tcp|udp|tcp+udp (default: tcp+udp; ignored when allow_ports=all)
- `enable_ipv4` / `enable_ipv6` - true|false (default: true)
- `ipv6_required` - true|false (default: false)
- `http_timeout` - seconds (default: 15)
- `http_retries` - integer (default: 3)
- `user_agent` - HTTP User-Agent (default: ip-allowlist)
- `min_entries` - Minimum entries, empty -> 1
- `max_shrink_ratio` - 0..1 (default: 0.5)
- `update_interval` - duration (default: 1d)
- `timer_interval` - duration (default: 15m)
- `update_on_boot` - true|false (default: true)
- `auto_update` - true|false (default: false)
- `update_check_interval` - duration (default: 1d)
- `repo` - owner/name (default: SemouSky/ip-allowlist)
- `fail2ban_ignoreip_file` - drop-in path (default: /etc/fail2ban/jail.d/zz-ip-allowlist.local)
- `fail2ban_merge_existing` - true|false (default: true)
- `firewalld_zone` - zone name (default: firewalld default)
- `state_dir` - State directory (default: /var/lib/ip-allowlist)
- `snapshot_retention` - integer (default: 3)
- `lock_file` - Lock path (default: /run/ip-allowlist.lock)
- `lock_wait` - seconds (default: 30)
- `log_level` - debug|info|warn|error (default: info)
- `log_target` - auto|stdout|file|syslog|none, comma separated (default: auto)
- `log_file` - required when log_target includes file (default: empty)
- `log_format` - text|json (default: text)

Source config (`sources.d/*.conf`):
- `name` - ^[a-z][a-z0-9_-]{0,15}$, unique (required)
- `enabled` - true|false (default: true)
- `type` - http|file (required)
- `urls` - space/comma separated URLs (http type)
- `paths` - space separated paths (file type)
- `format` - text (only value in v1)
- `firewall_enabled` / `fail2ban_enabled` - inherit
- `enable_ipv4` / `enable_ipv6` / `ipv6_required` - inherit
- `allow_ports` / `allow_protocol` - inherit
- `update_interval` - inherit (duration)
- `http_timeout` / `http_retries` / `user_agent` - inherit
- `min_entries` / `max_shrink_ratio` - inherit


## Development Workflow

1. Make changes to library files
2. Run `make lint` to check syntax
3. Run `make unit` for unit tests
4. Run `make integration` for integration tests
5. All tests must pass before commit

## Common Tasks

### Adding a new firewall backend
1. Create `lib/firewall/<backend>.sh`
2. Implement required functions (see nft.sh for interface)
3. Update main script to load backend
4. Add tests

### Adding a new source type
1. Extend `lib/source.sh` parse functions
2. Add fetch logic in `source_fetch()`
3. Add validation
4. Update documentation

### Debugging
- Set `LOG_LEVEL=debug` in config or environment
- Check state: `ip-allowlist status`
- View logs: `journalctl -u ip-allowlist -f`

## File Paths

All paths in config are relative to config file directory unless absolute.
No spaces allowed in path values.

## Versioning

Version in `version.txt`, managed by release-please (simple type).
CHANGELOG.md updated automatically.