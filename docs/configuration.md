# Configuration

**English** | [简体中文](configuration.zh-CN.md)

## Main config: `/etc/ip-allowlist/config.conf`

Format: strict `key=value`, one per line. `#` starts a comment. Values may be
optionally quoted. There is no variable expansion and no `eval`.

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `schema_version` | integer | `1` | Config schema version |
| `firewall_backend` | `nft`\|`ufw`\|`firewalld` | required | Backend to use (no auto-detect) |
| `firewall_chain_name` | identifier | `ip-allowlist` | nft table name / base chain prefix |
| `firewall_table_family` | `inet`\|`ip`\|`ip6` | `inet` | nft table family |
| `firewall_firewalld_zone` | zone name | firewalld default | Target zone for the firewalld backend |
| `allow_ports` | `any` or port list | `any` | Ports to allow from source addresses |
| `allow_protocol` | `any`\|`tcp`\|`udp`\|`tcp+udp` | `any` | Protocols to allow from source addresses |
| `enable_ipv4` | boolean | `true` | Apply IPv4 entries |
| `enable_ipv6` | boolean | `true` | Apply IPv6 entries |
| `fail2ban_enabled` | boolean | `true` | Manage the ignoreip drop-in |
| `fail2ban_ignoreip_file` | path | `/etc/fail2ban/ip-allowlist.conf` | Drop-in to manage |
| `paths.state_dir` | path | `/var/lib/ip-allowlist` | State directory |
| `paths.sources_dir` | path | `/etc/ip-allowlist/sources.d` | Source config directory |
| `paths.log_file` | path | `/var/log/ip-allowlist.log` | Log file (file targets) |
| `logging.level` | `debug`\|`info`\|`warn`\|`error` | `info` | Minimum log level |
| `logging.target` | `auto`\|`stdout`\|`file`\|`syslog` | `auto` | Log destination |
| `logging.format` | `text`\|`json` | `text` | Log record format |
| `update_interval` | seconds | `900` | Default minimum interval per source |
| `update_on_boot` | boolean | `true` | Enable the boot oneshot service |

Paths may be absolute or relative to the directory containing `config.conf`.
Path values must not contain spaces.

## Schema version

`schema_version` declares the config schema the file was written for. The
current supported version is `1`.

- Missing `schema_version` is treated as the current version.
- A value older than the current version triggers the migration path (no
  migrations are defined yet; the step is where future ones are added).
- A value newer than the current version is rejected with an error, so an older
  binary cannot silently misread a newer config.

## Booleans

Accepted true values: `true`, `1`, `yes`, `on`.
Accepted false values: `false`, `0`, `no`, `off`.

## Source configs: `sources.d/*.conf`

One file per source. The `name` key is the identity used for state and firewall
objects; it must be unique and match `[A-Za-z0-9_-]+`.

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `enabled` | boolean | `true` | Whether the source is active |
| `name` | identifier | required | Unique source name |
| `type` | `http`\|`file` | required | Source type |
| `urls` | comma-separated URLs | — | Required for `type=http` |
| `file_path` | path | — | Required for `type=file` |
| `min_entries` | integer | `1` | Fail if fewer canonical entries |
| `max_shrink_ratio` | 0..1 | `0.5` | Warn if entries shrink more than this |
| `update_interval` | seconds | global | Per-source override |
| `allow_ports` | `any` or port list | global | Override the main `allow_ports` |
| `allow_protocol` | `any`\|`tcp`\|`udp`\|`tcp+udp` | global | Override the main `allow_protocol` |
| `enable_ipv4` | boolean | global | Override the main `enable_ipv4` |
| `enable_ipv6` | boolean | global | Override the main `enable_ipv6` |

For `type=file`, a relative `file_path` is resolved against the config
directory. For `type=http`, only `http://` and `https://` URLs are accepted.

### Disable versus delete

- Setting `enabled=false` removes the source from the firewall/fail2ban on the
  next run but keeps its config file and state history.
- Deleting the config file removes the source and its stale state on the next
  run.

## Rule parameters

`allow_ports`, `allow_protocol`, `enable_ipv4` and `enable_ipv6` control what a
source is allowed to reach. Precedence is: source config > main config >
built-in default.

- `allow_ports=any` (default) allows every port from the source addresses.
  A list such as `443`, `443,8443` or `8000-8080` narrows the rule to those
  ports. A port list implies TCP and UDP unless `allow_protocol` says otherwise.
- `allow_protocol=any` (default) matches all protocols when `allow_ports=any`.
  `tcp`, `udp` or `tcp+udp` restrict the match; when a port list is set and the
  protocol is `any`, both TCP and UDP are used.
- `enable_ipv4` / `enable_ipv6` drop that address family from the firewall
  (fail2ban still receives the full union).

Rendering per backend:

- nft: `ip saddr @set accept` for all traffic, otherwise
  `ip saddr @set meta l4proto tcp accept` or `ip saddr @set tcp dport { 443 } accept`.
- ufw: `allow from <cidr>`, `allow from <cidr> proto tcp`, or
  `allow from <cidr> to any port 443 proto tcp`.
- firewalld: `rule ... source ipset="..." accept`,
  `... protocol value="tcp" accept`, or
  `... port port="443" protocol="tcp" accept`.

## Validation

Startup fails with a clear message on invalid config. Source files with a
missing `name`/`type`, an unknown `type`, missing `urls`/`file_path`, or
out-of-range numeric values are rejected. `max_shrink_ratio` must be between 0
and 1 inclusive.

## Example

```ini
firewall_backend=nft
firewall_table_family=inet
fail2ban_enabled=true
logging.level=info
update_interval=900
update_on_boot=true
```
