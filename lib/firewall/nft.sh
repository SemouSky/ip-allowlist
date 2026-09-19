#!/usr/bin/env bash
# ip-allowlist nftables backend.
#
# Model (per the plan):
#   table inet ip_allowlist
#     set al_<name>_v4  { type ipv4_addr; flags interval; ... }
#     set al_<name>_v6  { type ipv6_addr; flags interval; ... }
#     chain al_<name>   { ip saddr @al_<name>_v4 tcp dport { 443 } accept ... }
#     chain input       { type filter hook input priority filter; policy accept;
#                         jump al_<name>; ... }
#
# The whole table is regenerated and applied in one atomic `nft -f` transaction.
#
# Sourced by the main script; do not execute directly.

[[ -n "${_IP_ALLOWLIST_NFT_LOADED:-}" ]] && return 0
_IP_ALLOWLIST_NFT_LOADED=1

NFT_TABLE="${NFT_TABLE:-ip_allowlist}"
NFT_FAMILY="${NFT_FAMILY:-inet}"
NFT_PRIORITY="${NFT_PRIORITY:-filter}"
# Table name used by releases before the plan naming was adopted.
NFT_LEGACY_TABLE="ip-allowlist"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Convert a source name into a valid nft identifier fragment.
nft_sanitize_name() {
  local name="$1"
  name="${name//[^A-Za-z0-9_]/_}"
  if [[ "$name" =~ ^[0-9] ]]; then
    name="_${name}"
  fi
  printf '%s' "$name"
}

nft_available() {
  have nft
}

nft_validate() {
  nft_available || die "nftables backend selected but 'nft' is not installed"
}

# ---------------------------------------------------------------------------
# Ruleset generation
# ---------------------------------------------------------------------------

