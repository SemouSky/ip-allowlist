#!/usr/bin/env bash
# Unit test entry point: run the bats suite when bats is available, otherwise
# fall back to the plain-bash unit tests (hosts/containers without bats).
set -uo pipefail

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

if command -v bats >/dev/null 2>&1; then
  exec bats "$ROOT/tests/bats"/*.bats
fi

echo "bats not available; running tests/unit.sh instead" >&2
exec bash "$ROOT/tests/unit.sh"
