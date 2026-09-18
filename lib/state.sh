#!/usr/bin/env bash
# ip-allowlist state management: snapshots, hashes, markers, status.
# Sourced by the main script; do not execute directly.

[[ -n "${_IP_ALLOWLIST_STATE_LOADED:-}" ]] && return 0
_IP_ALLOWLIST_STATE_LOADED=1

STATE_DIR=""

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

# Initialize the state directory layout.
state_init() {
  local dir="$1"
  STATE_DIR="$dir"
  mkdir -p -- \
    "$dir" \
    "$dir/current" \
    "$dir/applied" \
    "$dir/status" \
    "$dir/rules" \
    "$dir/snapshots" \
    "$dir/fail2ban"
}

state_path() {
  local rel="$1"
  printf '%s/%s' "${STATE_DIR%/}" "$rel"
}

# ---------------------------------------------------------------------------
# In-progress marker (crash recovery)
# ---------------------------------------------------------------------------

state_mark_in_progress() {
  local marker
  marker=$(state_path "in-progress")
  {
    printf 'pid=%s\n' "$$"
    printf 'started=%s\n' "$(date +%s)"
    printf 'run_id=%s\n' "$RUN_ID"
  } >"$marker"
}

state_clear_in_progress() {
  rm -f -- "$(state_path "in-progress")"
}

state_in_progress() {
  [[ -f "$(state_path "in-progress")" ]]
}

# ---------------------------------------------------------------------------
# Applied hash tracking
# ---------------------------------------------------------------------------

state_get_applied_hash() {
  local name="$1"
  local f
  f=$(state_path "applied/${name}.hash")
  [[ -f "$f" ]] || return 0
  tr -d '[:space:]' <"$f"
}

state_set_applied_hash() {
  local name="$1" hash="$2"
  local f
  f=$(state_path "applied/${name}.hash")
  printf '%s\n' "$hash" >"$f"
}

# Remove applied-hash, entries, rule spec and run marker for a source.
state_remove_source() {
  local name="$1"
  rm -f -- \
    "$(state_path "applied/${name}.hash")" \
    "$(state_path "current/${name}.ips")" \
    "$(state_path "rules/${name}.conf")" \
    "$(state_path "status/${name}.last_run")"
}

# Persist the effective firewall rule parameters for a source.
# Usage: state_write_rule_spec <name> <ports> <protocol> <ipv4> <ipv6>
state_write_rule_spec() {
  local name="$1" ports="$2" protocol="$3" ipv4="$4" ipv6="$5"
  local dir
  dir=$(state_path "rules")
  mkdir -p -- "$dir"
  local tmp
  tmp=$(tmpfile "rules-${name}")
  {
    printf 'allow_ports=%s\n' "$ports"
    printf 'allow_protocol=%s\n' "$protocol"
    printf 'enable_ipv4=%s\n' "$ipv4"
    printf 'enable_ipv6=%s\n' "$ipv6"
  } >"$tmp"
  atomic_install "$tmp" "$dir/${name}.conf" "0644"
}

# ---------------------------------------------------------------------------
# Run timestamps
# ---------------------------------------------------------------------------

state_mark_run() {
  local name="$1"
  mkdir -p -- "$STATE_DIR/status"
  date +%s >"$STATE_DIR/status/${name}.last_run"
}

state_last_run() {
  local name="$1"
  local f="$STATE_DIR/status/${name}.last_run"
  [[ -f "$f" ]] || return 0
  tr -d '[:space:]' <"$f"
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

# Copy the current canonical entries for a source into a timestamped snapshot.
state_snapshot_source() {
  local name="$1"
  local src="$STATE_DIR/current/${name}.ips"
  [[ -f "$src" ]] || return 0
  local dir="$STATE_DIR/snapshots/${name}"
  mkdir -p -- "$dir"
  local ts
  ts=$(date +%s)
  cp -- "$src" "$dir/${ts}.ips"
  # Retain only the most recent 10 snapshots per source.
  prune_snapshots "$dir" 10 ".ips"
}

# Save an arbitrary firewall state blob to the snapshot area.
# Usage: state_snapshot_backend <backend> <file>
state_snapshot_backend() {
  local backend="$1" file="$2"
  local dir="$STATE_DIR/snapshots/backend"
  mkdir -p -- "$dir"
  local ts
  ts=$(date +%s)
  cp -- "$file" "$dir/${backend}-${ts}.state"
  prune_snapshots "$dir" 5 "-*.state"
}

# Keep the newest N files in a directory matching a suffix/pattern.
# Usage: prune_snapshots <dir> <keep> <pattern>
prune_snapshots() {
  local dir="$1" keep="$2" pattern="$3"
  local f
  local -a files=()
  while IFS= read -r f; do
    [[ -e "$f" ]] || continue
    files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f -name "*${pattern}" -print 2>/dev/null)
  (( ${#files[@]} <= keep )) && return 0
  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "${files[@]}" | sort -r)
  local i
  for (( i = keep; i < ${#sorted[@]}; i++ )); do
    rm -f -- "${sorted[i]}"
  done
}

# Restore the most recent snapshot for a source into current/.
# Used by the interrupted-run recovery path.
state_restore_latest_snapshot() {
  local name="$1"
  local dir="$STATE_DIR/snapshots/${name}"
  local f
  local -a files=()
  for f in "$dir"/*.ips; do
    [[ -e "$f" ]] || continue
    files+=("$f")
  done
  (( ${#files[@]} > 0 )) || return 1
  local latest
  latest=$(printf '%s\n' "${files[@]}" | sort | tail -n1)
  [[ -n "$latest" && -f "$latest" ]] || return 1
  atomic_install "$latest" "$STATE_DIR/current/${name}.ips" "0644"
}

# ---------------------------------------------------------------------------
# Backend tracking
# ---------------------------------------------------------------------------

state_set_backend() {
  local backend="$1"
  printf '%s\n' "$backend" >"$(state_path "backend")"
}

state_set_key() {
  local key="$1" value="$2"
  printf '%s\n' "$value" >"$(state_path "$key")"
}

state_get_key() {
  local key="$1"
  local f
  f=$(state_path "$key")
  [[ -f "$f" ]] || return 0
  tr -d '[:space:]' <"$f"
}

# ---------------------------------------------------------------------------
# Fail2ban union hash
# ---------------------------------------------------------------------------

state_fail2ban_hash() {
  state_get_key "fail2ban/applied.hash"
}

state_set_fail2ban_hash() {
  state_set_key "fail2ban/applied.hash" "$1"
}
