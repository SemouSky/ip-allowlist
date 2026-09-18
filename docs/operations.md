# Operations

**English** | [简体中文](operations.zh-CN.md)

## Installation

```bash
sudo ./install.sh
```

This installs the program to `/usr/local/lib/ip-allowlist` with a symlink at
`/usr/local/sbin/ip-allowlist`, creates `/etc/ip-allowlist` with a default
config and Cloudflare source, installs systemd units and logrotate config, and
enables `ip-allowlist.timer`.

## Commands

| Command | Description |
|---------|-------------|
| `ip-allowlist` / `sync` | Fetch sources and apply allow-lists |
| `ip-allowlist check` | Fetch and report changes without applying |
| `ip-allowlist apply-offline` | Apply from cached state, no network |
| `ip-allowlist sources` | List configured sources (`--json`) |
| `ip-allowlist status` | Show status (`--json`, `--check`) |
| `ip-allowlist cleanup` | Remove firewall objects and the fail2ban drop-in |
| `ip-allowlist version` | Show version |
| `ip-allowlist upgrade [--check]` | Check for/install updates (`--check` only reports) |
| `ip-allowlist install` | Install system-wide |
| `ip-allowlist uninstall [--purge]` | Remove |

Common flags: `--config FILE`, `--verbose`, `--quiet`, `--dry-run`, `--force`,
`--json`, `--check`, `--purge`, `--yes`.

## Scheduling

`ip-allowlist.timer` runs `ip-allowlist.service` every 15 minutes and at boot
(plus 2 minutes). The script itself also honours per-source `update_interval`,
so a 15-minute timer with a 1-hour source interval only refetches hourly.

```bash
systemctl list-timers ip-allowlist.timer
systemctl status ip-allowlist.service
journalctl -u ip-allowlist.service -f
```

The boot service only runs when `/etc/ip-allowlist/update-on-boot` exists, which
the installer creates based on `update_on_boot`. It runs `sync --force` so every
source is fetched at boot.

## Monitoring

`status --check` returns Nagios-style codes:

- `0` OK
- `1` WARNING (no enabled sources, backend inactive, interrupted run)
- `2` CRITICAL (a source below `min_entries` or with no applied state)

```bash
ip-allowlist status --check
ip-allowlist status --json
```

Logs can be emitted as JSON with `logging.format=json` for structured
collection.

## Logging

`logging.target`:
- `auto` — stdout when interactive, and the log file when non-interactive
- `stdout` — stdout/stderr only (systemd journal)
- `file` — append to `paths.log_file`
- `syslog` — send to syslog via `logger` (tag `ip-allowlist`); falls back to stdout if `logger` is unavailable

Logrotate is installed at `/etc/logrotate.d/ip-allowlist`.

## Rollback and recovery

Inspect snapshots under `/var/lib/ip-allowlist/snapshots/`. To roll back a
source manually, copy a snapshot over `current/<name>.ips` and run
`ip-allowlist apply-offline`.

If a run is interrupted, the `in-progress` marker triggers a recovery path on
the next run: any source missing its `current/` file is restored from its most
recent snapshot, then the known-good state is re-applied.

`ip-allowlist cleanup` removes all ip-allowlist firewall objects and the managed
fail2ban drop-in without uninstalling the program. It also invalidates the
applied hashes so the next `sync` rebuilds the allow-list.

## Backends

| Backend | Objects | Notes |
|---------|---------|-------|
| `nft` | One table, per-source interval sets, base `input` chain | Atomic `nft -f` apply |
| `ufw` | One commented allow rule per entry | Rules are diffed against `ufw show added`; large lists take longer because ufw reloads per change |
| `firewalld` | One `hash:net` ipset per source/family + rich rules | Applied `--permanent` then a single `--reload` |

Only one manager may be active. If a different manager is running than
`firewall_backend` specifies, the run stops with an error.

Changing `firewall_backend` triggers a rebuild on the new backend and then
removes the previous backend's objects. Changing `firewall_firewalld_zone`
removes the old zone's rich rules, and changing `fail2ban_ignoreip_file` removes
the old drop-in file.

## Uninstall

```bash
sudo ./uninstall.sh            # keep config and state
sudo ./uninstall.sh --purge    # remove everything
```
