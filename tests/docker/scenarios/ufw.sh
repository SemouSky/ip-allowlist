#!/usr/bin/env bash
# ip-allowlist ufw backend integration tests. Run as root with NET_ADMIN.
set -uo pipefail
export IP_ALLOWLIST_SKIP_UPDATE_CHECK=1

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLI="$ROOT/ip-allowlist"

PASS=0
FAIL=0

pass() { PASS=$(( PASS + 1 )); printf 'ok   - %s\n' "$1"; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}
fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL - %s\n' "$1" >&2; }

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else
    fail "$desc (missing '$needle')"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else
    fail "$desc (unexpected '$needle')"
  fi
}

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw not installed; skipping ufw integration tests" >&2
  exit 77
fi
if ! ufw --force enable >/dev/null 2>&1; then
  echo "ufw cannot be enabled (needs NET_ADMIN/iptables); skipping" >&2
  exit 77
fi

WS="$(mktemp -d)"
cleanup() {
  ufw --force reset >/dev/null 2>&1 || true
  rm -rf -- "$WS"
}
trap cleanup EXIT

CONF="$WS/config.conf"
SOURCES="$WS/sources.d"
STATE="$WS/state"
mkdir -p "$SOURCES" "$STATE"

cat >"$CONF" <<EOF
firewall_backend=ufw
allow_ports=all
fail2ban_enabled=false
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_level=info
log_target=stdout
update_interval=0
EOF

cat >"$SOURCES/test.conf" <<EOF
enabled=true
name=testv4
type=file
paths=$WS/v4.txt
min_entries=1
EOF

printf '1.2.3.0/24\n5.6.7.8\n' >"$WS/v4.txt"

# ---------------------------------------------------------------------------
# 1. Initial apply
# ---------------------------------------------------------------------------
if "$CLI" --config "$CONF" sync >"$WS/out1" 2>&1; then
  pass "ufw sync exits 0"
else
  fail "ufw sync exits 0 (see $WS/out1)"
  cat "$WS/out1" >&2
fi
added="$(ufw show added 2>/dev/null || true)"
assert_contains "ufw rule for cidr added" "$added" "ip-allowlist:testv4"
assert_contains "ufw rule cidr correct" "$added" "from 1.2.3.0/24"
assert_contains "ufw rule host correct" "$added" "from 5.6.7.8"

# ---------------------------------------------------------------------------
# 2. Change detection removes stale rule
# ---------------------------------------------------------------------------
printf '1.2.3.0/24\n9.9.9.9\n' >"$WS/v4.txt"
"$CLI" --config "$CONF" sync >"$WS/out2" 2>&1
added="$(ufw show added 2>/dev/null || true)"
assert_contains "ufw change applied" "$added" "from 9.9.9.9"
assert_not_contains "ufw stale rule removed" "$added" "from 5.6.7.8"

# ---------------------------------------------------------------------------
# 2b. Rule parameters: ports and protocol
# ---------------------------------------------------------------------------
cat >"$SOURCES/ports.conf" <<EOF
enabled=true
name=portrule
type=file
paths=$WS/ports.txt
min_entries=1
allow_ports=443
allow_protocol=tcp+udp
EOF
printf '1.2.3.0/24\n' >"$WS/ports.txt"
"$CLI" --config "$CONF" sync >"$WS/out2b" 2>&1
added="$(ufw show added 2>/dev/null || true)"
assert_contains "ufw port rule tcp" "$added" "to any port 443 proto tcp comment 'ip-allowlist:portrule'"
assert_contains "ufw port rule udp" "$added" "to any port 443 proto udp comment 'ip-allowlist:portrule'"
assert_not_contains "ufw portrule is not all-port" "$added" "from 1.2.3.0/24 comment 'ip-allowlist:portrule'"

# ---------------------------------------------------------------------------
# 3. Re-run is idempotent
# ---------------------------------------------------------------------------
before="$(ufw show added 2>/dev/null || true)"
"$CLI" --config "$CONF" sync >"$WS/out3" 2>&1
after="$(ufw show added 2>/dev/null || true)"
if [[ "$before" == "$after" ]]; then
  pass "ufw re-run is idempotent"
else
  fail "ufw re-run is idempotent"
fi

# ---------------------------------------------------------------------------
# 4. Disabled source removes rules
# ---------------------------------------------------------------------------
cat >"$SOURCES/test.conf" <<EOF
enabled=false
name=testv4
type=file
paths=$WS/v4.txt
min_entries=1
EOF
"$CLI" --config "$CONF" sync >"$WS/out4" 2>&1
added="$(ufw show added 2>/dev/null || true)"
assert_not_contains "ufw disabled source removed" "$added" "ip-allowlist:testv4"

# ---------------------------------------------------------------------------
# 5. Conflict detection
# ---------------------------------------------------------------------------
cat >"$CONF" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=false
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_level=info
log_target=stdout
update_interval=0
EOF
if "$CLI" --config "$CONF" sync >"$WS/out5" 2>&1; then
  fail "mismatched backend rejected while ufw active"
else
  pass "mismatched backend rejected while ufw active"
fi
assert_contains "conflict message mentions ufw" "$(cat "$WS/out5")" "ufw is active"

# ---------------------------------------------------------------------------
# 6. cleanup removes managed rules
# ---------------------------------------------------------------------------
cat >"$CONF" <<EOF
firewall_backend=ufw
allow_ports=all
fail2ban_enabled=false
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_level=info
log_target=stdout
update_interval=0
EOF
cat >"$SOURCES/test.conf" <<EOF
enabled=true
name=testv4
type=file
paths=$WS/v4.txt
min_entries=1
EOF
"$CLI" --config "$CONF" sync >/dev/null 2>&1
"$CLI" --config "$CONF" cleanup >"$WS/out6" 2>&1
added="$(ufw show added 2>/dev/null || true)"
assert_not_contains "ufw cleanup removes rules" "$added" "ip-allowlist:testv4"

# ---------------------------------------------------------------------------
# 7. uninstall removes managed ufw rules
# ---------------------------------------------------------------------------
cat >"$SOURCES/test.conf" <<EOF
enabled=true
name=testv4
type=file
paths=$WS/v4.txt
min_entries=1
EOF
"$CLI" --config "$CONF" sync >/dev/null 2>&1
before="$(ufw show added 2>/dev/null | grep -c "ip-allowlist:" || true)"
if (( before > 0 )); then
  "$CLI" uninstall --yes >"$WS/uninstall.log" 2>&1 || true
  after="$(ufw show added 2>/dev/null | grep -c "ip-allowlist:" || true)"
  assert_eq "uninstall removes managed ufw rules" "0" "$after"
else
  fail "uninstall test setup (no managed rules to remove)"
fi

echo ""
echo "ufw integration: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
