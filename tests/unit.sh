#!/usr/bin/env bash
# ip-allowlist unit tests. Run with bash 4.4+.
set -uo pipefail

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export IP_ALLOWLIST_ROOT="$ROOT"
LOG_LEVEL=3
LOG_TARGET=stdout

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/source.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/state.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/fail2ban.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/firewall/ufw.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/firewall/firewalld.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "unit tests require bash 4.4+ (found ${BASH_VERSION})" >&2
  exit 77
fi

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    FAILED_NAMES+=("$desc")
    printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$desc" "$expected" "$actual" >&2
  fi
}

assert_ok() {
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    FAILED_NAMES+=("$desc")
    printf 'FAIL: %s (expected success)\n' "$desc" >&2
  fi
}

assert_not_ok() {
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then
    FAIL=$(( FAIL + 1 ))
    FAILED_NAMES+=("$desc")
    printf 'FAIL: %s (expected failure)\n' "$desc" >&2
  else
    PASS=$(( PASS + 1 ))
  fi
}

TMP_STATE="$(mktemp -d)"
trap 'rm -rf -- "$TMP_STATE"' EXIT

# ---------------------------------------------------------------------------
# IPv4 validation
# ---------------------------------------------------------------------------
assert_ok     "ipv4 valid 1.2.3.4"        valid_ipv4_dotted "1.2.3.4"
assert_ok     "ipv4 valid 0.0.0.0"        valid_ipv4_dotted "0.0.0.0"
assert_ok     "ipv4 valid 255.255.255.255" valid_ipv4_dotted "255.255.255.255"
assert_not_ok "ipv4 invalid 256.1.1.1"    valid_ipv4_dotted "256.1.1.1"
assert_not_ok "ipv4 invalid 1.2.3"        valid_ipv4_dotted "1.2.3"
assert_not_ok "ipv4 invalid 1.2.3.4.5"    valid_ipv4_dotted "1.2.3.4.5"
assert_not_ok "ipv4 invalid 01.2.3.4"     valid_ipv4_dotted "01.2.3.4"
assert_not_ok "ipv4 invalid abc"          valid_ipv4_dotted "abc"
assert_not_ok "ipv4 invalid 1.2.3.-1"     valid_ipv4_dotted "1.2.3.-1"

assert_ok     "ipv4 cidr 1.2.3.0/24"      valid_ipv4_cidr "1.2.3.0/24"
assert_ok     "ipv4 cidr 1.2.3.4/32"      valid_ipv4_cidr "1.2.3.4/32"
assert_ok     "ipv4 cidr 0.0.0.0/0"       valid_ipv4_cidr "0.0.0.0/0"
assert_not_ok "ipv4 cidr 1.2.3.0/33"      valid_ipv4_cidr "1.2.3.0/33"
assert_not_ok "ipv4 cidr 1.2.3.0/x"       valid_ipv4_cidr "1.2.3.0/x"
assert_not_ok "ipv4 cidr 1.2.3.0/24/8"    valid_ipv4_cidr "1.2.3.0/24/8"

assert_eq "ipv4 normalize host bits"  "1.2.3.0/24"  "$(ipv4_cidr_normalize 1.2.3.4/24)"
assert_eq "ipv4 normalize bare"       "1.2.3.4/32"  "$(ipv4_cidr_normalize 1.2.3.4)"
assert_eq "ipv4 normalize zero"       "0.0.0.0/0"   "$(ipv4_cidr_normalize 1.2.3.4/0)"
assert_eq "ipv4 int roundtrip"        "3232235777"  "$(ipv4_to_int 192.168.1.1)"
assert_eq "ipv4 int to ip"            "192.168.1.1" "$(int_to_ipv4 3232235777)"

# ---------------------------------------------------------------------------
# IPv4 merging
# ---------------------------------------------------------------------------
merged="$(printf '1.2.3.0/25\n1.2.3.128/25\n' | ipv4_merge_cidrs)"
assert_eq "ipv4 merge two halves" "1.2.3.0/24" "$merged"

merged="$(printf '10.0.0.0/24\n10.0.1.0/24\n' | ipv4_merge_cidrs)"
assert_eq "ipv4 merge adjacent" "10.0.0.0/23" "$merged"

merged="$(printf '10.0.0.0/24\n' | ipv4_merge_cidrs)"
assert_eq "ipv4 merge single" "10.0.0.0/24" "$merged"

merged="$(printf '10.0.0.0/24\n11.0.0.0/24\n' | ipv4_merge_cidrs)"
assert_eq "ipv4 merge disjoint" "$(printf '10.0.0.0/24\n11.0.0.0/24')" "$merged"

