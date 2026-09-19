#!/usr/bin/env bash
# ip-allowlist firewalld backend integration tests.
# Requires firewalld + dbus and NET_ADMIN; skips when unavailable.
set -uo pipefail
export IP_ALLOWLIST_SKIP_UPDATE_CHECK=1

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLI="$ROOT/ip-allowlist"

PASS=0
FAIL=0
FWD_PID=""

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

if ! command -v firewall-cmd >/dev/null 2>&1; then
  echo "firewalld not installed; skipping firewalld integration tests" >&2
  exit 77
fi

start_firewalld() {
  firewall-cmd --state >/dev/null 2>&1 && return 0
  mkdir -p /run/dbus
  dbus-daemon --system --fork >/dev/null 2>&1 || true
  firewalld --nofork >/tmp/ip-allowlist-firewalld.log 2>&1 &
  FWD_PID=$!
  local i
  for i in 1 2 3 4 5 6 7 8; do
    sleep 1
    firewall-cmd --state >/dev/null 2>&1 && return 0
  done
  return 1
}

if ! start_firewalld; then
  echo "firewalld could not be started; skipping" >&2
  if [ -n "$FWD_PID" ]; then kill "$FWD_PID" 2>/dev/null || true; fi
  exit 77
fi

WS="$(mktemp -d)"
cleanup() {
  if [[ -x "$CLI" ]]; then
    "$CLI" --config "$WS/config.conf" cleanup >/dev/null 2>&1 || true
  fi
  firewall-cmd --permanent --get-ipsets 2>/dev/null | grep '^ia-' | while read -r s; do
    firewall-cmd --permanent --delete-ipset="$s" >/dev/null 2>&1 || true
  done
  rm -rf -- "$WS"
  if [ -n "$FWD_PID" ]; then kill "$FWD_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

CONF="$WS/config.conf"
SOURCES="$WS/sources.d"
STATE="$WS/state"
mkdir -p "$SOURCES" "$STATE"
ZONE="$(firewall-cmd --get-default-zone 2>/dev/null)"
[[ -n "$ZONE" ]] || ZONE=public

cat >"$CONF" <<EOF
firewall_backend=firewalld
allow_ports=all
firewalld_zone=$ZONE
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
  pass "firewalld sync exits 0"
else
  fail "firewalld sync exits 0 (see $WS/out1)"
  cat "$WS/out1" >&2
fi
sets="$(firewall-cmd --get-ipsets 2>/dev/null || true)"
assert_contains "firewalld ipset created" "$sets" "ia-"
set_name="$(printf '%s\n' "$sets" | grep '^ia-' | head -n1)"
entries="$(firewall-cmd --ipset="$set_name" --get-entries 2>/dev/null || true)"
assert_contains "firewalld ipset has cidr" "$entries" "1.2.3.0/24"
assert_contains "firewalld ipset has host" "$entries" "5.6.7.8"
rules="$(firewall-cmd --zone="$ZONE" --list-rich-rules 2>/dev/null || true)"
assert_contains "firewalld rich rule references ipset" "$rules" "ipset=\"$set_name\""

# ---------------------------------------------------------------------------
# 2. Change detection updates ipset
# ---------------------------------------------------------------------------
printf '1.2.3.0/24\n9.9.9.9\n' >"$WS/v4.txt"
"$CLI" --config "$CONF" sync >"$WS/out2" 2>&1
set_name="$(firewall-cmd --get-ipsets 2>/dev/null | grep '^ia-' | head -n1)"
entries="$(firewall-cmd --ipset="$set_name" --get-entries 2>/dev/null || true)"
assert_contains "firewalld change applied" "$entries" "9.9.9.9"
assert_not_contains "firewalld stale entry removed" "$entries" "5.6.7.8"

# ---------------------------------------------------------------------------
# 3. Disabled source removes ipset and rich rule
# ---------------------------------------------------------------------------
cat >"$SOURCES/test.conf" <<EOF
enabled=false
name=testv4
type=file
paths=$WS/v4.txt
min_entries=1
EOF
"$CLI" --config "$CONF" sync --allow-empty >"$WS/out3" 2>&1
sets="$(firewall-cmd --get-ipsets 2>/dev/null || true)"
assert_not_contains "firewalld disabled source ipset removed" "$sets" "ia-"
rules="$(firewall-cmd --zone="$ZONE" --list-rich-rules 2>/dev/null || true)"
assert_not_contains "firewalld disabled source rule removed" "$rules" "ipset=\"ia-"

# ---------------------------------------------------------------------------
# 3b. Zone change moves rich rules to the new zone
# ---------------------------------------------------------------------------
ALT_ZONE="ipallowtest"
firewall-cmd --permanent --new-zone="$ALT_ZONE" >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true
cat >"$SOURCES/test.conf" <<EOF
enabled=true
name=testv4
type=file
paths=$WS/v4.txt
min_entries=1
EOF
cat >"$CONF" <<EOF
firewall_backend=firewalld
allow_ports=all
firewalld_zone=$ALT_ZONE
fail2ban_enabled=false
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_level=info
log_target=stdout
update_interval=0
EOF
"$CLI" --config "$CONF" sync >"$WS/out3b" 2>&1
old_rules="$(firewall-cmd --zone="$ZONE" --list-rich-rules 2>/dev/null || true)"
assert_not_contains "firewalld zone change removes old zone rule" "$old_rules" "ipset=\"ia-"
new_rules="$(firewall-cmd --zone="$ALT_ZONE" --list-rich-rules 2>/dev/null || true)"
assert_contains "firewalld zone change adds new zone rule" "$new_rules" "ipset=\"ia-"

# ---------------------------------------------------------------------------
# 3c. Rule parameters: ports and protocol
# ---------------------------------------------------------------------------
cat >"$SOURCES/ports.conf" <<EOF
enabled=true
name=portrule
type=file
paths=$WS/ports.txt
min_entries=1
allow_ports=443,8443
allow_protocol=tcp
EOF
printf '1.2.3.0/24\n' >"$WS/ports.txt"
"$CLI" --config "$CONF" sync >"$WS/out3c" 2>&1
rules="$(firewall-cmd --zone="$ALT_ZONE" --list-rich-rules 2>/dev/null || true)"
assert_contains "firewalld port rule 443" "$rules" 'port port="443" protocol="tcp"'
assert_contains "firewalld port rule 8443" "$rules" 'port port="8443" protocol="tcp"'

# ---------------------------------------------------------------------------
# 4. cleanup removes everything
# ---------------------------------------------------------------------------
cat >"$SOURCES/test.conf" <<EOF
enabled=true
name=testv4
type=file
paths=$WS/v4.txt
min_entries=1
EOF
"$CLI" --config "$CONF" sync >/dev/null 2>&1
"$CLI" --config "$CONF" cleanup >"$WS/out4" 2>&1
sets="$(firewall-cmd --get-ipsets 2>/dev/null || true)"
assert_not_contains "firewalld cleanup removes ipsets" "$sets" "ia-"

# ---------------------------------------------------------------------------
# 5. uninstall removes managed ipsets and rich rules
# ---------------------------------------------------------------------------
cat >"$SOURCES/test.conf" <<EOF
enabled=true
name=testv4
type=file
paths=$WS/v4.txt
min_entries=1
EOF
"$CLI" --config "$CONF" sync >/dev/null 2>&1
before="$(firewall-cmd --permanent --get-ipsets 2>/dev/null | tr ' ' '\n' | grep -c '^ia-' || true)"
if (( before > 0 )); then
  "$CLI" uninstall --yes >"$WS/uninstall.log" 2>&1 || true
  after="$(firewall-cmd --permanent --get-ipsets 2>/dev/null | tr ' ' '\n' | grep -c '^ia-' || true)"
  assert_eq "uninstall removes firewalld ipsets" "0" "$after"
else
  fail "uninstall test setup (no managed ipsets to remove)"
fi

echo ""
echo "firewalld integration: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
