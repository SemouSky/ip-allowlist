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

- `tests/unit.sh` — pure-function tests: IPv4/IPv6 validation, normalization,
  merging, canonicalization, fail2ban normalization, config parsing, path and
  JSON helpers, due-interval logic.
- `tests/integration/run.sh` — end-to-end under a container: real `nft` table,
  idempotency, change detection, invalid filtering, `min_entries`, disabled and
  removed sources, status/sources output, fail2ban union and drop-in removal.
- `tests/integration/ufw.sh` — ufw backend under a container.
- `tests/integration/firewalld.sh` — firewalld backend under a container (needs dbus).
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
