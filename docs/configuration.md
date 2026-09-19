# Configuration

**English** | [简体中文](configuration.zh-CN.md)

## Main config: `/etc/ip-allowlist/config.conf`

Format: strict `key=value`, one per line. `#` starts a comment (also inline
after a value), values may be quoted, and **unknown keys are rejected**. Quote a
value to keep a literal `#` in it (for example `urls="https://example/#/list"`). There is no variable expansion and no
`eval`. Paths without a leading `/` are relative to the config file's directory
and must not contain spaces.

### Targets

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `firewall_enabled` | boolean | `true` | Master switch for the firewall target |
| `fail2ban_enabled` | boolean | `false` | Master switch for the fail2ban target |
| `firewall_backend` | `nft`\|`ufw`\|`firewalld` | required* | Backend (required when `firewall_enabled=true`); the installer preselects a running ufw/firewalld, then one that is enabled, otherwise nft (and warns if the selected backend is not running) |
| `allow_conflicting_firewall` | boolean | `false` | Proceed even if another manager is active |

### How the target switches work

`firewall_enabled` and `fail2ban_enabled` are **master switches**. Neither one
removes anything by itself:

| Main switch | Effect |
|---|---|
| `firewall_enabled=true` | Apply the allow-list to `firewall_backend`. Only sources that are `enabled=true` **and** have `firewall_enabled=true` are applied. |
| `firewall_enabled=false` | The firewall target is a no-op: nothing is applied and existing ip-allowlist firewall objects are left in place. Remove them with `ip-allowlist cleanup` (or `uninstall`). `firewall_backend` may be omitted. |
| `fail2ban_enabled=true` | Manage `[DEFAULT] ignoreip` in `fail2ban_ignoreip_file` with the canonical union of the sources whose `fail2ban_enabled` is true, merged with the user's own `ignoreip` entries when `fail2ban_merge_existing=true`. |
| `fail2ban_enabled=false` | The fail2ban target is a no-op: the existing drop-in is left untouched. Remove it with `ip-allowlist cleanup`. |

The per-source switches are combined with the main switch using **logical AND**,
and a source that omits them **inherits the main value**:

- `firewall_enabled=false` on a source excludes it from the firewall (its
  objects are removed if it had been applied) while its ranges are still fetched
  and cached for the fail2ban union.
- `fail2ban_enabled=false` on a source excludes it from the ignoreip union while
  it can still be applied to the firewall.
- Both switches participate in the source's effective hash, so changing one
  triggers a rebuild on the next `sync`.

If both targets end up disabled, or the selected backend tool is missing/not
running and fail2ban is unavailable, `sync` is a no-op and exits 0.

### Sources

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `sources_dir` | path | `/etc/ip-allowlist/sources.d` | Source config directory |
| `allow_empty_sources` | boolean | `false` | Allow clearing everything when no source is active |

A missing or unreadable `sources_dir` is a hard error; no cleanup is performed.

### Default allow rules (a source may override each)

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `allow_ports` | `443`, `80,443`, `20000-40000`, `all` | `80,443` | Ports to allow |
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

## Log destinations

`log_target` selects one or more destinations (comma separated):

- `auto` — write to stdout/stderr only. Under systemd that is the service
  journal (`journalctl -u ip-allowlist.service -f`); when run interactively it
  is the terminal. `auto` never writes a file.
- `stdout` — the same destination as `auto`, stated explicitly.
- `file` — append to `log_file` (required); also ship the logrotate config.
- `syslog` — send to syslog via `logger` (tag `ip-allowlist`).
- `none` — no log output.

Combine to fan out, for example `log_target=stdout,file` writes to both the
journal/terminal and the log file.

### Which keys a source can override

Every key in the example config is annotated `[main-only]` or
`[source-overridable]`. A source may override exactly these keys (omitting one
inherits the value from this file):

`allow_ports`, `allow_protocol`, `enable_ipv4`, `enable_ipv6`, `ipv6_required`,
`firewall_enabled`, `fail2ban_enabled`, `update_interval`, `http_timeout`,
`http_retries`, `user_agent`, `min_entries`, `max_shrink_ratio`.

Everything else (`firewall_backend`, `allow_conflicting_firewall`, `sources_dir`,
`allow_empty_sources`, `fail2ban_ignoreip_file`, `fail2ban_merge_existing`,
`firewalld_zone`, `state_dir`, `snapshot_retention`, `lock_file`, `lock_wait`,
`log_*`, `timer_interval`, `update_on_boot`, `auto_update`,
`update_check_interval`, `repo`, `schema_version`) is **main-only**; a source
file that sets one of them is rejected as an unknown key.

## Source configs: `sources.d/*.conf`

Start from `sources.d/example.conf.example` (a fully commented template for
`http` and `file` sources) or `sources.d/cloudflare.conf.example`, copy it to
`<name>.conf` and edit it. Only `*.conf` files are loaded, so the shipped
`.example` files are inert.

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
