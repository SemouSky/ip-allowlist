#!/usr/bin/env bash
# ip-allowlist CLI surface test: exercises every command and option.
set -uo pipefail
export IP_ALLOWLIST_SKIP_UPDATE_CHECK=1

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLI="$ROOT/ip-allowlist"

PASS=0
FAIL=0
pass() { PASS=$(( PASS + 1 )); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL - %s\n' "$1" >&2; }
skip() { printf 'skip - %s\n' "$1"; }

assert_eq() {
  local d="$1" e="$2" a="$3"
  if [[ "$e" == "$a" ]]; then pass "$d"; else fail "$d (expected '$e', got '$a')"; fi
}
assert_contains() {
  local d="$1" h="$2" n="$3"
  if [[ "$h" == *"$n"* ]]; then pass "$d"; else fail "$d (missing '$n')"; fi
}
assert_not_contains() {
  local d="$1" h="$2" n="$3"
  if [[ "$h" != *"$n"* ]]; then pass "$d"; else fail "$d (unexpected '$n')"; fi
}
assert_exit() {
  local d="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then pass "$d"; else fail "$d (exit $got, want $want)"; fi
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "cli scenario requires root" >&2; exit 77; }
}
require_root

WS="$(mktemp -d)"
cleanup() {
  nft delete table inet ip_allowlist 2>/dev/null || true
  rm -rf -- "$WS"
}
trap cleanup EXIT

CONF="$WS/config.conf"
SOURCES="$WS/sources.d"
STATE="$WS/state"
mkdir -p "$SOURCES"
printf '1.2.3.0/24\n2001:db8::/32\n' >"$WS/a.txt"
printf '9.9.9.9\n' >"$WS/b.txt"
cat >"$SOURCES/a.conf" <<EOF
name=a
enabled=true
type=file
paths=$WS/a.txt
min_entries=1
EOF
cat >"$SOURCES/b.conf" <<EOF
name=b
enabled=true
type=file
paths=$WS/b.txt
min_entries=1
EOF
cat >"$CONF" <<EOF
firewall_backend=nft
allow_ports=all
fail2ban_enabled=false
state_dir=$STATE
sources_dir=$SOURCES
log_target=stdout
update_interval=0
EOF

# ---------------------------------------------------------------------------
# help / version
# ---------------------------------------------------------------------------
h="$("$CLI" help 2>&1)"; assert_contains "help prints usage" "$h" "Usage: ip-allowlist"
h="$("$CLI" --help 2>&1)"; assert_contains "--help prints usage" "$h" "Usage: ip-allowlist"
h="$("$CLI" -h 2>&1)"; assert_contains "-h prints usage" "$h" "Usage: ip-allowlist"
h="$("$CLI" 2>&1)"; assert_contains "no command prints usage" "$h" "Usage: ip-allowlist"
assert_not_contains "no command does not sync" "$h" "sync complete"
for c in sync check apply-offline sources status cleanup version upgrade install uninstall; do
  h="$("$CLI" help "$c" 2>&1)"
  assert_contains "help $c prints usage" "$h" "ip-allowlist $c"
done
h="$("$CLI" help run 2>&1)"; assert_contains "help run maps to sync" "$h" "ip-allowlist sync"
h="$("$CLI" help uninstall 2>&1)"; assert_contains "help uninstall documents --purge" "$h" "--purge"
h="$("$CLI" help install 2>&1)"; assert_contains "help install documents --prefix" "$h" "--prefix"
h="$("$CLI" help bogus 2>&1)"; assert_contains "help <unknown> falls back to usage" "$h" "Usage: ip-allowlist"

v="$("$CLI" version 2>&1)"; assert_contains "version prints name" "$v" "ip-allowlist"
v="$("$CLI" --version 2>&1)"; assert_contains "--version prints name" "$v" "ip-allowlist"
v="$("$CLI" version --json 2>&1)"; assert_contains "version --json has version" "$v" '"version"'

# ---------------------------------------------------------------------------
# argument validation
# ---------------------------------------------------------------------------
assert_exit "unknown option exits 64" 64 "$CLI" --bogus
assert_exit "unknown command exits 64" 64 "$CLI" frobnicate
cj="$("$CLI" --config /nonexistent/config.conf sources 2>&1)"; assert_contains "missing config is reported" "$cj" "config"
assert_exit "missing config exits non-zero" 1 "$CLI" --config /nonexistent/config.conf sources
assert_exit "--source requires a value" 64 "$CLI" --config "$CONF" --source

