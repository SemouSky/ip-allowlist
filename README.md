# ip-allowlist

**English** | [简体中文](README.zh-CN.md)

[![CI](https://github.com/SemouSky/ip-allowlist/actions/workflows/ci.yml/badge.svg)](https://github.com/SemouSky/ip-allowlist/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Linux shell script that periodically fetches Cloudflare IP ranges (IPv4/IPv6) and applies them to firewall allow-lists (nftables, ufw, firewalld) and fail2ban ignoreip.

## Features

- **Multi-source support**: Fetch IP ranges from multiple HTTP/file sources
- **Multi-backend**: nftables (per-source sets), ufw (commented rules), firewalld (ipsets + rich rules)
- **Fail2ban integration**: Automatic union of all sources as ignoreip drop-in
- **Per-source isolation**: Each source maintains its own firewall objects
- **Systemd timer**: Automatic periodic updates (default 15min)
- **Crash recovery**: Snapshot rollback and in-progress markers
- **Atomic operations**: Staged changes with atomic rename
- **Security-first**: No eval, strict input validation, safe temp files

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/SemouSky/ip-allowlist/main/install.sh | sudo bash
```

Or manually:

```bash
git clone https://github.com/SemouSky/ip-allowlist.git
cd ip-allowlist
sudo ./install.sh
```

## Configuration

Main config: `/etc/ip-allowlist/config.conf`
Sources: `/etc/ip-allowlist/sources.d/*.conf`

Example Cloudflare source (`/etc/ip-allowlist/sources.d/cloudflare.conf`):

```ini
enabled=true
name=cloudflare
type=http
urls=https://www.cloudflare.com/ips-v4,https://www.cloudflare.com/ips-v6
min_entries=5
max_shrink_ratio=0.5
update_interval=3600
```

## Commands

```bash
ip-allowlist                 # Sync all sources (default; alias: run)
ip-allowlist sync            # Explicit sync
ip-allowlist --source NAME   # Limit sync/check/status to one source (repeatable)
ip-allowlist --allow-empty   # Allow clearing everything when no source is active
ip-allowlist check           # Validate and report changes without applying
ip-allowlist check --offline # Validate config only, no network
ip-allowlist apply-offline   # Apply from cached state, no network
ip-allowlist sources         # List configured sources (--json)
ip-allowlist status          # Show status (--json, --check for Nagios)
ip-allowlist cleanup         # Remove firewall objects and fail2ban drop-in
ip-allowlist version         # Show version
ip-allowlist upgrade         # Check for/install updates
ip-allowlist upgrade --version 0.3.0 --from-dir DIR  # Offline / pinned install
ip-allowlist install         # Install system-wide
ip-allowlist uninstall       # Uninstall (--purge to remove data)
```

`allow_ports` defaults to `443` with `allow_protocol=tcp+udp`; set
`allow_ports=all` to allow every port from the source addresses.

## Firewall caveats

- The nft table uses `policy accept` and only adds accept rules; it never
  changes the base policy or other rules. A host that runs default-deny must
  allow the source ranges in its own policy as well.
- In nftables an `accept` verdict is not final across base chains in different
  tables, so a separate default-deny chain can still drop allow-listed traffic.
- Docker can bypass ufw/firewalld; see the backend documentation.

## Requirements

- Linux with bash 4.4+
- coreutils, curl/wget, tar, gzip
- One of: nftables, ufw, firewalld
- fail2ban (optional, for ignoreip integration)
- systemd (for timer)

## Documentation

- [Architecture](docs/architecture.md)
- [Configuration](docs/configuration.md)
- [Sources](docs/sources.md)
- [Operations](docs/operations.md)
- [Development](docs/development.md)
- [Security](docs/security.md)

## License

MIT License - see [LICENSE](LICENSE) for details.