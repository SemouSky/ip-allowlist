# Security

**English** | [简体中文](security.zh-CN.md)

The top-level [SECURITY.md](../SECURITY.md) covers reporting and the threat
model. This document details the implementation-level controls.

## Input handling

- **No `eval` anywhere.** Configuration is parsed by a strict reader that only
  accepts `key=value` lines and never expands values as shell code.
- **Token validation.** Every candidate address is validated before use:
  - IPv4 octets must be 0–255 with no leading zeros.
  - IPv4 prefixes must be 0–32; IPv6 prefixes 0–128.
  - IPv6 addresses are fully expanded and re-compressed, so malformed forms
    (multiple `::`, too many groups, invalid hex) are rejected.
- **Tokenization, not parsing.** Responses are treated as untrusted token
  streams. Non-IP tokens are discarded; no control characters or shell
  metacharacters reach a command line.
- **URL scheme allowlist.** Only `http://` and `https://` sources are accepted.
- **Backend name allowlist.** `firewall_backend` must be one of
  `nft|ufw|firewalld`; the value is never used to build a path directly.

## File and path safety

- Config path values must not contain whitespace.
- Relative paths resolve against the config directory; absolute paths are used
  as-is.
- Temporary files are created with `mktemp` (mode 0600) and registered for
  cleanup via an exit trap.
- All writes are staged to a temporary file in the destination directory and
  installed with an atomic `rename`, so readers never see partial content.
- `flock` serializes runs and prevents concurrent state mutation.

## Resource limits

- Download cap of 10 MiB per URL (`curl --max-filesize`).
- Connect timeout, overall timeout, and bounded retries.
- Lock acquisition timeout to avoid indefinite hangs.

## Privilege and exposure

- The script must run as root for firewall and fail2ban operations.
- `install.sh` sets:
  - config `0640` root:root
  - state dir `0700` root:root
  - log file created via logrotate as `0640` root:root
- The systemd unit uses `ProtectSystem=strict`, `ProtectHome=true`,
  `PrivateTmp=true`, `NoNewPrivileges=true`, and a minimal capability set
  (`CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE`), with `ReadWritePaths` limited to the
  state dir, log file, and `/etc/fail2ban`.

## fail2ban

- The managed drop-in contains only a `[DEFAULT]` `ignoreip` line with the
  canonical union of source and user entries.
- When collecting user `ignoreip` values, the drop-in itself is resolved via
  `readlink -f` and excluded, so re-runs are idempotent and cannot self-amplify.
- When the union is empty, the drop-in is removed rather than left with an empty
  `ignoreip`.

## Logging

- Logs never include fetched content, only counts and source names.
- JSON output escapes control characters to keep records well-formed.
- `run_id` correlates all records for a single execution.

## Residual risks

- No TLS pinning; HTTPS validation relies on the system trust store.
- No signature verification of fetched ranges; trust derives from the source
  URL and the `min_entries`/`max_shrink_ratio` guards.
- The firewall base chain accepts matching traffic at priority `-1`, before
  other filter chains; this is intentional and scoped to the configured sets.
