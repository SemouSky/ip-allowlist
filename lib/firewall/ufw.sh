#!/usr/bin/env bash
# ip-allowlist ufw backend.
#
# ufw has no native set/chain grouping, so each source entry is installed as an
# individual allow rule tagged with a comment of the form
# "ip-allowlist:<source>". Sync diffs the rules ufw reports as added against the
# desired set and only adds/removes the difference.
#
# Sourced by the main script; do not execute directly.

[[ -n "${_IP_ALLOWLIST_UFW_LOADED:-}" ]] && return 0
_IP_ALLOWLIST_UFW_LOADED=1

UFW_COMMENT_PREFIX="ip-allowlist"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ufw_available() {
  have ufw
}

ufw_is_active() {
  ufw status 2>/dev/null | grep -qi '^Status:[[:space:]]*active'
}

ufw_validate() {
  ufw_available || die "ufw backend selected but 'ufw' is not installed"
  if ! ufw_is_active; then
    log_warn "ufw is not active; rules will be stored but not enforced until 'ufw enable'"
  fi
}

# Normalize a CIDR reported by ufw back to canonical form.
ufw_normalize_cidr() {
  local cidr="$1"
  if [[ "$cidr" == *:* ]]; then
    ipv6_cidr_normalize "$cidr" 2>/dev/null || printf '%s' "$cidr"
  else
    ipv4_cidr_normalize "$cidr" 2>/dev/null || printf '%s' "$cidr"
  fi
}

# ---------------------------------------------------------------------------
# Desired / current rule sets (pure helpers, unit-testable)
# ---------------------------------------------------------------------------

# Build the desired rule set from a state dir.
# Emits "cidr|source" lines, sorted and unique.
# Usage: ufw_build_desired <state_dir> <out_file>
ufw_build_desired() {
  local state_dir="$1" out="$2"
  : >"$out"
  local f base line
  for f in "$state_dir"/current/*.ips; do
    [[ -e "$f" ]] || continue
    base=$(basename -- "$f" .ips)
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      printf '%s|%s\n' "$line" "$base" >>"$out"
    done <"$f"
  done
  LC_ALL=C sort -u -o "$out" "$out"
}

# Parse "ufw show added" output into "cidr|source" lines.
# Usage: ufw_parse_added <raw_file> <out_file>
ufw_parse_added() {
  local raw="$1" out="$2"
  : >"$out"
  local line cidr source norm
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *"${UFW_COMMENT_PREFIX}:"* ]] || continue
    cidr=$(printf '%s' "$line" | sed -n 's/.*from \([^ ]*\).*/\1/p')
    source=$(printf '%s' "$line" | sed -n "s/.*comment '${UFW_COMMENT_PREFIX}:\([^']*\)'.*/\1/p")
    [[ -n "$cidr" && -n "$source" ]] || continue
    norm=$(ufw_normalize_cidr "$cidr")
    printf '%s|%s\n' "$norm" "$source" >>"$out"
  done <"$raw"
  LC_ALL=C sort -u -o "$out" "$out"
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

# Add one managed rule.
ufw_add_rule() {
  local cidr="$1" source="$2"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "ufw: dry-run, would allow from $cidr (source $source)"
    return 0
  fi
  ufw allow from "$cidr" to any comment "${UFW_COMMENT_PREFIX}:${source}" >/dev/null 2>&1 \
    || { log_error "ufw: failed to allow $cidr"; return 1; }
}

# Delete one managed rule.
ufw_del_rule() {
  local cidr="$1" source="$2"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "ufw: dry-run, would delete allow from $cidr (source $source)"
    return 0
  fi
  ufw delete allow from "$cidr" to any comment "${UFW_COMMENT_PREFIX}:${source}" >/dev/null 2>&1 \
    || { log_warn "ufw: failed to delete rule for $cidr"; return 1; }
}

# Reconcile ufw allow rules with all current source entries.
# Usage: ufw_apply <state_dir>
ufw_apply() {
  local state_dir="$1"
  local desired existing added removed raw
  desired=$(tmpfile "ufw-desired")
  existing=$(tmpfile "ufw-existing")
  added=$(tmpfile "ufw-added")
  removed=$(tmpfile "ufw-removed")
  raw=$(tmpfile "ufw-raw")

  ufw_build_desired "$state_dir" "$desired"
  ufw show added 2>/dev/null >"$raw"
  ufw_parse_added "$raw" "$existing"

  LC_ALL=C comm -13 "$existing" "$desired" >"$added"
  LC_ALL=C comm -23 "$existing" "$desired" >"$removed"

  local failures=0 cidr source
  while IFS='|' read -r cidr source || [[ -n "$cidr" ]]; do
    [[ -n "$cidr" ]] || continue
    ufw_del_rule "$cidr" "$source" || failures=$(( failures + 1 ))
  done <"$removed"
  while IFS='|' read -r cidr source || [[ -n "$cidr" ]]; do
    [[ -n "$cidr" ]] || continue
    ufw_add_rule "$cidr" "$source" || failures=$(( failures + 1 ))
  done <"$added"

  local n_add n_del
  n_add=$(count_lines "$added")
  n_del=$(count_lines "$removed")
  log_info "ufw: applied ($n_add added, $n_del removed)"
  (( failures > 0 )) && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Snapshot / cleanup / status
# ---------------------------------------------------------------------------

ufw_snapshot() {
  local out="$1"
  ufw status verbose >"$out" 2>/dev/null || : >"$out"
}

ufw_cleanup() {
  local raw existing cidr source
  raw=$(tmpfile "ufw-clean-raw")
  existing=$(tmpfile "ufw-clean-existing")
  ufw show added 2>/dev/null >"$raw"
  ufw_parse_added "$raw" "$existing"
  while IFS='|' read -r cidr source || [[ -n "$cidr" ]]; do
    [[ -n "$cidr" ]] || continue
    ufw_del_rule "$cidr" "$source" || true
  done <"$existing"
  log_info "ufw: removed managed rules"
}

ufw_status() {
  if ufw_available && ufw_is_active; then
    local n
    n=$(ufw show added 2>/dev/null | grep -c "${UFW_COMMENT_PREFIX}:" || true)
    printf 'active managed_rules=%s' "$n"
  else
    printf 'inactive'
  fi
}
