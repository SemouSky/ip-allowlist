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
curl -fsSL https://raw.githubusercontent.com/SemouSky/ip-allowlist/main/install.sh | bash
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
ip-allowlist              # Sync all sources (default)
ip-allowlist sync         # Explicit sync
ip-allowlist check        # Check for changes without applying
ip-allowlist sources      # List configured sources
ip-allowlist status       # Show status (--check for Nagios format)
ip-allowlist cleanup      # Remove firewall objects and fail2ban drop-in
ip-allowlist version      # Show version
ip-allowlist upgrade      # Check for updates
ip-allowlist install      # Install system-wide
ip-allowlist uninstall    # Uninstall (--purge to remove data)
ip-allowlist apply-offline # Apply from local state
```

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