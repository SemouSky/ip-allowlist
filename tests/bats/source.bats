#!/usr/bin/env bash
# bats unit tests: IP validation, normalization and canonicalization.

setup() {
  load 'helper'
}

@test "IPv4 validation" {
  valid_ipv4_dotted 1.2.3.4
  valid_ipv4_dotted 255.255.255.255
  run valid_ipv4_dotted 256.1.1.1
  [ "$status" -ne 0 ]
  run valid_ipv4_dotted 01.2.3.4
  [ "$status" -ne 0 ]
  run valid_ipv4_cidr 1.2.3.0/33
  [ "$status" -ne 0 ]
  valid_ipv4_cidr 1.2.3.0/24
}

@test "IPv4 normalization and merge" {
  [ "$(ipv4_cidr_normalize 1.2.3.4/24)" = "1.2.3.0/24" ]
  [ "$(ipv4_cidr_normalize 1.2.3.4)" = "1.2.3.4/32" ]
  [ "$(printf '1.2.3.0/25\n1.2.3.128/25\n' | ipv4_merge_cidrs)" = "1.2.3.0/24" ]
}

@test "IPv6 validation and normalization" {
  valid_ipv6_cidr 2001:db8::/32
  valid_ipv6_cidr ::1
  valid_ipv6_cidr ::ffff:1.2.3.4
  run valid_ipv6_cidr 2001:db8::1::2
  [ "$status" -ne 0 ]
  run valid_ipv6_cidr 2001:db8::/129
  [ "$status" -ne 0 ]
  [ "$(ipv6_cidr_normalize '2001:0DB8:0:0:0:0:0:1')" = "2001:db8::1/128" ]
  [ "$(ipv6_cidr_normalize '0:0:0:0:0:0:0:0')" = "::/128" ]
}

@test "canonicalize dedupes, sorts and merges" {
  local out
  out=$(canonicalize_stream <<<'1.2.3.4
1.2.3.4
5.6.7.8')
  [ "$out" = "$(printf '1.2.3.4/32\n5.6.7.8/32')" ]
  out=$(canonicalize_stream <<<'1.2.3.0/25
1.2.3.128/25')
  [ "$out" = "1.2.3.0/24" ]
}

@test "canonicalize strict rejects invalid entries and lenient ignores them" {
  run bash -c 'source "$IP_ALLOWLIST_ROOT/lib/common.sh"; source "$IP_ALLOWLIST_ROOT/lib/source.sh"; printf "not-an-ip\n" | canonicalize_stream strict'
  [ "$status" -ne 0 ]
  local out
  out=$(printf '1.2.3.4\nnot-an-ip\n' | canonicalize_stream)
  [ "$out" = "1.2.3.4/32" ]
}

@test "count_v4_v6 splits families" {
  local f; f="$(mktemp)"
  printf '1.2.3.0/24\n5.6.7.8/32\n2001:db8::/32\n' >"$f"
  [ "$(count_v4_v6 "$f")" = "2 1" ]
  rm -f "$f"
}

@test "effective hash changes with rule parameters" {
  local d; d="$(mktmp)"
  mkdir -p "$d/current"
  printf '1.2.3.0/24\n' >"$d/current/a.ips"
  local h1 h2
  h1=$(source_effective_hash "$d" a 443 tcp true true)
  h2=$(source_effective_hash "$d" a 8443 tcp true true)
  [ "$h1" != "$h2" ]
  rm -rf "$d"
}