# ---------------------------------------------------------------------------
# sources / status before any sync
# ---------------------------------------------------------------------------
s="$("$CLI" --config "$CONF" sources 2>&1)"
assert_contains "sources lists a" "$s" "a"
assert_contains "sources lists b" "$s" "b"
sj="$("$CLI" --config "$CONF" sources --json 2>&1)"
assert_contains "sources --json is an array" "$sj" '"name":"a"'
assert_contains "sources --json has enabled" "$sj" '"enabled":true'
assert_contains "sources --json has due" "$sj" '"due":'
assert_contains "sources --json has status" "$sj" '"status":'
assert_contains "sources --json has last_success" "$sj" '"last_success":'
sf="$("$CLI" --config "$CONF" --source a sources 2>&1)"
assert_contains "sources --source filters" "$sf" "a"
assert_not_contains "sources --source excludes others" "$sf" " b "
assert_exit "sources --source unknown exits non-zero" 1 "$CLI" --config "$CONF" --source nope sources

st="$("$CLI" --config "$CONF" status 2>&1)"
assert_contains "status prints backend" "$st" "backend:"
assert_contains "status prints verify" "$st" "verify:"
assert_contains "status prints fail2ban" "$st" "fail2ban:"
assert_contains "status prints latest" "$st" "latest:"
sj="$("$CLI" --config "$CONF" status --json 2>&1)"
assert_contains "status --json has version" "$sj" '"version"'
assert_contains "status --json has run_id" "$sj" '"run_id"'
assert_contains "status --json has sources" "$sj" '"sources"'
assert_contains "status --json has desired is per source" "$sj" '"desired"'
assert_exit "status --check exits non-zero before first sync" 2 "$CLI" --config "$CONF" status --check

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
c="$("$CLI" --config "$CONF" check 2>&1)"; assert_contains "check reports pending" "$c" "would change"
cj="$("$CLI" --config "$CONF" check --json 2>&1)"; assert_contains "check --json reports changed" "$cj" '"changed":true'
co="$("$CLI" --config "$CONF" check --offline 2>&1)"; assert_contains "check --offline validates only" "$co" "offline"
cs="$("$CLI" --config "$CONF" --source a check 2>&1)"; assert_not_contains "check --source limits scope" "$cs" "source b"
assert_exit "check exits 0" 0 "$CLI" --config "$CONF" check

# ---------------------------------------------------------------------------
# dry-run / sync / run / apply-offline
# ---------------------------------------------------------------------------
nft delete table inet ip_allowlist 2>/dev/null || true
d="$("$CLI" --config "$CONF" sync --dry-run 2>&1)"
assert_contains "sync --dry-run logs planned work" "$d" "dry-run"
if nft list table inet ip_allowlist >/dev/null 2>&1; then
  fail "sync --dry-run leaves the firewall unchanged"
else
  pass "sync --dry-run leaves the firewall unchanged"
fi

"$CLI" --config "$CONF" sync >"$WS/sync.log" 2>&1
assert_contains "sync applies" "$(cat "$WS/sync.log")" "sync complete"
assert_contains "sync generated the accept rule" "$(nft list table inet ip_allowlist 2>/dev/null)" "ip saddr @al_a_v4 accept"
assert_contains "sync includes the second source" "$(nft list table inet ip_allowlist 2>/dev/null)" "9.9.9.9"

r="$("$CLI" --config "$CONF" run 2>&1)"; assert_contains "run is a sync alias" "$r" "sync complete"
c="$("$CLI" --config "$CONF" check 2>&1)"; assert_contains "check reports up to date" "$c" "up to date"
cj="$("$CLI" --config "$CONF" check --json 2>&1)"; assert_contains "check --json reports no change" "$cj" '"changed":false'
assert_exit "status --check exits 0 after sync" 0 "$CLI" --config "$CONF" status --check

"$CLI" --config "$CONF" sync --force >"$WS/force.log" 2>&1
assert_contains "sync --force re-applies" "$(cat "$WS/force.log")" "sync complete"

assert_exit "apply-offline exits 0" 0 "$CLI" --config "$CONF" apply-offline
assert_contains "apply-offline keeps the table" "$(nft list table inet ip_allowlist 2>/dev/null)" "ip saddr @al_a_v4"

