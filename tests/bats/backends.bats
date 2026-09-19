#!/usr/bin/env bash
# bats unit tests: backend rule generation.

setup() {
  load 'helper'
}

@test "nft renders per-source sets, chains and port rules" {
  local d; d="$(mktmp)"
  mkdir -p "$d/current" "$d/rules"
  printf '1.2.3.0/24\n2001:db8::/32\n' >"$d/current/src.ips"
  cat >"$d/rules/src.conf" <<'EOF'
allow_ports=443,8000-8080
allow_protocol=tcp
enable_ipv4=true
enable_ipv6=false
EOF
  NFT_FAMILY=inet
  NFT_TABLE=ip_allowlist
  local out; out="$(mktemp)"
  nft_generate_ruleset "$d" "$out"
  local content; content="$(cat "$out")"
  [[ "$content" == *"set al_src_v4 {"* ]]
  [[ "$content" == *"chain al_src {"* ]]
  [[ "$content" == *"ip saddr @al_src_v4 tcp dport { 443, 8000-8080 } accept"* ]]
  [[ "$content" == *"jump al_src"* ]]
  [[ "$content" != *"al_src_v6"* ]]
  rm -rf "$d" "$out"
}

@test "nft partial batch flushes one source" {
  local d; d="$(mktmp)"
  mkdir -p "$d/current" "$d/rules"
  printf '1.2.3.0/24\n' >"$d/current/a.ips"
  # Values are stored normalized (any = all ports).
  cat >"$d/rules/a.conf" <<'EOF'
allow_ports=any
allow_protocol=any
enable_ipv4=true
enable_ipv6=true
EOF
  NFT_FAMILY=inet
  NFT_TABLE=ip_allowlist
  local batch; batch="$(nft_emit_source_batch "$d" a)"
  [[ "$batch" == *"flush set inet ip_allowlist al_a_v4"* ]]
  [[ "$batch" == *"flush chain inet ip_allowlist al_a"* ]]
  [[ "$batch" == *"add rule inet ip_allowlist al_a ip saddr @al_a_v4 accept"* ]]
  rm -rf "$d"
}

@test "ufw desired and parse use cidr|source|proto|port" {
  local d; d="$(mktmp)"
  mkdir -p "$d/current" "$d/rules"
  printf '1.2.3.0/24\n2001:db8::/32\n' >"$d/current/src.ips"
  cat >"$d/rules/src.conf" <<'EOF'
allow_ports=443
allow_protocol=tcp
enable_ipv4=true
enable_ipv6=false
EOF
  local out; out="$(mktemp)"
  ufw_build_desired "$d" "$out"
  [ "$(cat "$out")" = "1.2.3.0/24|src|tcp|443" ]

  local raw; raw="$(mktemp)"
  cat >"$raw" <<'EOF'
ufw allow from 1.2.3.0/24 comment 'ip-allowlist:plain'
ufw allow from 1.2.3.0/24 to any port 443 proto tcp comment 'ip-allowlist:ported'
EOF
  local parsed; parsed="$(mktemp)"
  ufw_parse_added "$raw" "$parsed"
  [ "$(cat "$parsed")" = "$(printf '1.2.3.0/24|plain|any|any\n1.2.3.0/24|ported|tcp|443')" ]
  rm -rf "$d" "$out" "$raw" "$parsed"
}

@test "firewalld set names and family mapping" {
  local n
  n="$(firewalld_set_name cloudflare v4)"
  [ "$n" = "$(firewalld_set_name cloudflare v4)" ]
  [ "$n" != "$(firewalld_set_name cloudflare v6)" ]
  [ "${n:0:3}" = "ia-" ]
  [ "${#n}" -le 31 ]
  [ "$(firewalld_family_type v4)" = "inet" ]
  [ "$(firewalld_family_type v6)" = "inet6" ]
  [ "$(firewalld_family_rule v4)" = "ipv4" ]
  [ "$(firewalld_family_rule v6)" = "ipv6" ]
}
