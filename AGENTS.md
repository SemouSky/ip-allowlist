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
- **Install**: `install.sh` / `uninstall.sh` with atomic staging

## Key Design Principles

1. **No eval** - Strict key=value parser only
2. **No external deps** - bash 4.4+, coreutils, curl/wget only
3. **Atomic operations** - Staged changes, atomic rename
4. **Crash recovery** - Snapshot rollback, in-progress marker
5. **Explicit config** - No auto-detection of firewall backend
6. **Per-source isolation** - Separate sets/chains per source
7. **Security first** - Input validation, safe temp files, fixed User-Agent

## Testing

- `make test` runs lint + unit + integration
- Integration tests use Docker/podman with per-distro images
- Test runner: `tests/run.sh` (auto-detects podman→docker)
- Bats for unit tests (if available), custom for integration

## Configuration Schema

Main config (`config.conf`):
- `schema_version` - Config version for migration
- `firewall_backend` - nft|ufw|firewalld (required)
- `firewall_chain_name` - Base chain name (default: ip-allowlist)
- `firewall_table_family` - inet|ip|ip6 (default: inet)
- `fail2ban_enabled` - true|false (default: true)
- `fail2ban_ignoreip_file` - Path to drop-in (default: /etc/fail2ban/ip-allowlist.conf)
- `paths.state_dir` - State directory (default: /var/lib/ip-allowlist)
- `paths.sources_dir` - Sources directory (default: /etc/ip-allowlist/sources.d)
- `paths.log_file` - Log file (default: /var/log/ip-allowlist.log)
- `logging.level` - debug|info|warn|error (default: info)
- `logging.target` - auto|stdout|file|syslog (default: auto)
- `logging.format` - text|json (default: text)
- `update_interval` - Default interval seconds (default: 900)
- `update_on_boot` - true|false (default: true)

Source config (`sources.d/*.conf`):
- `enabled` - true|false (default: true)
- `name` - Unique source name (required)
- `type` - http|file (required)
- `urls` - Comma-separated URLs (http type)
- `file_path` - Path to file (file type)
- `min_entries` - Minimum entries required (default: 1)
- `max_shrink_ratio` - Max shrink before alert (default: 0.5)
- `update_interval` - Override global interval (optional)

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