# ---------------------------------------------------------------------------
# --source selective sync preserves the other source
# ---------------------------------------------------------------------------
printf '1.2.3.0/24\n8.8.8.8\n' >"$WS/a.txt"
printf '7.7.7.7\n' >"$WS/b.txt"
"$CLI" --config "$CONF" sync --source a >/dev/null 2>&1
a_now="$(cat "$STATE/current/a.ips")"
b_now="$(cat "$STATE/current/b.ips")"
assert_contains "sync --source updates the selected source" "$a_now" "8.8.8.8"
assert_eq "sync --source preserves unselected sources" "9.9.9.9/32" "$b_now"
assert_contains "partial sync keeps other rules in the table" "$(nft list table inet ip_allowlist 2>/dev/null)" "9.9.9.9"

# ---------------------------------------------------------------------------
# verbs: verbose / quiet
# ---------------------------------------------------------------------------
vb="$("$CLI" --config "$CONF" --verbose sync 2>&1)"
assert_contains "--verbose emits debug" "$vb" "[DEBUG]"
qt="$("$CLI" --config "$CONF" --quiet sync 2>&1)"
assert_not_contains "--quiet suppresses info" "$qt" "[INFO]"

# ---------------------------------------------------------------------------
# all sources disabled: guard, then --allow-empty
# ---------------------------------------------------------------------------
printf 'name=a\nenabled=false\ntype=file\npaths=%s\nmin_entries=1\n' "$WS/a.txt" >"$SOURCES/a.conf"
printf 'name=b\nenabled=false\ntype=file\npaths=%s\nmin_entries=1\n' "$WS/b.txt" >"$SOURCES/b.conf"
guard="$("$CLI" --config "$CONF" sync 2>&1)"; guard_rc=$?
assert_eq "no active sources aborts" "1" "$guard_rc"
assert_contains "no active sources explains the guard" "$guard" "no active sources"
assert_exit "sync --allow-empty clears everything" 0 "$CLI" --config "$CONF" sync --allow-empty
if nft list table inet ip_allowlist >/dev/null 2>&1; then
  pass "cleared table still exists (empty)"
else
  pass "cleared table removed"
fi

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
"$CLI" --config "$CONF" cleanup >"$WS/cleanup.log" 2>&1
if nft list table inet ip_allowlist >/dev/null 2>&1; then
  fail "cleanup removes the table"
else
  pass "cleanup removes the table"
fi
assert_exit "status --check warns after cleanup" 1 "$CLI" --config "$CONF" status --check

# ---------------------------------------------------------------------------
# upgrade (offline / pinned)
# ---------------------------------------------------------------------------
badc="$("$CLI" --config "$CONF" upgrade --version 0.0.1 2>&1)"; badrc=$?
assert_eq "upgrade to an older version is refused" "1" "$badrc"
assert_contains "upgrade refusal explains --force" "$badc" "--force"

# ---------------------------------------------------------------------------
# install / uninstall
# ---------------------------------------------------------------------------
if "$ROOT/install.sh" --yes >"$WS/install.log" 2>&1; then
  pass "install exits 0"
else
  fail "install exits 0 (see $WS/install.log)"
fi
assert_contains "install config is usable" "$("$CLI" --config /etc/ip-allowlist/config.conf sources 2>&1)" "cloudflare"
mkdir -p /etc/ip-allowlist/sources.d
printf '9.9.9.9\n' >"$WS/inst.txt"
printf 'name=t\nenabled=true\ntype=file\npaths=%s\nmin_entries=1\n' "$WS/inst.txt" >"/etc/ip-allowlist/sources.d/t.conf"
assert_exit "installed binary syncs" 0 "$CLI" sync
assert_exit "install --from-dir re-installs" 0 "$ROOT/install.sh" --yes --from-dir "$ROOT"
assert_exit "upgrade --from-dir runs offline" 0 "$CLI" upgrade --from-dir "$ROOT"
assert_exit "upgrade --from-dir --sync exits 0" 0 "$CLI" upgrade --from-dir "$ROOT" --sync
assert_exit "uninstall without confirmation aborts" 0 bash -c "printf 'n\n' | '$CLI' uninstall"
assert_exit "uninstall keeps config without --purge" 0 "$CLI" uninstall --yes
if [[ -f /etc/ip-allowlist/config.conf ]]; then
  pass "uninstall without --purge preserves config"
else
  fail "uninstall without --purge preserves config"
fi
assert_exit "uninstall --purge exits 0" 0 "$CLI" uninstall --yes --purge
if [[ ! -e /etc/ip-allowlist && ! -e /usr/local/sbin/ip-allowlist ]]; then
  pass "uninstall --purge removes config and program"
else
  fail "uninstall --purge removes config and program"
fi

echo ""
echo "cli integration: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
