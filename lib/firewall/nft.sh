#!/usr/bin/env bash
# ip-allowlist nftables backend.
# Sourced by the main script; do not execute directly.

[[ -n "${_IP_ALLOWLIST_NFT_LOADED:-}" ]] && return 0
_IP_ALLOWLIST_NFT_LOADED=1

NFT_TABLE="${NFT_TABLE:-ip-allowlist}"
NFT_FAMILY="${NFT_FAMILY:-inet}"
NFT_PRIORITY="${NFT_PRIORITY:--1}"

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

# Return 0 if nftables is available and usable.
nft_available() {
  have nft
}

# Validate the nft backend environment.
nft_validate() {
  nft_available || die "nftables backend selected but 'nft' is not installed"
}

# ---------------------------------------------------------------------------
# Ruleset generation
# ---------------------------------------------------------------------------

# Emit an nft set definition. Usage: nft_emit_set <set_name> <type> <entries...>
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

# Emit one accept rule for a source set, honouring ports and protocols.
# Usage: nft_emit_rule <ip|ip6> <set_name> <ports> <protocols>
nft_emit_rule() {
  local family="$1" setname="$2" ports="$3" protocols="$4"
  if [[ -z "$protocols" ]]; then
    printf '    %s saddr @%s accept\n' "$family" "$setname"
    return 0
  fi
  local proto
  for proto in $protocols; do
    if [[ "$ports" == "any" ]]; then
      printf '    %s saddr @%s meta l4proto %s accept\n' "$family" "$setname" "$proto"
    else
      printf '    %s saddr @%s %s dport { %s } accept\n' "$family" "$setname" "$proto" "${ports//,/, }"
    fi
  done
}

# Generate the full nft ruleset for all current sources into a file.
# Usage: nft_generate_ruleset <state_dir> <output_file>
nft_generate_ruleset() {
  local state_dir="$1" out="$2"
  local name entries base ports protocol ipv4 ipv6 protocols

  local -a set_names=() set_types=() set_entries=()
  local -a rule_families=() rule_sets=() rule_ports=() rule_protocols=()

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
      if [[ "$line" == *:* ]]; then
        v6+=("$line")
      else
        v4+=("$line")
      fi
    done <"$entries"

    if [[ "$ipv4" == "true" ]] && (( ${#v4[@]} > 0 )); then
      set_names+=("v4_${name}")
      set_types+=("ipv4_addr")
      set_entries+=("$(printf '%s\n' "${v4[@]}")")
      rule_families+=("ip")
      rule_sets+=("v4_${name}")
      rule_ports+=("$ports")
      rule_protocols+=("$protocols")
    fi
    if [[ "$ipv6" == "true" ]] && (( ${#v6[@]} > 0 )); then
      set_names+=("v6_${name}")
      set_types+=("ipv6_addr")
      set_entries+=("$(printf '%s\n' "${v6[@]}")")
      rule_families+=("ip6")
      rule_sets+=("v6_${name}")
      rule_ports+=("$ports")
      rule_protocols+=("$protocols")
    fi
  done

  {
    printf 'table %s %s {}\n' "$NFT_FAMILY" "$NFT_TABLE"
    printf 'delete table %s %s\n' "$NFT_FAMILY" "$NFT_TABLE"
    printf 'table %s %s {\n' "$NFT_FAMILY" "$NFT_TABLE"

    local i
    for (( i = 0; i < ${#set_names[@]}; i++ )); do
      local -a items=()
      mapfile -t items <<<"${set_entries[i]}"
      nft_emit_set "${set_names[i]}" "${set_types[i]}" "${items[@]}"
    done

    if (( ${#set_names[@]} > 0 )); then
      printf '  chain input {\n'
      printf '    type filter hook input priority %s; policy accept;\n' "$NFT_PRIORITY"
      for (( i = 0; i < ${#rule_sets[@]}; i++ )); do
        nft_emit_rule "${rule_families[i]}" "${rule_sets[i]}" "${rule_ports[i]}" "${rule_protocols[i]}"
      done
      printf '  }\n'
    fi

    printf '}\n'
  } >"$out"
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

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
}

# ---------------------------------------------------------------------------
# Snapshot / cleanup / status
# ---------------------------------------------------------------------------

# Save the current nft table to a file (for rollback/audit).
nft_snapshot() {
  local out="$1"
  if ! nft list table "$NFT_FAMILY" "$NFT_TABLE" >"$out" 2>/dev/null; then
    : >"$out"
  fi
}

# Remove all ip-allowlist nft objects.
nft_cleanup() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "nft: dry-run, would delete table $NFT_FAMILY $NFT_TABLE"
    return 0
  fi
  if nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1; then
    nft delete table "$NFT_FAMILY" "$NFT_TABLE" || log_warn "nft: failed to delete table"
    log_info "nft: deleted table $NFT_FAMILY $NFT_TABLE"
  fi
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
