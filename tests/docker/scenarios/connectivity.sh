#!/usr/bin/env bash
# ip-allowlist connectivity test (veth + netns).
#
# Verifies on the data path that the generated nft table does not drop traffic
# and contains accept rules for the allow-listed source only.
#
# Default-deny enforcement is explicitly out of scope for this tool (plan
# non-goals): it only adds accept rules and never sets the base-chain policy.
# Note also that in nftables an `accept` verdict is NOT final across base chains
# in different tables, so a separate default-deny chain would drop the traffic
# regardless of this table; hosts that use default-deny must allow the
# allow-listed sources in their own policy.
set -uo pipefail
export IP_ALLOWLIST_SKIP_UPDATE_CHECK=1

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLI="$ROOT/ip-allowlist"

PASS=0
FAIL=0
pass() { PASS=$(( PASS + 1 )); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL - %s\n' "$1" >&2; }

if ! command -v nft >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
  echo "nft/iproute2 not installed; skipping connectivity test" >&2
  exit 77
fi

NS="ialtest-ns"
VH="ialtest-h"
ALLOWED="10.200.0.1"
OTHER="10.200.0.3"
HOST="10.200.0.2"

cleanup() {
  nft delete table inet ip_allowlist 2>/dev/null || true
  ip netns del "$NS" 2>/dev/null || true
  ip link del "$VH" 2>/dev/null || true
}
trap cleanup EXIT

if ! ip netns add "$NS" 2>/dev/null; then
  echo "netns unavailable; skipping connectivity test" >&2
  exit 77
fi
if ! ip link add "$VH" type veth peer name "${VH}-p" 2>/dev/null; then
  echo "veth unavailable; skipping connectivity test" >&2
  exit 77
fi

ip link set "${VH}-p" netns "$NS"
ip addr add "$HOST/24" dev "$VH"
ip link set "$VH" up
ip netns exec "$NS" ip addr add "$ALLOWED/24" dev "${VH}-p"
ip netns exec "$NS" ip addr add "$OTHER/24" dev "${VH}-p"
ip netns exec "$NS" ip link set "${VH}-p" up
ip netns exec "$NS" ip link set lo up

WS="$(mktemp -d)"
mkdir -p "$WS/sources.d"
printf '%s/32\n' "$ALLOWED" >"$WS/allow.txt"
cat >"$WS/sources.d/probe.conf" <<EOF
enabled=true
name=probe
type=file
paths=$WS/allow.txt
min_entries=1
EOF
cat >"$WS/config.conf" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=false
state_dir=$WS/state
sources_dir=$WS/sources.d
log_target=stdout
update_interval=0
EOF

if "$CLI" --config "$WS/config.conf" sync >"$WS/out" 2>&1; then
  pass "connectivity: allow-list applied"
else
  fail "connectivity: allow-list applied (see $WS/out)"
  cat "$WS/out" >&2
fi

rules="$(nft list table inet ip_allowlist 2>/dev/null || true)"
if [[ "$rules" == *"ip saddr @al_probe_v4 accept"* ]]; then
  pass "connectivity: accept rule generated"
else
  fail "connectivity: accept rule generated"
fi
if [[ "$rules" == *"$ALLOWED"* ]]; then
  pass "connectivity: allow-listed source present in the set"
else
  fail "connectivity: allow-listed source present in the set"
fi
if [[ "$rules" != *"$OTHER"* ]]; then
  pass "connectivity: unlisted source absent from the set"
else
  fail "connectivity: unlisted source absent from the set"
fi

if ip netns exec "$NS" ping -c1 -W2 -I "$ALLOWED" "$HOST" >/dev/null 2>&1; then
  pass "connectivity: allow-listed source reaches the host"
else
  fail "connectivity: allow-listed source reaches the host"
fi

# The tool never drops; this confirms it does not block unlisted sources either
# (host-side policy is the operator's responsibility).
if ip netns exec "$NS" ping -c1 -W2 -I "$OTHER" "$HOST" >/dev/null 2>&1; then
  pass "connectivity: table does not drop unlisted traffic"
else
  fail "connectivity: table does not drop unlisted traffic"
fi

"$CLI" --config "$WS/config.conf" cleanup >/dev/null 2>&1
rm -rf -- "$WS"

echo ""
echo "connectivity integration: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
