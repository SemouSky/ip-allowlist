#!/usr/bin/env bash
# bats unit tests: shared helpers, config parsing, durations.

setup() {
  load 'helper'
}

@test "kv parses values, quotes and comments" {
  local f; f="$(mktemp)"
  cat >"$f" <<'EOF'
# comment
enabled = true
name = cloudflare
quoted = "hello world"
empty =
EOF
  declare -A p=()
  kv_load_file p "$f"
  [ "${p[enabled]}" = "true" ]
  [ "${p[name]}" = "cloudflare" ]
  [ "${p[quoted]}" = "hello world" ]
  [ "${p[empty]}" = "" ]
  rm -f "$f"
}

@test "kv strips inline comments and keeps quoted hashes" {
  local f; f="$(mktemp)"
  cat >"$f" <<'EOF'
a = true          # trailing comment
b = "x#y"         # quoted keeps the hash
c = 443#no-space
d = 'q' # quoted single
EOF
  declare -A p=()
  kv_load_file p "$f"
  [ "${p[a]}" = "true" ]
  [ "${p[b]}" = "x#y" ]
  [ "${p[c]}" = "443" ]
  [ "${p[d]}" = "q" ]
  rm -f "$f"
}

@test "kv rejects malformed lines" {
  local f; f="$(mktemp)"
  printf 'this is not kv\n' >"$f"
  run kv_load_file p "$f"
  [ "$status" -ne 0 ]
  rm -f "$f"
}

@test "kv_reject_unknown rejects unlisted keys" {
  local f; f="$(mktemp)"
  printf 'name=a\nbogus=1\n' >"$f"
  declare -A p=()
  kv_load_file p "$f"
  run kv_reject_unknown p "$f" name
  [ "$status" -ne 0 ]
  rm -f "$f"
}

@test "durations parse to seconds" {
  [ "$(parse_duration 30)" = "30" ]
  [ "$(parse_duration 15m)" = "900" ]
  [ "$(parse_duration 2h)" = "7200" ]
  [ "$(parse_duration 1d)" = "86400" ]
  [ "$(parse_duration 1w)" = "604800" ]
  run parse_duration 1x
  [ "$status" -ne 0 ]
}

@test "upgrade asset urls cover both names and the source archive" {
  local urls
  urls="$(upgrade_asset_urls SemouSky/ip-allowlist v1.2.3)"
  [[ "$urls" == *"/releases/download/v1.2.3/ip-allowlist-v1.2.3.tar.gz"* ]]
  [[ "$urls" == *"/releases/download/v1.2.3/ip-allowlist-1.2.3.tar.gz"* ]]
  [[ "$urls" == *"/archive/refs/tags/v1.2.3.tar.gz"* ]]
  # the v-prefixed asset is preferred (current release naming)
  local first
  first="$(printf '%s\n' "$urls" | head -n1)"
  [[ "$first" == *"ip-allowlist-v1.2.3.tar.gz" ]]
}

@test "json_escape and resolve_path" {
  [ "$(json_escape 'a"b\c')" = 'a\"b\\c' ]
  [ "$(resolve_path /x /a/b)" = "/a/b" ]
  [ "$(resolve_path /x a)" = "/x/a" ]
  [ "$(resolve_path /x/ a)" = "/x/a" ]
}

@test "booleans normalize and paths with spaces are detected" {
  [ "$(normalize_bool yes)" = "true" ]
  [ "$(normalize_bool 0)" = "false" ]
  path_has_no_spaces "/var/lib/ip-allowlist"
  run path_has_no_spaces "/var/lib/my state"
  [ "$status" -ne 0 ]
}
