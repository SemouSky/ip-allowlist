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
  status/<source>.last_run    Unix timestamp of last successful fetch
  snapshots/<source>/*.ips    Last 10 canonical snapshots per source
  snapshots/backend/          Last 5 backend state dumps
  fail2ban/union.ips          Rendered union of all source + user entries
  fail2ban/applied.hash       SHA-256 of the union drop-in content
```

## nftables model

A single table (`firewall_chain_name`, default `ip-allowlist`) in the configured
family (`inet` by default) holds:

- one interval set per source and address family (`v4_<source>`, `v6_<source>`)
- one base `input` chain at `priority -1` (before Docker's `filter` chain at
  priority 0) that accepts traffic matching any source set

The full ruleset is regenerated and applied atomically with `nft -f`. The
ruleset uses the idiom:

```
table inet ip-allowlist {}
delete table inet ip-allowlist
table inet ip-allowlist { ... }
```

This is idempotent whether or not the table already exists and keeps the swap
atomic. `policy accept` is used so the table never drops traffic by itself.

Sources that are disabled or removed from config have their `current/<name>.ips`
file deleted, which removes them from the regenerated ruleset.

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
(`firewall_firewalld_zone`, default firewalld's default zone):

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
`firewall_chain_name`, `firewall_table_family` or `firewall_firewalld_zone`
triggers a rebuild on the next `sync` even when source data is unchanged.

## Crash recovery

A run creates `state/in-progress` before processing and removes it on success.
If the next run finds a stale marker it logs a warning and re-applies the last
known-good `current/` state, which is idempotent. Per-source snapshots allow
manual rollback.

## Failure handling

- A source that fails fetch/validation is logged and skipped; the previous
  `current/` file is retained so the firewall keeps working.
- Any source failure makes `sync` exit non-zero (2) so timers/monitoring see it.
- If backend apply fails, `sync` exits 2 without updating applied hashes.
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
