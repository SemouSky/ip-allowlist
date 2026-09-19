#!/usr/bin/env bash
# Check that every key in the example configs is documented in
# docs/configuration.md (English).
set -uo pipefail

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/docs/configuration.md"
status=0

check_file() {
  local file="$1" key
  [[ -f "$file" ]] || return 0
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if ! grep -q "\`${key}\`" "$DOC"; then
      echo "undocumented config key '$key' (from $file)" >&2
      status=1
    fi
  done < <(sed -n 's/^\([a-z_][a-z0-9_]*\)=.*/\1/p' "$file" | sort -u)
}

check_file "$ROOT/config/config.conf.example"
check_file "$ROOT/config/sources.d/cloudflare.conf.example"
check_file "$ROOT/config/sources.d/example.conf.example"

if (( status == 0 )); then
  echo "config keys documented"
fi
exit "$status"
