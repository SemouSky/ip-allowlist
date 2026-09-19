# Development

**English** | [简体中文](development.zh-CN.md)

## Requirements

- bash 4.4+ for running and unit testing
- shellcheck for linting
- podman or docker for integration tests
- GNU coreutils

## Layout and conventions

- All logic lives in `lib/`; the `ip-allowlist` entry point handles CLI, config,
  and dispatch only.
- `set -uo pipefail` is used, but not `set -e`; errors are handled explicitly so
  partial failures can be logged and reported cleanly.
- No `eval`. Config is parsed with a strict `key=value` reader.
- Prefer assignment arithmetic (`x=$((x+1))`) over `((x++))` to avoid non-zero
  returns.
- Functions are `lower_snake_case`; globals are `UPPER_SNAKE_CASE`.
- Quote variables; use `[[ ]]` for tests.

## Running tests

```bash
make test          # lint + integration (container if available)
make lint          # shellcheck + bash -n
make unit          # host unit tests (needs bash 4.4+)
make integration   # container integration tests
make integration DISTRO=ubuntu-22.04
```

`tests/run.sh` detects podman before docker and can run tests directly inside a
container with `--local` (used by CI).

If the host lacks bash 4.4+, unit tests are skipped on the host (exit 77) and
should be run in a container.

## Test structure

- `tests/bats/*.bats` — unit tests (bats): config parsing, durations, IPv4/IPv6
  validation and normalization, merging, canonicalization (strict/lenient),
  rule parameters, backend rule generation.
- `tests/bats/run.sh` — runs the bats suite, or falls back to
  `tests/unit.sh` when bats is unavailable.
- `tests/unit.sh` — plain-bash fallback covering the same pure functions.
- `tests/docker/scenarios/run.sh` — end-to-end nft scenario: idempotency, change
  detection, strict parsing, `min_entries`, disabled/removed sources,
  status/sources, fail2ban union, backend switch, snapshots, crash recovery,
  install/uninstall.
- `tests/docker/scenarios/ufw.sh`, `firewalld.sh` — backend scenarios.
- `tests/docker/scenarios/connectivity.sh` — veth/netns data-path check.
- `tests/docker/<distro>/Dockerfile` — per-distro images.

## Adding a firewall backend

1. Create `lib/firewall/<backend>.sh`.
2. Implement `backend_validate`, `apply`, `snapshot`, `cleanup`, `status`
   equivalents (see `nft.sh` for the shape).
3. Wire it into `load_backend`, `backend_validate`, `backend_apply`,
   `backend_snapshot`, `backend_cleanup`, and `backend_status` in the entry
   point.
4. Add conflict detection in `firewall_check_conflicts` if needed.
5. Add tests.

## Adding a source type

1. Extend `source_load_config` validation in `lib/source.sh`.
2. Add a branch to `source_fetch`.
3. Update `docs/sources.md` and tests.

## Releases

Releases are automated with release-please (`simple` type):

1. Merge changes to `main`.
2. release-please opens a release PR bumping `version.txt` and `CHANGELOG.md`.
3. Merging that PR tags the release and publishes a GitHub Release with a
   source tarball.
4. `ip-allowlist upgrade` downloads the latest release tarball.
