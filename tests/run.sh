#!/usr/bin/env bash
# ip-allowlist test runner. Compatible with bash 3.2 (host) but tests need 4.4+.
set -uo pipefail

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="all"
DISTRO="ubuntu-24.04"
LOCAL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --unit) MODE="unit" ;;
    --integration) MODE="integration" ;;
    --local) LOCAL=1 ;;
    --distro) shift; [ $# -gt 0 ] || { echo "--distro requires a value" >&2; exit 64; }; DISTRO="$1" ;;
    --distro=*) DISTRO="${1#*=}" ;;
    -h|--help)
      cat <<'EOF'
Usage: tests/run.sh [--unit|--integration] [--distro NAME] [--local]

  --unit         Run unit tests only
  --integration  Run integration tests only
  --distro NAME  Container distro (default ubuntu-24.04)
  --local        Do not use a container; run directly on this host
EOF
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

INSIDE_CONTAINER=0
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
  INSIDE_CONTAINER=1
fi

find_bash4() {
  local candidate
  for candidate in "${BASH:-}" /usr/local/bin/bash /opt/homebrew/bin/bash /bin/bash bash; do
    [ -n "$candidate" ] || continue
    if command -v "$candidate" >/dev/null 2>&1; then
      local v major minor
      # shellcheck disable=SC2016
      v="$("$candidate" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null)"
      major="${v%%.*}"
      minor="${v##*.}"
      if [ "$major" -gt 4 ] 2>/dev/null || { [ "$major" -eq 4 ] && [ "$minor" -ge 4 ]; }; then
        printf '%s' "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

find_runtime() {
  if command -v podman >/dev/null 2>&1; then
    printf 'podman'; return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    printf 'docker'; return 0
  fi
  return 1
}

STATUS=0

run_unit_local() {
  local bash4
  if ! bash4="$(find_bash4)"; then
    echo "==> unit tests skipped: bash 4.4+ not found on host" >&2
    return 77
  fi
  echo "==> unit tests ($bash4)"
  "$bash4" "$ROOT/tests/bats/run.sh"
}

run_integration_local() {
  local rc=0
  echo "==> integration tests (local)"
  bash "$ROOT/tests/docker/scenarios/run.sh" || rc=1
  local script
  for script in ufw firewalld connectivity; do
    [ -f "$ROOT/tests/docker/scenarios/$script.sh" ] || continue
    echo "==> $script integration tests"
    bash "$ROOT/tests/docker/scenarios/$script.sh"
    local rcs=$?
    if [ "$rcs" -ne 0 ] && [ "$rcs" -ne 77 ]; then
      rc=1
    fi
  done
  return $rc
}

run_in_container() {
  local runtime="$1" image="ip-allowlist-test:$DISTRO"
  local dockerfile="$ROOT/tests/docker/$DISTRO/Dockerfile"
  if [ ! -f "$dockerfile" ]; then
    echo "==> no Dockerfile for distro $DISTRO ($dockerfile)" >&2
    return 1
  fi
  echo "==> building $image"
  "$runtime" build -t "$image" "$ROOT/tests/docker/$DISTRO" || return 1
  echo "==> running tests in $image"
  "$runtime" run --rm --privileged \
    -v "$ROOT:/src" -w /src \
    "$image" /src/tests/run.sh --local
}

# --- dispatch --------------------------------------------------------------

if [ "$MODE" = "unit" ]; then
  run_unit_local; STATUS=$?
elif [ "$MODE" = "integration" ]; then
  if [ "$LOCAL" = "1" ] || [ "$INSIDE_CONTAINER" = "1" ]; then
    run_integration_local; STATUS=$?
  else
    if runtime="$(find_runtime)"; then
      run_in_container "$runtime"; STATUS=$?
    else
      echo "==> integration tests skipped: no podman/docker available" >&2
      STATUS=77
    fi
  fi
else
  # all
  if [ "$LOCAL" = "1" ] || [ "$INSIDE_CONTAINER" = "1" ]; then
    run_unit_local; U=$?
    run_integration_local; I=$?
    [ "$U" -eq 0 ] || STATUS=1
    [ "$I" -eq 0 ] || STATUS=1
    [ "$U" -eq 77 ] && [ "$I" -eq 77 ] && STATUS=77
  else
    if runtime="$(find_runtime)"; then
      run_in_container "$runtime"; STATUS=$?
    else
      echo "==> no podman/docker available; running unit tests locally" >&2
      run_unit_local; STATUS=$?
    fi
  fi
fi

if [ "$STATUS" -eq 77 ]; then
  echo "==> tests skipped"
  exit 0
fi
exit "$STATUS"
