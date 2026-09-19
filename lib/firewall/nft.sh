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
# Two apply strategies:
#   * partial (default when the table already exists): only the sources that
#     changed are flushed and rewritten, and removed sources are deleted, all in
#     one `nft -f` transaction; other sources are untouched.
#   * full: regenerate the whole table in one atomic transaction (first run,
#     backend switch, or when the table is missing/foreign).
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

nft_table_exists() {
  nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1
}

nft_set_exists() {
  nft list set "$NFT_FAMILY" "$NFT_TABLE" "$1" >/dev/null 2>&1
}

# Handle of the base-chain "jump <chain>" rule, or empty.
nft_jump_handle() {
  local chain="$1"
  nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" input 2>/dev/null \
    | sed -n "s/.*jump ${chain} # handle \([0-9][0-9]*\).*/\1/p" | head -n1
}

# Print the normalized entries for one family, one per line.
nft_family_entries() {
  local file="$1" fam="$2"
  if [[ "$fam" == "v4" ]]; then
    grep -v ':' "$file" 2>/dev/null || true
  else
    grep ':' "$file" 2>/dev/null || true
  fi
}

# Effective rule parameters for a source. Sets global-ish outputs via echo.
# Usage: nft_source_params <state_dir> <base>  ->  "ports protocol ipv4 ipv6 protocols"
nft_source_params() {
  local state_dir="$1" base="$2" ports protocol ipv4 ipv6 protocols
  ports=$(rule_spec_get "$state_dir" "$base" allow_ports any)
  protocol=$(rule_spec_get "$state_dir" "$base" allow_protocol any)
  ipv4=$(rule_spec_get "$state_dir" "$base" enable_ipv4 true)
  ipv6=$(rule_spec_get "$state_dir" "$base" enable_ipv6 true)
  protocols=$(effective_protocols "$protocol" "$ports")
  printf '%s %s %s %s %s' "$ports" "$protocol" "$ipv4" "$ipv6" "$protocols"
}

# ---------------------------------------------------------------------------
# Full ruleset generation
# ---------------------------------------------------------------------------

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

