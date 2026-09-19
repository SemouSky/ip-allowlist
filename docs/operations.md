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
| `ip-allowlist upgrade [--check] [--version VER] [--from-dir DIR] [--from-tarball FILE] [--sync] [--force]` | Check for/install updates; `--sync` runs a sync after upgrading |
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

Without systemd the installer writes `/etc/cron.d/ip-allowlist` instead of the
units (`timer_interval` rounded to minutes, plus a `@reboot apply-offline` entry
for the nft backend). Timer runs acquire the lock non-blocking and skip when
another run is active; manual runs wait up to `lock_wait` seconds. If a previous
backend could not be cleaned (its tool is gone), `status` reports
`residual: <backend>` and `status --check` returns WARNING.

The boot service only runs for the `nft` backend when
`/etc/ip-allowlist/update-on-boot` exists (created by the installer). It runs
`apply-offline` after `nftables.service` to rebuild the table from cached state.

## Monitoring

`status --check` returns Nagios-style codes:

- `0` OK
- `1` WARNING (no enabled sources, backend inactive, interrupted run)
- `2` CRITICAL (a source below `min_entries` or with no applied state)

```bash
ip-allowlist status --check
ip-allowlist status --json
```

Logs can be emitted as JSON with `log_format=json` for structured
collection.

## Logging

`log_target`:
- `auto` — stdout when interactive, and the log file when non-interactive
- `stdout` — stdout/stderr only (systemd journal)
- `file` — append to `log_file`
- `syslog` — send to syslog via `logger` (tag `ip-allowlist`)
- `none` — no log output

`log_target` accepts a comma separated list (for example `stdout,file`); `file`
additionally requires `log_file`. Records include a `component` field
(config/source/firewall/fail2ban/upgrade).

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

Rule parameters (`allow_ports`, `allow_protocol`, `enable_ipv4`,
`enable_ipv6`) and output-affecting settings (backend, chain name, table family,
firewalld zone) are fingerprinted. Changing any of them triggers a rebuild on
the next `sync`, even if the fetched source data is unchanged. To apply a
config change without fetching, run `apply-offline`.

Changing `firewall_backend` triggers a rebuild on the new backend and then
removes the previous backend's objects. Changing `firewalld_zone`
removes the old zone's rich rules, and changing `fail2ban_ignoreip_file` removes
the old drop-in file.

## Uninstall

```bash
sudo ./uninstall.sh            # keep config and state
sudo ./uninstall.sh --purge    # remove everything
```
