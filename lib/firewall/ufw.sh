#!/usr/bin/env bash
# ip-allowlist ufw backend.
#
# ufw has no native set/chain grouping, so each source entry is installed as an
# individual allow rule tagged with a comment of the form
# "ip-allowlist:<source>". A rule is identified by the tuple
# cidr|source|protocol|port, so a source can allow all traffic, a protocol, or
# specific ports. Sync diffs the rules ufw reports as added against the desired
# set and only adds/removes the difference.
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
  if ! ufw_version_supported; then
    log_warn "ufw version is older than 0.34; rule comments may not be supported"
  fi
  if ! ufw_is_active; then
    log_warn "ufw is not active; rules will be stored but not enforced until 'ufw enable'"
  fi
}

# Return 0 when ufw is >= 0.34 (comment support).
ufw_version_supported() {
  local v maj min
  v=$(ufw --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  [[ -n "$v" ]] || return 1
  maj="${v%%.*}"
  min="${v##*.}"
  (( 10#$maj > 0 || (10#$maj == 0 && 10#$min >= 34) ))
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
# Emits "cidr|source|protocol|port" lines, sorted and unique.
# Usage: ufw_build_desired <state_dir> <out_file>
ufw_build_desired() {
  local state_dir="$1" out="$2"
  : >"$out"
  local f base line ports protocol ipv4 ipv6 protocols p r
  for f in "$state_dir"/current/*.ips; do
    [[ -e "$f" ]] || continue
    base=$(basename -- "$f" .ips)
    ports=$(rule_spec_get "$state_dir" "$base" allow_ports any)
    protocol=$(rule_spec_get "$state_dir" "$base" allow_protocol any)
    ipv4=$(rule_spec_get "$state_dir" "$base" enable_ipv4 true)
    ipv6=$(rule_spec_get "$state_dir" "$base" enable_ipv6 true)
    protocols=$(effective_protocols "$protocol" "$ports")

    local -a ranges=()
    if [[ "$ports" != "any" ]]; then
      IFS=',' read -ra ranges <<<"$ports"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      if [[ "$line" == *:* ]]; then
        [[ "$ipv6" == "true" ]] || continue
      else
        [[ "$ipv4" == "true" ]] || continue
      fi
      if [[ -z "$protocols" ]]; then
        printf '%s|%s|any|any\n' "$line" "$base" >>"$out"
      elif [[ "$ports" == "any" ]]; then
        for p in $protocols; do
          printf '%s|%s|%s|any\n' "$line" "$base" "$p" >>"$out"
        done
      else
        for p in $protocols; do
          for r in "${ranges[@]:-}"; do
            [[ -n "$r" ]] || continue
            printf '%s|%s|%s|%s\n' "$line" "$base" "$p" "${r//-/:}" >>"$out"
          done
        done
      fi
    done <"$f"
  done
  LC_ALL=C sort -u -o "$out" "$out"
}

# Parse "ufw show added" output into "cidr|source|protocol|port" lines.
# Usage: ufw_parse_added <raw_file> <out_file>
ufw_parse_added() {
  local raw="$1" out="$2"
  : >"$out"
  local line cidr source proto port norm
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *"${UFW_COMMENT_PREFIX}:"* ]] || continue
    cidr=$(printf '%s' "$line" | sed -n 's/.*from \([^ ]*\).*/\1/p')
    source=$(printf '%s' "$line" | sed -n "s/.*comment '${UFW_COMMENT_PREFIX}:\([^']*\)'.*/\1/p")
    [[ -n "$cidr" && -n "$source" ]] || continue
    proto=$(printf '%s' "$line" | sed -n 's/.*proto \([^ ]*\).*/\1/p')
    port=$(printf '%s' "$line" | sed -n 's/.*port \([^ ]*\).*/\1/p')
    [[ -n "$proto" ]] || proto=any
    [[ -n "$port" ]] || port=any
    norm=$(ufw_normalize_cidr "$cidr")
    printf '%s|%s|%s|%s\n' "$norm" "$source" "$proto" "$port" >>"$out"
  done <"$raw"
  LC_ALL=C sort -u -o "$out" "$out"
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

# Add one managed rule.
ufw_add_rule() {
  local cidr="$1" source="$2" proto="$3" port="$4"
  local -a args=(allow from "$cidr")
  if [[ "$port" == "any" ]]; then
    if [[ "$proto" == "any" ]]; then
      args+=(to any)
    else
      args+=(proto "$proto")
    fi
  else
    [[ "$proto" == "any" ]] && proto=tcp
    args+=(to any port "$port" proto "$proto")
  fi
  args+=(comment "${UFW_COMMENT_PREFIX}:${source}")

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "ufw: dry-run, would add: ufw ${args[*]}"
    return 0
  fi
  ufw "${args[@]}" >/dev/null 2>&1 \
    || { log_error "ufw: failed to add rule for $cidr"; return 1; }
}

# Delete one managed rule.
ufw_del_rule() {
  local cidr="$1" source="$2" proto="$3" port="$4"
  local -a args=(delete allow from "$cidr")
  if [[ "$port" == "any" ]]; then
    if [[ "$proto" == "any" ]]; then
      args+=(to any)
    else
      args+=(proto "$proto")
    fi
  else
    [[ "$proto" == "any" ]] && proto=tcp
    args+=(to any port "$port" proto "$proto")
  fi
  args+=(comment "${UFW_COMMENT_PREFIX}:${source}")

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "ufw: dry-run, would delete: ufw ${args[*]}"
    return 0
  fi
  ufw "${args[@]}" >/dev/null 2>&1 \
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

  local failures=0 cidr source proto port
  while IFS='|' read -r cidr source proto port || [[ -n "$cidr" ]]; do
    [[ -n "$cidr" ]] || continue
    ufw_del_rule "$cidr" "$source" "$proto" "$port" || failures=$(( failures + 1 ))
  done <"$removed"
  while IFS='|' read -r cidr source proto port || [[ -n "$cidr" ]]; do
    [[ -n "$cidr" ]] || continue
    ufw_add_rule "$cidr" "$source" "$proto" "$port" || failures=$(( failures + 1 ))
  done <"$added"

  local n_add n_del
  n_add=$(count_lines "$added")
  n_del=$(count_lines "$removed")
  log_info "ufw: applied ($n_add added, $n_del removed)"
  (( failures > 0 )) && return 1
  return 0
}

# Verify that every desired managed rule is present.
# Usage: ufw_verify <state_dir>
ufw_verify() {
  local state_dir="$1"
  local desired existing raw
  desired=$(tmpfile "ufw-verify-desired")
  existing=$(tmpfile "ufw-verify-existing")
  raw=$(tmpfile "ufw-verify-raw")
  ufw_build_desired "$state_dir" "$desired"
  ufw show added 2>/dev/null >"$raw"
  ufw_parse_added "$raw" "$existing"
  if LC_ALL=C comm -13 "$existing" "$desired" | grep -q .; then
    log_error "ufw verify: applied rules do not match the desired set"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Snapshot / cleanup / status
# ---------------------------------------------------------------------------

ufw_snapshot() {
  local out="$1"
  ufw status verbose >"$out" 2>/dev/null || : >"$out"
}

# Snapshot the ufw configuration directories (file-level rollback).
ufw_snapshot_files() {
  state_snapshot_paths ufw /etc/ufw /etc/default/ufw
}

# Restore the ufw configuration directories and reload.
ufw_restore_files() {
  state_restore_paths ufw || return 1
  ufw reload >/dev/null 2>&1 || true
  log_warn "ufw: restored configuration files from snapshot"
  return 0
}

ufw_cleanup() {
  local raw existing cidr source proto port
  raw=$(tmpfile "ufw-clean-raw")
  existing=$(tmpfile "ufw-clean-existing")
  ufw show added 2>/dev/null >"$raw"
  ufw_parse_added "$raw" "$existing"
  while IFS='|' read -r cidr source proto port || [[ -n "$cidr" ]]; do
    [[ -n "$cidr" ]] || continue
    ufw_del_rule "$cidr" "$source" "$proto" "$port" || true
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