# ---------------------------------------------------------------------------
# IPv6 validation and normalization
# ---------------------------------------------------------------------------
assert_ok     "ipv6 valid 2001:db8::1"        valid_ipv6_cidr "2001:db8::1"
assert_ok     "ipv6 valid ::1"                valid_ipv6_cidr "::1"
assert_ok     "ipv6 valid ::/0"               valid_ipv6_cidr "::/0"
assert_ok     "ipv6 valid full"               valid_ipv6_cidr "2001:0db8:0000:0000:0000:0000:0000:0001"
assert_ok     "ipv6 valid 2400:cb00::/32"     valid_ipv6_cidr "2400:cb00::/32"
assert_ok     "ipv6 valid embedded v4"        valid_ipv6_cidr "::ffff:1.2.3.4"
assert_not_ok "ipv6 invalid 2001:db8::1::2"   valid_ipv6_cidr "2001:db8::1::2"
assert_not_ok "ipv6 invalid 2001:db8"         valid_ipv6_cidr "2001:db8"
assert_not_ok "ipv6 invalid 2001:db8::/129"   valid_ipv6_cidr "2001:db8::/129"
assert_not_ok "ipv6 invalid ::gggg"           valid_ipv6_cidr "::gggg"

assert_eq "ipv6 normalize uppercase" "2001:db8::1/128" \
  "$(ipv6_cidr_normalize '2001:0DB8:0000:0000:0000:0000:0000:0001')"
assert_eq "ipv6 normalize compress"  "2001:db8::/128" \
  "$(ipv6_cidr_normalize '2001:0db8:0:0:0:0:0:0')"
assert_eq "ipv6 normalize full"      "1:2:3:4:5:6:7:8/128" \
  "$(ipv6_cidr_normalize '0001:0002:0003:0004:0005:0006:0007:0008')"
assert_eq "ipv6 normalize all zero"  "::/128" "$(ipv6_cidr_normalize '0:0:0:0:0:0:0:0')"
assert_eq "ipv6 normalize bare"      "2001:db8::1/128" "$(ipv6_cidr_normalize '2001:db8::1')"
assert_eq "ipv6 normalize cidr"      "2001:db8::/32" "$(ipv6_cidr_normalize '2001:db8::/32')"

# ---------------------------------------------------------------------------
# Canonicalization pipeline
# ---------------------------------------------------------------------------
canon() {
  canonicalize_stream < <(printf '%s\n' "$@")
}

result="$(canon "1.2.3.4" "1.2.3.4" "5.6.7.8")"
assert_eq "canon dedupe+sort" "$(printf '1.2.3.4/32\n5.6.7.8/32')" "$result"

result="$(canon "1.2.3.0/25" "1.2.3.128/25")"
assert_eq "canon merge" "1.2.3.0/24" "$result"

result="$(canon "2001:db8::1" "2001:0DB8::1")"
assert_eq "canon v6 dedupe" "2001:db8::1/128" "$result"

result="$(canon "1.2.3.4 not-an-ip 5.6.7.8" "2001:db8::/32")"
assert_eq "canon filters invalid" "$(printf '1.2.3.4/32\n5.6.7.8/32\n2001:db8::/32')" "$result"

result="$(canon "1.2.3.4,5.6.7.8,2001:db8::1")"
assert_eq "canon comma separated" "$(printf '1.2.3.4/32\n5.6.7.8/32\n2001:db8::1/128')" "$result"

result="$(canon "not-an-ip at all")"
assert_eq "canon all invalid" "" "$result"

# ---------------------------------------------------------------------------
# fail2ban entry normalization
# ---------------------------------------------------------------------------
assert_eq "f2b normalize bare v4" "1.2.3.4/32"  "$(fail2ban_normalize_entry 1.2.3.4)"
assert_eq "f2b normalize cidr v4" "1.2.3.0/24"  "$(fail2ban_normalize_entry 1.2.3.4/24)"
assert_eq "f2b normalize bare v6" "2001:db8::1/128" "$(fail2ban_normalize_entry 2001:db8::1)"
assert_eq "f2b normalize invalid" "" "$(fail2ban_normalize_entry nonsense)"

# ---------------------------------------------------------------------------
# Config parsing
# ---------------------------------------------------------------------------
cfg="$(mktemp)"
cat >"$cfg" <<'EOF'
# comment
enabled = true
name = test-source
type = http
urls = https://example.com/a, https://example.com/b
min_entries = 3
max_shrink_ratio = 0.25
empty_value =
quoted = "hello world"
EOF
declare -A parsed=()
kv_load_file parsed "$cfg"
assert_eq "kv parse enabled"     "true" "${parsed[enabled]}"
assert_eq "kv parse name"        "test-source" "${parsed[name]}"
assert_eq "kv parse urls"        "https://example.com/a, https://example.com/b" "${parsed[urls]}"
assert_eq "kv parse quoted"      "hello world" "${parsed[quoted]}"
assert_eq "kv parse empty"       "" "${parsed[empty_value]}"

