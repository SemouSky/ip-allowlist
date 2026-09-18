#!/usr/bin/env bash
# ip-allowlist lint. Runs shellcheck (if available) and bash syntax checks
# using a bash 4.4+ interpreter when one can be found.
set -uo pipefail

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

SCRIPTS=(
  "$ROOT/ip-allowlist"
  "$ROOT/lib/common.sh"
  "$ROOT/lib/source.sh"
  "$ROOT/lib/state.sh"
  "$ROOT/lib/fail2ban.sh"
  "$ROOT/lib/firewall/nft.sh"
  "$ROOT/lib/firewall/ufw.sh"
  "$ROOT/lib/firewall/firewalld.sh"
  "$ROOT/install.sh"
  "$ROOT/uninstall.sh"
  "$ROOT/tests/run.sh"
  "$ROOT/tests/lint.sh"
  "$ROOT/tests/unit.sh"
  "$ROOT/tests/integration/run.sh"
  "$ROOT/tests/integration/ufw.sh"
  "$ROOT/tests/integration/firewalld.sh"
)

find_bash4() {
  local candidate
  for candidate in "${BASH:-}" /usr/local/bin/bash /opt/homebrew/bin/bash /bin/bash bash; do
    [ -n "$candidate" ] || continue
    if command -v "$candidate" >/dev/null 2>&1; then
      # shellcheck disable=SC2016
      if "$candidate" -c '[[ ${BASH_VERSINFO[0]} -gt 4 || ( ${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -ge 4 ) ]]' 2>/dev/null; then
        printf '%s' "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

STATUS=0

if command -v shellcheck >/dev/null 2>&1; then
  echo "==> shellcheck"
  if ! shellcheck "${SCRIPTS[@]}"; then
    STATUS=1
  fi
else
  echo "==> shellcheck not found; skipping"
fi

if BASH4="$(find_bash4)"; then
  echo "==> bash syntax check ($BASH4)"
  for f in "${SCRIPTS[@]}"; do
    if ! "$BASH4" -n "$f"; then
      echo "syntax error: $f" >&2
      STATUS=1
    fi
  done
else
  echo "==> bash 4.4+ not found; skipping syntax check (run inside the test container)"
fi

if [ "$STATUS" -eq 0 ]; then
  echo "lint passed"
else
  echo "lint failed" >&2
fi
exit "$STATUS"
