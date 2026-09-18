# Configuration

**English** | [简体中文](configuration.zh-CN.md)

## Main config: `/etc/ip-allowlist/config.conf`

Format: strict `key=value`, one per line. `#` starts a comment, values may be
quoted, and **unknown keys are rejected**. There is no variable expansion and no
`eval`. Paths without a leading `/` are relative to the config file's directory
and must not contain spaces.

### Targets

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `firewall_enabled` | boolean | `true` | Master switch for the firewall target |
| `fail2ban_enabled` | boolean | `true` | Master switch for the fail2ban target |
| `firewall_backend` | `nft`\|`ufw`\|`firewalld` | required* | Backend (required when `firewall_enabled=true`) |
| `allow_conflicting_firewall` | boolean | `false` | Proceed even if another manager is active |

`firewall_enabled=false` / `fail2ban_enabled=false` make that target a no-op: it
is not applied and existing objects are **not** removed (use `uninstall`).

### Sources

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `sources_dir` | path | `/etc/ip-allowlist/sources.d` | Source config directory |
| `allow_empty_sources` | boolean | `false` | Allow clearing everything when no source is active |

A missing or unreadable `sources_dir` is a hard error; no cleanup is performed.

### Default allow rules (a source may override each)

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `allow_ports` | `443`, `80,443`, `20000-40000`, `all` | `443` | Ports to allow |
| `allow_protocol` | `tcp`\|`udp`\|`tcp+udp` | `tcp+udp` | Protocols (ignored when `allow_ports=all`) |
| `enable_ipv4` / `enable_ipv6` | boolean | `true` | Address families |
| `ipv6_required` | boolean | `false` | Fail a source when it has no IPv6 entries |
| `http_timeout` | seconds | `15` | HTTP connect/max time |
| `http_retries` | integer | `3` | HTTP retries |
| `user_agent` | string | `ip-allowlist` | HTTP User-Agent |
| `min_entries` | integer | empty → `1` | Minimum entries across enabled families |
| `max_shrink_ratio` | 0..1 | `0.5` | Reject a result that shrinks more than this |

### Schedule and self-update

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `update_interval` | duration | `1d` | Default per-source fetch interval |
| `timer_interval` | duration | `15m` | systemd timer cadence |
| `update_on_boot` | boolean | `true` | Enable the boot service |
| `auto_update` | boolean | `false` | Automatically install a newer version |
| `update_check_interval` | duration | `1d` | How often to check for a new version |
| `repo` | `owner/name` | `SemouSky/ip-allowlist` | Repository used by `upgrade` |

Durations accept a bare number (seconds) or an `s`/`m`/`h`/`d`/`w` suffix.

### fail2ban / firewalld / paths / logging

| Key | Values | Default |
|-----|--------|---------|
| `fail2ban_ignoreip_file` | path | `/etc/fail2ban/jail.d/zz-ip-allowlist.local` |
| `fail2ban_merge_existing` | boolean | `true` |
| `firewalld_zone` | zone name | firewalld default |
| `state_dir` | path | `/var/lib/ip-allowlist` |
| `snapshot_retention` | integer | `3` |
| `lock_file` | path | `/run/ip-allowlist.lock` |
| `lock_wait` | seconds | `30` |
| `log_level` | `debug`\|`info`\|`warn`\|`error` | `info` |
| `log_target` | comma list of `auto`\|`stdout`\|`file`\|`syslog`\|`none` | `auto` |
| `log_file` | path | empty (required when `log_target` includes `file`) |
| `log_format` | `text`\|`json` | `text` |
| `schema_version` | integer | `1` |

## Source configs: `sources.d/*.conf`

| Key | Values | Default |
|-----|--------|---------|
| `name` | `^[a-z][a-z0-9_-]{0,15}$`, unique | required |
| `enabled` | boolean | `true` |
| `type` | `http`\|`file` | required |
| `urls` | space/comma separated URLs | required for `http` |
| `paths` | space separated paths | required for `file` |
| `format` | `text` (only value in v1) | `text` |
| `firewall_enabled` / `fail2ban_enabled` | boolean | inherit |
| `enable_ipv4` / `enable_ipv6` / `ipv6_required` | boolean | inherit |
| `allow_ports` / `allow_protocol` | as above | inherit |
| `update_interval` | duration | inherit |
| `http_timeout` / `http_retries` / `user_agent` | as above | inherit |
| `min_entries` / `max_shrink_ratio` | as above | inherit |

Unknown keys in a source file are rejected. `urls` and `paths` are mutually
exclusive.

## Rule parameter semantics

- `allow_ports=all` allows every port and **ignores** `allow_protocol`.
- A port list implies TCP and UDP when `allow_protocol` is left at its default.
- `enable_ipv4`/`enable_ipv6` restrict the firewall only; fail2ban still gets
  the full union.

Rendering per backend (`allow_ports=443`, `allow_protocol=tcp`):

- nft: `ip saddr @set tcp dport { 443 } accept`
- ufw: `allow from <cidr> to any port 443 proto tcp`
- firewalld: `rule ... source ipset="..." port port="443" protocol="tcp" accept`

## Precedence

CLI flags > source config > main config > built-in defaults.