declare -A src=()
source_load_config src "$cfg"
assert_eq "source default enabled" "true" "${src[enabled]}"
assert_eq "source min_entries"     "3" "${src[min_entries]}"
assert_eq "source max_shrink"      "0.25" "${src[max_shrink_ratio]}"

bad="$(mktemp)"
printf 'type=http\nurls=http://x\n' >"$bad"
declare -A bsrc=()
assert_not_ok "source missing name rejected" source_load_config bsrc "$bad"

bad2="$(mktemp)"
printf 'name=x\ntype=bogus\n' >"$bad2"
declare -A bsrc2=()
assert_not_ok "source invalid type rejected" source_load_config bsrc2 "$bad2"

bad3="$(mktemp)"
printf 'name=x\ntype=http\n' >"$bad3"
declare -A bsrc3=()
assert_not_ok "source http missing urls rejected" source_load_config bsrc3 "$bad3"

# ---------------------------------------------------------------------------
# Path and JSON helpers
# ---------------------------------------------------------------------------
assert_eq "resolve absolute" "/a/b" "$(resolve_path /x /a/b)"
assert_eq "resolve relative" "/x/a" "$(resolve_path /x a)"
assert_eq "resolve trailing" "/x/a" "$(resolve_path /x/ a)"
assert_ok   "no spaces"      path_has_no_spaces "/var/lib/ip-allowlist"
assert_not_ok "has spaces"   path_has_no_spaces "/var/lib/my state"
assert_eq "json escape"      'a\"b\\c' "$(json_escape 'a"b\c')"
assert_eq "bool normalize"   "true" "$(normalize_bool yes)"
assert_eq "bool normalize 0" "false" "$(normalize_bool 0)"

# ---------------------------------------------------------------------------
# Due-interval logic
# ---------------------------------------------------------------------------
state_init "$TMP_STATE"
assert_ok "source due when never run" source_is_due "$TMP_STATE" nosuch 900
state_mark_run "nosuch"
assert_not_ok "source not due just run" source_is_due "$TMP_STATE" nosuch 900
assert_ok "source due with zero interval" source_is_due "$TMP_STATE" nosuch 0

# ---------------------------------------------------------------------------
# ufw backend helpers
# ---------------------------------------------------------------------------
f2b_raw="$(mktemp)"
cat >"$f2b_raw" <<'EOF'
Added user rules (see 'ufw status' for running firewall):
ufw allow 22/tcp
ufw allow from 1.2.3.0/24 comment 'ip-allowlist:cloudflare'
ufw allow from 2001:db8::/32 comment 'ip-allowlist:cf6'
ufw allow from 5.6.7.8 comment 'other:managed'
EOF
parsed_ufw="$(mktemp)"
ufw_parse_added "$f2b_raw" "$parsed_ufw"
assert_eq "ufw parse extracts managed rules" \
  "$(printf '1.2.3.0/24|cloudflare\n2001:db8::/32|cf6')" "$(cat "$parsed_ufw")"

ufw_state="$TMP_STATE/ufw-state"
mkdir -p "$ufw_state/current"
printf '1.2.3.0/24\n2001:db8::/32\n' >"$ufw_state/current/cloudflare.ips"
desired_ufw="$(mktemp)"
ufw_build_desired "$ufw_state" "$desired_ufw"
assert_eq "ufw desired set built" \
  "$(printf '1.2.3.0/24|cloudflare\n2001:db8::/32|cloudflare')" "$(cat "$desired_ufw")"

# ---------------------------------------------------------------------------
# firewalld backend helpers
# ---------------------------------------------------------------------------
n1="$(firewalld_set_name cloudflare v4)"
n2="$(firewalld_set_name cloudflare v4)"
n3="$(firewalld_set_name cloudflare v6)"
n4="$(firewalld_set_name other v4)"
assert_eq "firewalld name deterministic" "$n1" "$n2"
assert_eq "firewalld name family specific" "v4-vs-v6" "$([[ "$n1" != "$n3" ]] && echo v4-vs-v6 || echo same)"
assert_eq "firewalld name source specific" "differs" "$([[ "$n1" != "$n4" ]] && echo differs || echo same)"
assert_ok "firewalld name within ipset limit" test "${#n1}" -le 31
assert_eq "firewalld name has prefix" "ia-" "${n1:0:3}"
assert_eq "firewalld family type v4" "inet" "$(firewalld_family_type v4)"
assert_eq "firewalld family type v6" "inet6" "$(firewalld_family_type v6)"
assert_eq "firewalld rule family v4" "ipv4" "$(firewalld_family_rule v4)"
assert_eq "firewalld rule family v6" "ipv6" "$(firewalld_family_rule v6)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "unit: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
