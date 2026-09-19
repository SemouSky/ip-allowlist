# Sources

**English** | [简体中文](sources.zh-CN.md)

A source is a named provider of IP ranges. Each source is applied as its own
set/object in the firewall so sources stay independent, and all sources are
unioned for fail2ban.

## Cloudflare

The default source uses Cloudflare's published ranges:

```ini
enabled=true
name=cloudflare
type=http
urls=https://www.cloudflare.com/ips-v4,https://www.cloudflare.com/ips-v6
min_entries=5
max_shrink_ratio=0.5
```

## HTTP sources

`type=http` fetches each URL in `urls` (comma separated) and concatenates the
responses. Content is parsed as a stream of whitespace/comma separated tokens;
any token that is a valid IPv4/IPv6 address or CIDR is kept and everything else
is ignored. This means plain-text one-per-line lists and simple JSON arrays both
work without a JSON parser.

Fetching uses `curl` when available, otherwise `wget`, with:
- connect timeout 30s, total timeout 90s
- up to 3 retries
- a 10 MiB download cap
- User-Agent `ip-allowlist/<version>`

Only `http://` and `https://` URLs are accepted.

## File sources

`type=file` reads a local file, which is useful for air-gapped hosts or testing:

```ini
enabled=true
name=internal
type=file
paths=/etc/ip-allowlist/internal-ranges.txt
min_entries=1
```

A relative `paths` is resolved against the main config directory.

## Rule parameters

A source can override the main allow-rule parameters:

```ini
allow_ports=443
allow_protocol=tcp+udp
enable_ipv4=true
enable_ipv6=false
```

The default is `any`, which allows every port and protocol from the source
addresses. See [configuration](configuration.md#rule-parameters) for the
semantics of each option.

## Canonicalization

All sources go through the same pipeline:

1. Tokenize on whitespace and commas.
2. Validate each token as IPv4/IPv6 address or CIDR.
3. Normalize: network address for IPv4, canonical compressed form for IPv6;
   bare addresses become `/32` or `/128`.
4. Deduplicate.
5. Sort (numeric for IPv4, expanded-hex for IPv6).
6. Merge overlapping/adjacent IPv4 ranges into minimal CIDRs.

Invalid tokens are dropped with a debug log. If a source yields nothing after
canonicalization, `min_entries` (default 1) fails the source.

## Safety thresholds

- `min_entries`: hard failure if the canonical count is below the value.
- `max_shrink_ratio`: warning if the new count shrank by more than the ratio
  relative to the previously applied count.

These protect against upstream outages, truncated responses, or accidental
empty files replacing a working allow-list.

## Adding a source

1. Create `/etc/ip-allowlist/sources.d/<name>.conf`.
2. Set a unique `name` and the appropriate `type`.
3. Validate with `ip-allowlist check` (no changes applied).
4. Apply with `ip-allowlist sync`.

No code change is required for new HTTP/file sources.
