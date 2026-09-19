# Architecture

**English** | [简体中文](architecture.zh-CN.md)

## Overview

`ip-allowlist` fetches IP ranges from configured sources, canonicalizes them,
and applies them to the host firewall and fail2ban. It is a set of bash scripts
with no runtime dependencies beyond bash 4.4+, coreutils, curl/wget, and the
selected firewall backend.

## Component layout

```
ip-allowlist            Main entry point and CLI dispatch
lib/
  common.sh             Logging, KV parsing, paths, locking, HTTP, hashing
  source.sh             IP validation, normalization, merging, fetch, process
  state.sh              State dir layout, hashes, snapshots, status, markers
  fail2ban.sh           ignoreip union and drop-in management
  firewall/
    nft.sh              nftables backend (per-source interval sets)
    ufw.sh              ufw backend (commented allow rules, diffed)
    firewalld.sh        firewalld backend (hash:net ipsets + rich rules)
config/
  config.conf.example   Main configuration template
sources.d/
  cloudflare.conf.example  Source template
systemd/                Timer + service + boot service
install.sh              Atomic staged install/upgrade
uninstall.sh            Removal (--purge for data)
tests/                  Unit + container integration tests
```

## Data flow

```
sources.d/*.conf
      |
      v
 source_fetch (http/file) --- raw text
      |                            |
      |                            v
      |                    canonicalize_stream
      |              validate -> normalize -> dedupe
      |              -> sort -> merge (IPv4)
      |                            |
      v                            v
 thresholds check          state/current/<name>.ips
 (min_entries,                    |
  max_shrink_ratio)               v
                          backend_apply (nft)
                                  |
                                  v
                          fail2ban union + drop-in
```

## State layout

```
/var/lib/ip-allowlist/
  in-progress                 Marker while a run is active
  backend                     Last applied backend name
  firewall.firewalld-zone     Last applied firewalld zone (for cleanup)
  fail2ban.ignoreip-file      Last applied drop-in path (for cleanup)
  .lock                       flock target
  current/<source>.ips        Canonical entries currently applied
  rules/<source>.conf         Effective rule parameters (ports/protocol/families)
  applied/<source>.hash       Hash of applied entries + rule parameters
  desired.hash                Fingerprint of the whole desired firewall state
  sources.known               Sources that have been applied (for cleanup)
  status/<source>.last_run    Unix timestamp of last successful fetch
  status/<source>.stale       Present when the last fetch failed (values kept)
  snapshots/<source>/*.ips    Last 10 canonical snapshots per source
  snapshots/backend/          Last 5 backend state dumps
  fail2ban/union.ips          Rendered union of all source + user entries
  fail2ban/applied.hash       SHA-256 of the union drop-in content
```

## nftables model

A single fixed table `inet ip_allowlist` holds, per source:

- one interval set per address family (`al_<source>_v4`, `al_<source>_v6`)
- one regular chain `al_<source>` with the accept rules
- a `jump al_<source>` entry in the base `input` chain
  (`type filter hook input priority filter; policy accept;`)

Rules look like `ip saddr @al_<source>_v4 tcp dport { 443 } accept`, or
`ip saddr @al_<source>_v4 accept` when `allow_ports=all`.

When the table already exists, only the sources that changed are updated in one
atomic `nft -f` transaction: their sets are flushed and refilled, their chain is
flushed and rewritten, and removed sources have their jump rule, chain and sets
deleted. Other sources are untouched. On the first run, a backend switch, or
when the table is missing, the full table is regenerated atomically using the
idempotent idiom:

```
table inet ip_allowlist {}
delete table inet ip_allowlist
table inet ip_allowlist { ... }
```

`policy accept` means the table never drops traffic by itself. The base chain
uses priority `filter`, so ordering relative to other managers (for example
Docker) is not guaranteed; see the README. Note that an nftables `accept` is not
final across base chains in different tables, so a host default-deny policy must
also allow the source ranges. Tables created by releases before the
plan naming (`inet ip-allowlist`) are removed automatically.

Sources that are disabled or removed from config have their `current/<name>.ips`
deleted, which removes them from the regenerated table.

## ufw model

ufw has no native set grouping, so each canonical entry is installed as an
individual allow rule tagged with a comment of the form
`ip-allowlist:<source>`. Sync reads the managed rules back from `ufw show added`,
normalizes them, and applies only the difference (`comm` of desired vs current):
new entries are added and stale entries are deleted. Disabled sources have their
`current/<name>.ips` removed, so their rules are deleted on the next sync.

## firewalld model

Each source gets one firewalld ipset per address family (`hash:net`) named
`ia-<source>-v4|v6-<hash>`, referenced by a rich rule in the target zone
(`firewalld_zone`, default firewalld's default zone):

```
rule family="ipv4" source ipset="ia-<source>-v4-<hash>" accept
```

Sync removes the ip-allowlist rich rules, recreates the desired ipsets with the
current entries, re-adds the rich rules, deletes stale ipsets, then performs a
single `firewall-cmd --reload`. All changes are written `--permanent` first, so
the runtime swap happens at the reload.

## Backend configuration and conflicts

The backend is explicit (`firewall_backend`); there is no auto-detection. Before
applying, the tool rejects a mismatch when a different firewall manager is
active (for example, `firewall_backend=nft` while ufw is active), and it rejects
the case where both ufw and firewalld are active.

When the configured backend differs from the backend recorded in state, the run
forces a rebuild so the new backend receives the allow-list, then removes the
objects left by the previous backend (for example, the old nft table when
switching to ufw). The firewalld zone and the fail2ban drop-in path are also
tracked, so changing either cleans up the previous zone's rich rules or the old
drop-in file.

Config-only changes are detected too: `desired.hash` fingerprints the backend,
table/chain/family, fail2ban settings and each source's entries plus rule
parameters, so editing `allow_ports`, `allow_protocol`, `enable_ipv4/6`,
`firewalld_zone`
triggers a rebuild on the next `sync` even when source data is unchanged.

## Crash recovery

A run creates `state/in-progress` (with a start timestamp) before processing
and removes it on success. If the next run finds a stale marker, it rolls every
source back to the snapshot taken during that interrupted run (snapshot mtime at
or after the marker's start), then continues normally. Per-source snapshots also
allow manual rollback.

## Failure handling

- A source that fails fetch/validation is logged, marked stale, and skipped; the
  previous `current/` file is retained so the firewall keeps working. The next
  run retries it immediately.
- A result that shrinks beyond `max_shrink_ratio` is rejected and the previous
  values are kept (`--force` bypasses the guard).
- Any source failure makes `sync` exit non-zero (2) so timers/monitoring see it.
- After the firewall is applied it is verified (sets/ipsets/rules present and
  counts matching). If verification fails, the sources are restored from the
  snapshots taken before the run and the previous state is re-applied; if that
  also fails, ufw/firewalld configuration directories are restored from the
  file snapshot taken before the run, and then `sync` exits 2 if still broken.
- firewalld records the exact rich rule strings it wrote, so a later apply
  removes them precisely (a prefix scan is kept as a fallback).
- The fail2ban drop-in is written only if `fail2ban-client -t` accepts it;
  otherwise the previous drop-in is restored.
- `flock` prevents concurrent runs.

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | Success / status OK |
| 1    | Status WARNING (`status --check`) |
| 2    | Critical / operational failure |
| 3    | Status UNKNOWN |
| 64   | Usage error |
| 77   | Tests skipped (not a runtime code) |
