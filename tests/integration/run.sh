#!/usr/bin/env bash
# ip-allowlist integration tests. Run as root inside a container.
set -uo pipefail
export IP_ALLOWLIST_SKIP_UPDATE_CHECK=1

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/ip-allowlist"

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$(( PASS + 1 )); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL - %s\n' "$1" >&2; }
skip() { SKIP=$(( SKIP + 1 )); printf 'skip - %s\n' "$1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

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

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v nft >/dev/null 2>&1; then
  echo "nft not installed; cannot run integration tests" >&2
  exit 77
fi
if ! nft list ruleset >/dev/null 2>&1; then
  echo "nft requires CAP_NET_ADMIN; run container with --privileged" >&2
  exit 77
fi

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------
WS="$(mktemp -d)"
cleanup() {
  nft delete table inet ip_allowlist 2>/dev/null || true
  rm -rf -- "$WS"
}
trap cleanup EXIT

CONF="$WS/config.conf"
SOURCES="$WS/sources.d"
STATE="$WS/state"
FAIL2BAN_DIR="$WS/fail2ban"
mkdir -p "$SOURCES" "$STATE" "$FAIL2BAN_DIR"

cat >"$CONF" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=false
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_level=debug
log_target=stdout
update_interval=0
EOF

cat >"$SOURCES/v4.conf" <<EOF
enabled=true
name=v4src
type=file
paths=$WS/v4.txt
min_entries=1
max_shrink_ratio=0.9
EOF

cat >"$SOURCES/v6.conf" <<EOF
enabled=true
name=v6src
type=file
paths=$WS/v6.txt
min_entries=1
EOF

printf '1.2.3.0/24\n5.6.7.8\n' >"$WS/v4.txt"
printf '2001:db8::/32\n' >"$WS/v6.txt"

# ---------------------------------------------------------------------------
# 1. Initial sync
# ---------------------------------------------------------------------------
if "$CLI" --config "$CONF" sync >"$WS/out1" 2>&1; then
  pass "initial sync exits 0"
else
  fail "initial sync exits 0 (see $WS/out1)"
  cat "$WS/out1" >&2
fi

rules="$(nft list table inet ip_allowlist 2>/dev/null || true)"
assert_contains "nft table contains v4 cidr" "$rules" "1.2.3.0/24"
assert_contains "nft table contains v4 host" "$rules" "5.6.7.8"
assert_contains "nft table contains v6 cidr" "$rules" "2001:db8::/32"
assert_contains "nft chain accepts ip saddr" "$rules" "ip saddr @al_v4src_v4 accept"
assert_contains "nft chain accepts ip6 saddr" "$rules" "ip6 saddr @al_v6src_v6 accept"

if [[ -f "$STATE/current/v4src.ips" ]]; then pass "state current file written"; else fail "state current file written"; fi
if [[ -f "$STATE/applied/v4src.hash" ]]; then pass "applied hash written"; else fail "applied hash written"; fi
if grep -Fxq "v4src" "$STATE/sources.known" 2>/dev/null; then
  pass "known list records applied source"
else
  fail "known list records applied source"
fi

# ---------------------------------------------------------------------------
# 2. Idempotent re-run
# ---------------------------------------------------------------------------
before="$(nft list table inet ip_allowlist 2>/dev/null || true)"
"$CLI" --config "$CONF" sync >"$WS/out2" 2>&1
after="$(nft list table inet ip_allowlist 2>/dev/null || true)"
assert_eq "re-run is idempotent" "$before" "$after"

# ---------------------------------------------------------------------------
# 3. Change detection
# ---------------------------------------------------------------------------
printf '1.2.3.0/24\n9.9.9.9\n' >"$WS/v4.txt"
"$CLI" --config "$CONF" sync >"$WS/out3" 2>&1
assert_contains "nft applies changed sources incrementally" "$(cat "$WS/out3")" "nft: partial apply"
rules="$(nft list table inet ip_allowlist 2>/dev/null || true)"
assert_contains "change applied (9.9.9.9)" "$rules" "9.9.9.9"
assert_not_contains "removed entry gone (5.6.7.8)" "$rules" "5.6.7.8"

# check reports no pending change now
if "$CLI" --config "$CONF" check >"$WS/out3c" 2>&1; then
  assert_contains "check reports up to date" "$(cat "$WS/out3c")" "up to date"
else
  fail "check exits 0"
fi

"$CLI" --config "$CONF" check --json >"$WS/out3j" 2>&1
assert_contains "check json reports no change" "$(cat "$WS/out3j")" '"changed":false'

# introduce a change, check should detect without applying
printf '1.2.3.0/24\n9.9.9.9\n8.8.8.8\n' >"$WS/v4.txt"
"$CLI" --config "$CONF" check >"$WS/out3d" 2>&1
assert_contains "check detects pending change" "$(cat "$WS/out3d")" "would change"
rules="$(nft list table inet ip_allowlist 2>/dev/null || true)"
assert_not_contains "check did not apply change" "$rules" "8.8.8.8"

# ---------------------------------------------------------------------------
# 4. Strict parsing rejects invalid source data; valid data merges
# ---------------------------------------------------------------------------
before="$(cat "$STATE/current/v4src.ips" 2>/dev/null || true)"
printf '1.2.3.0/25\n1.2.3.128/25\nnot-an-ip\n999.1.1.1\n' >"$WS/v4.txt"
if "$CLI" --config "$CONF" sync >"$WS/out4" 2>&1; then
  fail "invalid source data is rejected"
else
  pass "invalid source data is rejected"
fi
after="$(cat "$STATE/current/v4src.ips" 2>/dev/null || true)"
assert_eq "invalid data keeps previous values" "$before" "$after"

printf '1.2.3.0/25\n1.2.3.128/25\n' >"$WS/v4.txt"
"$CLI" --config "$CONF" sync >"$WS/out4b" 2>&1
assert_eq "ipv4 halves merge" "1.2.3.0/24" "$(cat "$STATE/current/v4src.ips" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 5. min_entries enforcement
# ---------------------------------------------------------------------------
printf '1.2.3.4/32\n' >"$WS/v4.txt"
cat >"$SOURCES/v4.conf" <<EOF
enabled=true
name=v4src
type=file
paths=$WS/v4.txt
min_entries=5
EOF
if "$CLI" --config "$CONF" sync >"$WS/out5" 2>&1; then
  fail "min_entries violation exits non-zero"
else
  rc=$?
  pass "min_entries violation exits non-zero"
  assert_eq "min_entries failure exit code is 2" "2" "$rc"
fi
assert_contains "min_entries error logged" "$(cat "$WS/out5")" "min_entries"
if [[ ! -f "$STATE/in-progress" ]]; then
  pass "failed source does not leave in-progress marker"
else
  fail "failed source does not leave in-progress marker"
fi

# Restore a valid config for later tests.
cat >"$SOURCES/v4.conf" <<EOF
enabled=true
name=v4src
type=file
paths=$WS/v4.txt
min_entries=1
EOF
printf '1.2.3.0/24\n' >"$WS/v4.txt"
"$CLI" --config "$CONF" sync >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 5b. Firewall-safe name collision is rejected
# ---------------------------------------------------------------------------
cat >"$SOURCES/a-b.conf" <<EOF
enabled=true
name=a-b
type=file
paths=$WS/v4.txt
min_entries=1
EOF
cat >"$SOURCES/a_b.conf" <<EOF
enabled=true
name=a_b
type=file
paths=$WS/v4.txt
min_entries=1
EOF
if "$CLI" --config "$CONF" sync >"$WS/out5b" 2>&1; then
  fail "sanitized name collision exits non-zero"
else
  pass "sanitized name collision exits non-zero"
fi
assert_contains "collision error names the sources" "$(cat "$WS/out5b")" "collides"
rm -f "$SOURCES/a-b.conf" "$SOURCES/a_b.conf"

# ---------------------------------------------------------------------------
# 6. status and sources commands
# ---------------------------------------------------------------------------
"$CLI" --config "$CONF" sources >"$WS/out6" 2>&1
assert_contains "sources lists v4src" "$(cat "$WS/out6")" "v4src"
assert_contains "sources lists v6src" "$(cat "$WS/out6")" "v6src"

"$CLI" --config "$CONF" status >"$WS/out7" 2>&1
assert_contains "status shows backend" "$(cat "$WS/out7")" "nft"

"$CLI" --config "$CONF" status --json >"$WS/out8" 2>&1
assert_contains "status json has version" "$(cat "$WS/out8")" '"version"'
assert_contains "status json has source" "$(cat "$WS/out8")" '"v4src"'
assert_contains "status shows verify" "$(cat "$WS/out7")" "verify:"
assert_contains "status shows fail2ban" "$(cat "$WS/out7")" "fail2ban:"
assert_contains "status shows desired hash" "$(cat "$WS/out7")" "desired:"
assert_contains "status json has verify" "$(cat "$WS/out8")" '"verify"'
assert_contains "status json has latest version" "$(cat "$WS/out8")" '"latest_version"'

"$CLI" --config "$CONF" status --check >"$WS/out9" 2>&1
assert_eq "status --check OK exit code" "0" "$?"

# ---------------------------------------------------------------------------
# 7. Disabled source removed from firewall
# ---------------------------------------------------------------------------
cat >"$SOURCES/v6.conf" <<EOF
enabled=false
name=v6src
type=file
paths=$WS/v6.txt
min_entries=1
EOF
"$CLI" --config "$CONF" sync >"$WS/out10" 2>&1
rules="$(nft list table inet ip_allowlist 2>/dev/null || true)"
assert_not_contains "disabled source not in firewall" "$rules" "2001:db8::/32"
if grep -Fxq "v6src" "$STATE/sources.known" 2>/dev/null; then
  fail "disabled source removed from known list"
else
  pass "disabled source removed from known list"
fi

# ---------------------------------------------------------------------------
# 8. fail2ban union drop-in
# ---------------------------------------------------------------------------
cat >"$CONF" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=true
fail2ban_ignoreip_file=$FAIL2BAN_DIR/ip-allowlist.conf
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_level=debug
log_target=stdout
update_interval=0
EOF

cat >"$WS/jail.local" <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 10.0.0.1
EOF

FAIL2BAN_JAIL_CONF="$WS/jail.conf" \
FAIL2BAN_JAIL_LOCAL="$WS/jail.local" \
FAIL2BAN_JAIL_D="$WS/jail.d" \
FAIL2BAN_RELOAD=false \
  "$CLI" --config "$CONF" sync >"$WS/out11" 2>&1

dropin="$(cat "$FAIL2BAN_DIR/ip-allowlist.conf" 2>/dev/null || true)"
assert_contains "fail2ban dropin has source ip" "$dropin" "1.2.3.0/24"
assert_contains "fail2ban dropin has user ip" "$dropin" "127.0.0.0/8"
assert_contains "fail2ban dropin has user host" "$dropin" "10.0.0.1/32"
assert_contains "fail2ban dropin is DEFAULT" "$dropin" "[DEFAULT]"

# ---------------------------------------------------------------------------
# 9. Empty union removes drop-in
# ---------------------------------------------------------------------------
cat >"$SOURCES/v4.conf" <<EOF
enabled=false
name=v4src
type=file
paths=$WS/v4.txt
min_entries=1
EOF
printf '\n' >"$WS/empty.txt"

cat >"$CONF" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=true
fail2ban_ignoreip_file=$FAIL2BAN_DIR/ip-allowlist.conf
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_level=debug
log_target=stdout
update_interval=0
EOF

FAIL2BAN_JAIL_CONF="$WS/nonexistent.conf" \
FAIL2BAN_JAIL_LOCAL="$WS/nonexistent.local" \
FAIL2BAN_JAIL_D="$WS/nodir" \
FAIL2BAN_RELOAD=false \
  "$CLI" --config "$CONF" sync --allow-empty >"$WS/out12" 2>&1

if [[ ! -f "$FAIL2BAN_DIR/ip-allowlist.conf" ]]; then
  pass "empty union removes drop-in"
else
  fail "empty union removes drop-in"
fi

# fail2ban enabled but its drop-in directory missing: warn and skip, keep exit 0
cat >"$CONF" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=true
fail2ban_ignoreip_file=$WS/no-such-fail2ban-dir/ip-allowlist.conf
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_level=debug
log_target=stdout
update_interval=0
EOF
if "$CLI" --config "$CONF" sync --allow-empty >"$WS/out-missing-f2b" 2>&1; then
  pass "missing fail2ban directory does not fail sync"
else
  fail "missing fail2ban directory does not fail sync (see $WS/out-missing-f2b)"
fi
assert_contains "missing fail2ban directory is reported" "$(cat "$WS/out-missing-f2b")" "missing"

# ---------------------------------------------------------------------------
# 10. version command
# ---------------------------------------------------------------------------
version_out="$("$CLI" version 2>&1)"
assert_contains "version output" "$version_out" "ip-allowlist"

# ---------------------------------------------------------------------------
# 10c. schema_version validation and syslog logging target
# ---------------------------------------------------------------------------
cat >"$WS/schema.conf" <<EOF
schema_version=99
firewall_backend=nft
allow_ports=all
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_target=stdout
EOF
if "$CLI" --config "$WS/schema.conf" sources >"$WS/out13" 2>&1; then
  fail "newer schema_version rejected"
else
  pass "newer schema_version rejected"
fi
assert_contains "schema error mentions supported version" "$(cat "$WS/out13")" "newer than supported"

cat >"$WS/syslog.conf" <<EOF
schema_version=1
firewall_backend=nft
allow_ports=all
state_dir=$STATE
sources_dir=$SOURCES
log_file=$WS/log.txt
log_target=syslog
EOF
if "$CLI" --config "$WS/syslog.conf" sources >"$WS/out14" 2>&1; then
  pass "syslog logging target runs"
else
  fail "syslog logging target runs"
fi
assert_contains "syslog target still lists sources" "$(cat "$WS/out14")" "v4src"

# ---------------------------------------------------------------------------
# 10b. cleanup command removes firewall objects
# ---------------------------------------------------------------------------
"$CLI" --config "$CONF" cleanup >"$WS/out12b" 2>&1
if nft list table inet ip_allowlist >/dev/null 2>&1; then
  fail "cleanup removes nft table"
else
  pass "cleanup removes nft table"
fi

# Re-enable a source and confirm sync rebuilds the allow-list after cleanup.
cat >"$SOURCES/v4.conf" <<EOF
enabled=true
name=v4src
type=file
paths=$WS/v4.txt
min_entries=1
EOF
"$CLI" --config "$CONF" sync >"$WS/out12c" 2>&1
if nft list table inet ip_allowlist >/dev/null 2>&1; then
  pass "sync restores allow-list after cleanup"
else
  fail "sync restores allow-list after cleanup"
fi

# ---------------------------------------------------------------------------
# 10d. backend switch cleanup and fail2ban drop-in path change
# ---------------------------------------------------------------------------
SW="$WS/switch"
mkdir -p "$SW/sources.d"
printf '1.2.3.0/24\n' >"$SW/v4.txt"
cat >"$SW/sources.d/switchsrc.conf" <<EOF
enabled=true
name=switchsrc
type=file
paths=$SW/v4.txt
min_entries=1
EOF

mk_switch_conf() {
  cat >"$SW/$1.conf" <<EOF
firewall_backend=$2
fail2ban_enabled=false
state_dir=$SW/state
sources_dir=$SW/sources.d
log_file=$SW/log
log_target=stdout
update_interval=0
EOF
}

mk_switch_conf nft nft
"$CLI" --config "$SW/nft.conf" sync >"$SW/out-nft" 2>&1
if nft list table inet ip_allowlist >/dev/null 2>&1; then
  pass "switch: nft table applied"
else
  fail "switch: nft table applied"
fi

if command -v ufw >/dev/null 2>&1; then
  mk_switch_conf ufw ufw
  "$CLI" --config "$SW/ufw.conf" sync >"$SW/out-ufw" 2>&1
  if nft list table inet ip_allowlist >/dev/null 2>&1; then
    fail "backend switch removes old nft table"
  else
    pass "backend switch removes old nft table"
  fi
  assert_contains "backend switch applies ufw rules" "$(ufw show added 2>/dev/null || true)" "ip-allowlist:switchsrc"
  "$CLI" --config "$SW/ufw.conf" cleanup >/dev/null 2>&1
else
  skip "backend switch test (no ufw)"
fi

FB="$WS/fail2ban-switch"
mkdir -p "$FB"
mk_fb_conf() {
  cat >"$FB/$1.conf" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=true
fail2ban_ignoreip_file=$FB/$2.conf
state_dir=$FB/state
sources_dir=$SW/sources.d
log_file=$FB/log
log_target=stdout
update_interval=0
EOF
}
mk_fb_conf first old
FAIL2BAN_RELOAD=false "$CLI" --config "$FB/first.conf" sync >"$FB/out1" 2>&1
if [[ -f "$FB/old.conf" ]]; then
  pass "fail2ban drop-in written at first path"
else
  fail "fail2ban drop-in written at first path"
fi
mk_fb_conf second new
FAIL2BAN_RELOAD=false "$CLI" --config "$FB/second.conf" sync >"$FB/out2" 2>&1
if [[ ! -f "$FB/old.conf" && -f "$FB/new.conf" ]]; then
  pass "fail2ban drop-in path change removes old drop-in"
else
  fail "fail2ban drop-in path change removes old drop-in"
fi
nft delete table inet ip_allowlist 2>/dev/null || true

# ---------------------------------------------------------------------------
# 10e. rule parameters: ports, protocol, address families (nft)
# ---------------------------------------------------------------------------
RP="$WS/ruleparams"
mkdir -p "$RP/sources.d"
printf '1.2.3.0/24\n2001:db8::/32\n' >"$RP/v.txt"
cat >"$RP/sources.d/rp.conf" <<EOF
enabled=true
name=rp
type=file
paths=$RP/v.txt
min_entries=1
allow_ports=443
allow_protocol=tcp
enable_ipv6=false
EOF
cat >"$RP/sources.d/rp2.conf" <<EOF
enabled=true
name=rp2
type=file
paths=$RP/v.txt
min_entries=1
allow_ports=443
allow_protocol=udp
enable_ipv4=false
EOF
cat >"$RP/config.conf" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=false
state_dir=$RP/state
sources_dir=$RP/sources.d
log_file=$RP/log
log_target=stdout
update_interval=0
EOF
"$CLI" --config "$RP/config.conf" sync >"$RP/out" 2>&1
rules="$(nft list table inet ip_allowlist 2>/dev/null || true)"
assert_contains "nft limited ports rule" "$rules" "ip saddr @al_rp_v4 tcp dport 443 accept"
assert_not_contains "nft disabled ipv6 has no v6 set" "$rules" "al_rp_v6"
assert_contains "nft udp port rule" "$rules" "ip6 saddr @al_rp2_v6 udp dport 443 accept"
assert_not_contains "nft disabled ipv4 has no v4 set" "$rules" "al_rp2_v4"

# Changing only allow_ports must rebuild even though the source data is unchanged.
sed -i 's/^allow_ports=443$/allow_ports=443,8443/' "$RP/sources.d/rp.conf"
"$CLI" --config "$RP/config.conf" sync >"$RP/out2" 2>&1
rules="$(nft list table inet ip_allowlist 2>/dev/null || true)"
assert_contains "nft port parameter change rebuilds" "$rules" "tcp dport { 443, 8443 } accept"
"$CLI" --config "$RP/config.conf" cleanup >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 10f. snapshot retention and fail2ban merge_existing
# ---------------------------------------------------------------------------
RN="$WS/retention"
mkdir -p "$RN/sources.d"
printf '1.2.3.0/24\n' >"$RN/v.txt"
cat >"$RN/sources.d/r.conf" <<EOF
enabled=true
name=r
type=file
paths=$RN/v.txt
min_entries=1
EOF
cat >"$RN/config.conf" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=false
snapshot_retention=2
state_dir=$RN/state
sources_dir=$RN/sources.d
log_target=stdout
update_interval=0
EOF
for i in 1 2 3 4 5; do
  printf '10.0.0.%d/32\n' "$i" >"$RN/v.txt"
  "$CLI" --config "$RN/config.conf" sync >/dev/null 2>&1
done
snap_count=$(find "$RN/state/snapshots/r" -name '*.ips' -type f 2>/dev/null | wc -l | tr -d ' ')
if (( snap_count <= 2 )); then
  pass "snapshot retention prunes to the configured limit"
else
  fail "snapshot retention prunes to the configured limit (got $snap_count)"
fi
"$CLI" --config "$RN/config.conf" cleanup >/dev/null 2>&1

ME="$WS/merge"
mkdir -p "$ME/sources.d"
printf '1.2.3.0/24\n' >"$ME/v.txt"
cat >"$ME/sources.d/m.conf" <<EOF
enabled=true
name=m
type=file
paths=$ME/v.txt
min_entries=1
EOF
cat >"$ME/jail.local" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 10.9.9.9
EOF
cat >"$ME/config.conf" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=true
fail2ban_merge_existing=false
fail2ban_ignoreip_file=$ME/dropin.conf
state_dir=$ME/state
sources_dir=$ME/sources.d
log_target=stdout
update_interval=0
EOF
FAIL2BAN_JAIL_CONF="$ME/none" FAIL2BAN_JAIL_LOCAL="$ME/jail.local" FAIL2BAN_JAIL_D="$ME/nodir" FAIL2BAN_RELOAD=false \
  "$CLI" --config "$ME/config.conf" sync >"$ME/out" 2>&1
dropin="$(cat "$ME/dropin.conf" 2>/dev/null || true)"
assert_contains "merge_existing=false keeps source ip" "$dropin" "1.2.3.0/24"
assert_not_contains "merge_existing=false drops user ip" "$dropin" "10.9.9.9"
nft delete table inet ip_allowlist 2>/dev/null || true

# ---------------------------------------------------------------------------
# 10g. crash recovery: in-progress marker rolls back to the pre-run snapshot
# ---------------------------------------------------------------------------
CR="$WS/crash"
mkdir -p "$CR/sources.d"
printf '1.2.3.0/24\n' >"$CR/v.txt"
cat >"$CR/sources.d/c.conf" <<EOF
enabled=true
name=c
type=file
paths=$CR/v.txt
min_entries=1
EOF
cat >"$CR/config.conf" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=false
state_dir=$CR/state
sources_dir=$CR/sources.d
log_target=stdout
update_interval=0
EOF
"$CLI" --config "$CR/config.conf" sync >/dev/null 2>&1
# Simulate an interrupted run: marker plus a snapshot taken during that run.
mkdir -p "$CR/state/snapshots/c"
printf 'started=%s\n' "$(date +%s)" >"$CR/state/in-progress"
cp "$CR/state/current/c.ips" "$CR/state/snapshots/c/run.ips"
# Corrupt the live values as if the interrupted run had partially written them.
printf '9.9.9.9\n' >"$CR/state/current/c.ips"
cat >"$CR/sources.d/c.conf" <<EOF
enabled=false
name=c
type=file
paths=$CR/v.txt
min_entries=1
EOF
"$CLI" --config "$CR/config.conf" sync --allow-empty >"$CR/out" 2>&1
assert_contains "crash recovery rolls back to the pre-run snapshot" "$(cat "$CR/out")" "restored the snapshot taken before the interrupted run"
if [[ -f "$CR/state/in-progress" ]]; then
  fail "crash recovery clears the in-progress marker"
else
  pass "crash recovery clears the in-progress marker"
fi
"$CLI" --config "$CR/config.conf" cleanup >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 11. install/uninstall smoke test
# ---------------------------------------------------------------------------
if [[ -x "$ROOT/install.sh" ]]; then
  if "$ROOT/install.sh" --yes >"$WS/install.log" 2>&1; then
    pass "install.sh exits 0"
  else
    fail "install.sh exits 0 (see $WS/install.log)"
  fi
  if [[ -x /usr/local/sbin/ip-allowlist ]]; then
    pass "installed symlink present"
  else
    fail "installed symlink present"
  fi
  installed_version="$(/usr/local/sbin/ip-allowlist version 2>&1 || true)"
  assert_contains "installed binary runs" "$installed_version" "ip-allowlist"

  # Bootstrap mode: reading the installer from stdin leaves BASH_SOURCE unset;
  # --from-dir keeps it offline while exercising that code path.
  if bash -s -- --yes --from-dir "$ROOT" <"$ROOT/install.sh" >"$WS/install-piped.log" 2>&1; then
    pass "piped install (--from-dir) exits 0"
  else
    fail "piped install (--from-dir) exits 0 (see $WS/install-piped.log)"
    cat "$WS/install-piped.log" >&2
  fi
  piped_version="$(/usr/local/sbin/ip-allowlist version 2>&1 || true)"
  assert_contains "piped install binary runs" "$piped_version" "ip-allowlist"

  # A broken source tree must fail without damaging the installed copy.
  BADTREE="$WS/badtree"
  mkdir -p "$BADTREE"
  cp "$ROOT/ip-allowlist" "$BADTREE/ip-allowlist"
  if "$ROOT/install.sh" --yes --from-dir "$BADTREE" >"$WS/install-bad.log" 2>&1; then
    fail "install from an incomplete tree fails"
  else
    pass "install from an incomplete tree fails"
  fi
  still="$(/usr/local/sbin/ip-allowlist version 2>&1 || true)"
  assert_contains "failed install leaves the previous install intact" "$still" "ip-allowlist"

  if "$ROOT/uninstall.sh" --yes --purge >"$WS/uninstall.log" 2>&1; then
    pass "uninstall.sh exits 0"
  else
    fail "uninstall.sh exits 0 (see $WS/uninstall.log)"
  fi
  if [[ ! -e /usr/local/sbin/ip-allowlist && ! -e /etc/ip-allowlist ]]; then
    pass "uninstall purged files"
  else
    fail "uninstall purged files"
  fi
else
  skip "install/uninstall smoke test"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "integration: $PASS passed, $FAIL failed, $SKIP skipped"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