nft_generate_ruleset() {
  local state_dir="$1" out="$2"
  local name entries base ports protocol ipv4 ipv6 protocols

  {
    printf 'table %s %s {}\n' "$NFT_FAMILY" "$NFT_TABLE"
    printf 'delete table %s %s\n' "$NFT_FAMILY" "$NFT_TABLE"
    printf 'table %s %s {\n' "$NFT_FAMILY" "$NFT_TABLE"

    for entries in "$state_dir"/current/*.ips; do
      [[ -e "$entries" ]] || continue
      base=$(basename -- "$entries" .ips)
      name=$(nft_sanitize_name "$base")
      read -r ports _ ipv4 ipv6 protocols <<<"$(nft_source_params "$state_dir" "$base")"

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

    local any=0
    for entries in "$state_dir"/current/*.ips; do
      [[ -e "$entries" ]] || continue
      base=$(basename -- "$entries" .ips)
      name=$(nft_sanitize_name "$base")
      read -r _ _ ipv4 ipv6 _ <<<"$(nft_source_params "$state_dir" "$base")"
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
        read -r _ _ ipv4 ipv6 _ <<<"$(nft_source_params "$state_dir" "$base")"
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
# Partial (per-source) batch
# ---------------------------------------------------------------------------

# Emit batch lines that create/refresh one source's sets, chain and rules.
# Usage: nft_emit_source_batch <state_dir> <base>
nft_emit_source_batch() {
  local state_dir="$1" base="$2"
  local name ports protocol ipv4 ipv6 protocols
  name=$(nft_sanitize_name "$base")
  read -r ports protocol ipv4 ipv6 protocols <<<"$(nft_source_params "$state_dir" "$base")"

  local file="$state_dir/current/${base}.ips"
  local fam set_name entries
  for fam in v4 v6; do
    set_name="al_${name}_${fam}"
    local enabled="$ipv4"
    [[ "$fam" == "v6" ]] && enabled="$ipv6"
    entries=$(nft_family_entries "$file" "$fam")
    if [[ "$enabled" == "true" && -n "$entries" ]]; then
      printf 'add set %s %s %s { type %s; flags interval; }\n' \
        "$NFT_FAMILY" "$NFT_TABLE" "$set_name" "$([[ "$fam" == v4 ]] && echo ipv4_addr || echo ipv6_addr)"
      printf 'flush set %s %s %s\n' "$NFT_FAMILY" "$NFT_TABLE" "$set_name"
      local -a elems=()
      mapfile -t elems <<<"$entries"
      printf 'add element %s %s %s { ' "$NFT_FAMILY" "$NFT_TABLE" "$set_name"
      local ei
      for (( ei = 0; ei < ${#elems[@]}; ei++ )); do
        [[ -n "${elems[ei]}" ]] || continue
        (( ei > 0 )) && printf ', '
        printf '%s' "${elems[ei]}"
      done
      printf ' }\n'
    elif nft_set_exists "$set_name"; then
      printf 'delete set %s %s %s\n' "$NFT_FAMILY" "$NFT_TABLE" "$set_name"
    fi
  done

  printf 'add chain %s %s al_%s\n' "$NFT_FAMILY" "$NFT_TABLE" "$name"
  printf 'flush chain %s %s al_%s\n' "$NFT_FAMILY" "$NFT_TABLE" "$name"

  local have4=0 have6=0
  [[ "$ipv4" == "true" ]] && [[ -n "$(nft_family_entries "$file" v4)" ]] && have4=1
  [[ "$ipv6" == "true" ]] && [[ -n "$(nft_family_entries "$file" v6)" ]] && have6=1
  if (( have4 == 1 )); then
    nft_emit_source_rules "ip" "al_${name}_v4" "$ports" "$protocols" \
      | sed "s/^[[:space:]]*/add rule $NFT_FAMILY $NFT_TABLE al_${name} /"
  fi
  if (( have6 == 1 )); then
    nft_emit_source_rules "ip6" "al_${name}_v6" "$ports" "$protocols" \
      | sed "s/^[[:space:]]*/add rule $NFT_FAMILY $NFT_TABLE al_${name} /"
  fi
}

# Emit batch lines removing one source's chain, sets and jump rule.
# Usage: nft_emit_remove_batch <base>
nft_emit_remove_batch() {
  local base="$1"
  local name
  name=$(nft_sanitize_name "$base")
  local h
  h=$(nft_jump_handle "al_${name}")
  if [[ -n "$h" ]]; then
    printf 'delete rule %s %s input handle %s\n' "$NFT_FAMILY" "$NFT_TABLE" "$h"
  fi
  if nft list chain "$NFT_FAMILY" "$NFT_TABLE" "al_${name}" >/dev/null 2>&1; then
    printf 'delete chain %s %s al_%s\n' "$NFT_FAMILY" "$NFT_TABLE" "$name"
  fi
  local fam set_name
  for fam in v4 v6; do
    set_name="al_${name}_${fam}"
    nft_set_exists "$set_name" && printf 'delete set %s %s %s\n' "$NFT_FAMILY" "$NFT_TABLE" "$set_name"
  done
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

nft_cleanup_legacy() {
  nft list table "$NFT_FAMILY" "$NFT_LEGACY_TABLE" >/dev/null 2>&1 || return 0
  log_warn "removing legacy nft table $NFT_FAMILY $NFT_LEGACY_TABLE"
  nft delete table "$NFT_FAMILY" "$NFT_LEGACY_TABLE" 2>/dev/null || true
}

# Apply nftables rules. Uses per-source updates when the table already exists
# and no full rebuild was requested.
# Usage: nft_apply <state_dir>
nft_apply() {
  local state_dir="$1"
  local ruleset err
  ruleset=$(tmpfile "nft-ruleset")
  err=$(tmpfile "nft-err")

  local full="${FIREWALL_FULL_REBUILD:-0}"
  if (( full == 0 )) && ! nft_table_exists; then
    full=1
  fi

  if (( full == 1 )); then
    log_debug "nft: full apply"
    nft_generate_ruleset "$state_dir" "$ruleset"
  else
    local -a changed=("${FIREWALL_CHANGED_SOURCES[@]:-}")
    local -a removed=("${FIREWALL_REMOVED_SOURCES[@]:-}")
    if (( ${#changed[@]} == 0 && ${#removed[@]} == 0 )); then
      log_debug "nft: full apply (no changed sources recorded)"
      nft_generate_ruleset "$state_dir" "$ruleset"
    else
      log_debug "nft: partial apply (${#changed[@]} changed, ${#removed[@]} removed)"
      {
        printf 'add table %s %s\n' "$NFT_FAMILY" "$NFT_TABLE"
        printf 'add chain %s %s input { type filter hook input priority %s; policy accept; }\n' \
          "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PRIORITY"
        local n
        for n in "${removed[@]}"; do
          [[ -n "$n" ]] || continue
          nft_emit_remove_batch "$n"
        done
        for n in "${changed[@]}"; do
          [[ -n "$n" ]] || continue
          [[ -f "$state_dir/current/${n}.ips" ]] || continue
          nft_emit_source_batch "$state_dir" "$n"
        done
        # Ensure every applied source has its jump rule in the base chain.
        for n in "${changed[@]}"; do
          [[ -n "$n" ]] || continue
          [[ -f "$state_dir/current/${n}.ips" ]] || continue
          local cname
          cname=$(nft_sanitize_name "$n")
          if [[ -z "$(nft_jump_handle "al_${cname}")" ]]; then
            printf 'add rule %s %s input jump al_%s\n' "$NFT_FAMILY" "$NFT_TABLE" "$cname"
          fi
        done
      } >"$ruleset"
    fi
  fi

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
    read -r _ _ ipv4 ipv6 _ <<<"$(nft_source_params "$state_dir" "$base")"
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

# Return non-zero when a removed source still has objects.
# Usage: nft_verify_orphans <name> ...
nft_verify_orphans() {
  local n sname
  for n in "$@"; do
    [[ -n "$n" ]] || continue
    sname=$(nft_sanitize_name "$n")
    if nft list chain "$NFT_FAMILY" "$NFT_TABLE" "al_${sname}" >/dev/null 2>&1; then
      log_error "nft verify: removed source $n still has chain al_${sname}"
      return 1
    fi
    if [[ -n "$(nft_jump_handle "al_${sname}")" ]]; then
      log_error "nft verify: removed source $n still has a jump rule"
      return 1
    fi
  done
  return 0
}

nft_snapshot_files() { return 0; }
nft_restore_files() { return 1; }

nft_snapshot() {
  local out="$1"
  if ! nft list table "$NFT_FAMILY" "$NFT_TABLE" >"$out" 2>/dev/null; then
    : >"$out"
  fi
}

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

nft_status() {
  if nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1; then
    local n
    n=$(nft list table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null | grep -c 'elements' || true)
    printf 'active table=%s/%s sets=%s' "$NFT_FAMILY" "$NFT_TABLE" "$n"
  else
    printf 'inactive'
  fi
}