# Emit a set definition. Usage: nft_emit_set <set_name> <type> <elements...>
nft_emit_set() {
  local set_name="$1" type="$2"
  shift 2
  local -a entries=("$@")
  (( ${#entries[@]} > 0 )) || return 0

  printf '  set %s {\n' "$set_name"
  printf '    type %s\n' "$type"
  printf '    flags interval\n'
  printf '    elements = { '
  local i
  for (( i = 0; i < ${#entries[@]}; i++ )); do
    if (( i > 0 )); then
      printf ',\n                 '
    fi
    printf '%s' "${entries[i]}"
  done
  printf ' }\n'
  printf '  }\n'
}

# Emit one source's chain with rules for the given family.
# Usage: nft_emit_source_rules <family ip|ip6> <set_name> <ports> <protocols>
nft_emit_source_rules() {
  local family="$1" setname="$2" ports="$3" protocols="$4"
  if [[ -z "$protocols" ]]; then
    printf '    %s saddr @%s accept\n' "$family" "$setname"
    return 0
  fi
  local proto
  for proto in $protocols; do
    printf '    %s saddr @%s %s dport { %s } accept\n' \
      "$family" "$setname" "$proto" "${ports//,/, }"
  done
}

# Generate the full nft ruleset for all current sources into a file.
# Usage: nft_generate_ruleset <state_dir> <output_file>
nft_generate_ruleset() {
  local state_dir="$1" out="$2"
  local name entries base ports protocol ipv4 ipv6 protocols

  {
    printf 'table %s %s {}\n' "$NFT_FAMILY" "$NFT_TABLE"
    printf 'delete table %s %s\n' "$NFT_FAMILY" "$NFT_TABLE"
    printf 'table %s %s {\n' "$NFT_FAMILY" "$NFT_TABLE"

    # First pass: sets and per-source chains.
    for entries in "$state_dir"/current/*.ips; do
      [[ -e "$entries" ]] || continue
      base=$(basename -- "$entries" .ips)
      name=$(nft_sanitize_name "$base")
      ports=$(rule_spec_get "$state_dir" "$base" allow_ports any)
      protocol=$(rule_spec_get "$state_dir" "$base" allow_protocol any)
      ipv4=$(rule_spec_get "$state_dir" "$base" enable_ipv4 true)
      ipv6=$(rule_spec_get "$state_dir" "$base" enable_ipv6 true)
      protocols=$(effective_protocols "$protocol" "$ports")

      local -a v4=() v6=()
      local line
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == *:* ]]; then v6+=("$line"); else v4+=("$line"); fi
      done <"$entries"

      if [[ "$ipv4" == "true" ]] && (( ${#v4[@]} > 0 )); then
        nft_emit_set "al_${name}_v4" "ipv4_addr" "${v4[@]}"
      fi
      if [[ "$ipv6" == "true" ]] && (( ${#v6[@]} > 0 )); then
        nft_emit_set "al_${name}_v6" "ipv6_addr" "${v6[@]}"
      fi

      # Skip the per-source chain when neither family has entries.
      local have4=0 have6=0
      [[ "$ipv4" == "true" ]] && (( ${#v4[@]} > 0 )) && have4=1
      [[ "$ipv6" == "true" ]] && (( ${#v6[@]} > 0 )) && have6=1
      (( have4 == 1 || have6 == 1 )) || continue

      printf '  chain al_%s {\n' "$name"
      if (( have4 == 1 )); then
        nft_emit_source_rules "ip" "al_${name}_v4" "$ports" "$protocols"
      fi
      if (( have6 == 1 )); then
        nft_emit_source_rules "ip6" "al_${name}_v6" "$ports" "$protocols"
      fi
      printf '  }\n'
    done

    # Second pass: base chain jumping to each source chain.
    local any=0
    for entries in "$state_dir"/current/*.ips; do
      [[ -e "$entries" ]] || continue
      base=$(basename -- "$entries" .ips)
      name=$(nft_sanitize_name "$base")
      ipv4=$(rule_spec_get "$state_dir" "$base" enable_ipv4 true)
      ipv6=$(rule_spec_get "$state_dir" "$base" enable_ipv6 true)
      local has4=0 has6=0
      grep -qv ':' "$entries" 2>/dev/null && has4=1
      grep -q ':' "$entries" 2>/dev/null && has6=1
      if { [[ "$ipv4" == "true" && $has4 -eq 1 ]] || [[ "$ipv6" == "true" && $has6 -eq 1 ]]; }; then
        any=1
      fi
    done

    if (( any == 1 )); then
      printf '  chain input {\n'
      printf '    type filter hook input priority %s; policy accept;\n' "$NFT_PRIORITY"
      for entries in "$state_dir"/current/*.ips; do
        [[ -e "$entries" ]] || continue
        base=$(basename -- "$entries" .ips)
        name=$(nft_sanitize_name "$base")
        ipv4=$(rule_spec_get "$state_dir" "$base" enable_ipv4 true)
        ipv6=$(rule_spec_get "$state_dir" "$base" enable_ipv6 true)
        local j4=0 j6=0
        grep -qv ':' "$entries" 2>/dev/null && j4=1
        grep -q ':' "$entries" 2>/dev/null && j6=1
        if { [[ "$ipv4" == "true" && $j4 -eq 1 ]] || [[ "$ipv6" == "true" && $j6 -eq 1 ]]; }; then
          printf '    jump al_%s\n' "$name"
        fi
      done
      printf '  }\n'
    fi

    printf '}\n'
  } >"$out"
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

# Remove the table used by releases before the plan naming was adopted.
nft_cleanup_legacy() {
  nft list table "$NFT_FAMILY" "$NFT_LEGACY_TABLE" >/dev/null 2>&1 || return 0
  log_warn "removing legacy nft table $NFT_FAMILY $NFT_LEGACY_TABLE"
  nft delete table "$NFT_FAMILY" "$NFT_LEGACY_TABLE" 2>/dev/null || true
}

# Apply nftables rules for all current sources.
# Usage: nft_apply <state_dir>
nft_apply() {
  local state_dir="$1"
  local ruleset err
  ruleset=$(tmpfile "nft-ruleset")
  err=$(tmpfile "nft-err")
  nft_generate_ruleset "$state_dir" "$ruleset"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "nft: dry-run, would apply ruleset:"
    cat -- "$ruleset" >&2
    return 0
  fi

  if ! nft -f "$ruleset" 2>"$err"; then
    log_error "nft: failed to apply ruleset: $(cat -- "$err" 2>/dev/null)"
    return 1
  fi
  log_info "nft: applied ruleset (table $NFT_FAMILY $NFT_TABLE)"
  nft_cleanup_legacy
}

# ---------------------------------------------------------------------------
# Verify / snapshot / cleanup / status
# ---------------------------------------------------------------------------

# Verify that every expected set and per-source chain exists.
# Usage: nft_verify <state_dir>
nft_verify() {
  local state_dir="$1"
  local live
  if ! live=$(nft list table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null); then
    log_error "nft verify: table $NFT_FAMILY $NFT_TABLE missing"
    return 1
  fi
  local entries base name ipv4 ipv6
  for entries in "$state_dir"/current/*.ips; do
    [[ -e "$entries" ]] || continue
    base=$(basename -- "$entries" .ips)
    name=$(nft_sanitize_name "$base")
    ipv4=$(rule_spec_get "$state_dir" "$base" enable_ipv4 true)
    ipv6=$(rule_spec_get "$state_dir" "$base" enable_ipv6 true)
    local has4=0 has6=0
    grep -qv ':' "$entries" 2>/dev/null && has4=1
    grep -q ':' "$entries" 2>/dev/null && has6=1
    if { [[ "$ipv4" == "true" && $has4 -eq 1 ]] || [[ "$ipv6" == "true" && $has6 -eq 1 ]]; }; then
      if [[ "$live" != *"chain al_${name} {"* ]]; then
        log_error "nft verify: chain al_${name} missing"
        return 1
      fi
    fi
    if [[ "$ipv4" == "true" && $has4 -eq 1 ]] && [[ "$live" != *"set al_${name}_v4 {"* ]]; then
      log_error "nft verify: set al_${name}_v4 missing"
      return 1
    fi
    if [[ "$ipv6" == "true" && $has6 -eq 1 ]] && [[ "$live" != *"set al_${name}_v6 {"* ]]; then
      log_error "nft verify: set al_${name}_v6 missing"
      return 1
    fi
  done
  return 0
}

# nft state lives in the kernel; logical snapshots cover rollback. No
# configuration files are managed, so file snapshots are no-ops.
nft_snapshot_files() { return 0; }
nft_restore_files() { return 1; }

# Save the current nft table to a file (for rollback/audit).
nft_snapshot() {
  local out="$1"
  if ! nft list table "$NFT_FAMILY" "$NFT_TABLE" >"$out" 2>/dev/null; then
    : >"$out"
  fi
}

# Remove all ip-allowlist nft objects (current and legacy table names).
nft_cleanup() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "nft: dry-run, would delete table $NFT_FAMILY $NFT_TABLE"
    return 0
  fi
  local t
  for t in "$NFT_TABLE" "$NFT_LEGACY_TABLE"; do
    if nft list table "$NFT_FAMILY" "$t" >/dev/null 2>&1; then
      nft delete table "$NFT_FAMILY" "$t" || log_warn "nft: failed to delete table $t"
      log_info "nft: deleted table $NFT_FAMILY $t"
    fi
  done
}

# Report status of the nft table.
nft_status() {
  if nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1; then
    local n
    n=$(nft list table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null | grep -c 'elements' || true)
    printf 'active table=%s/%s sets=%s' "$NFT_FAMILY" "$NFT_TABLE" "$n"
  else
    printf 'inactive'
  fi
}
