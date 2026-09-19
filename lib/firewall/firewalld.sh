#!/usr/bin/env bash
# ip-allowlist firewalld backend.
#
# Each source gets one firewalld ipset per address family (hash:net) named
# "ia-<source>-v4|v6-<hash>", referenced by a rich rule in the target zone:
#
#   rule family="ipv4" source ipset="<name>" accept
#
# Sync removes the ip-allowlist rich rules and stale ipsets, recreates the
# desired ipsets with current entries, re-adds the rich rules, then reloads
# firewalld once. All changes are applied --permanent before the single reload.
#
# Sourced by the main script; do not execute directly.

[[ -n "${_IP_ALLOWLIST_FIREWALLD_LOADED:-}" ]] && return 0
_IP_ALLOWLIST_FIREWALLD_LOADED=1

FIREWALLD_ZONE="${FIREWALLD_ZONE:-}"
readonly FIREWALLD_IPSET_PREFIX="ia"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

firewalld_available() {
  have firewall-cmd
}

firewalld_running() {
  firewall-cmd --state >/dev/null 2>&1
}

# Ready = firewalld running; when systemd is the init system, the unit must be
# active as well (containers that start firewalld directly are accepted).
firewalld_service_ready() {
  firewalld_running || return 1
  if have systemctl && [[ -d /run/systemd/system ]]; then
    systemctl is-active --quiet firewalld 2>/dev/null || return 1
  fi
  return 0
}

firewalld_validate() {
  firewalld_available || die "firewalld backend selected but 'firewall-cmd' is not installed"
  firewalld_running || die "firewalld backend selected but firewalld is not running"
}

# Resolve the target zone: configured value, else the firewalld default zone.
firewalld_target_zone() {
  if [[ -n "$FIREWALLD_ZONE" ]]; then
    printf '%s' "$FIREWALLD_ZONE"
    return 0
  fi
  firewall-cmd --get-default-zone 2>/dev/null
}

# Build a firewalld ipset name for a source and family (v4|v6).
# Kept deterministic and within the ipset 31-character name limit.
firewalld_set_name() {
  local source="$1" fam="$2"
  local safe hash
  safe="${source//[^A-Za-z0-9_]/_}"
  safe="${safe:0:17}"
  hash=$(hash_file <(printf '%s' "$safe") 2>/dev/null || true)
  hash="${hash:0:6}"
  [[ -n "$hash" ]] || hash="000000"
  printf '%s-%s-%s-%s' "$FIREWALLD_IPSET_PREFIX" "$safe" "$fam" "$hash"
}

firewalld_supports_add_file() {
  firewall-cmd --help 2>&1 | grep -q -- '--add-entries-from-file'
}

firewalld_family_type() {
  [[ "$1" == "v6" ]] && printf 'inet6' || printf 'inet'
}

firewalld_family_rule() {
  [[ "$1" == "v6" ]] && printf 'ipv6' || printf 'ipv4'
}

# ---------------------------------------------------------------------------
# Rich rules
# ---------------------------------------------------------------------------

# Remove every ip-allowlist rich rule from the zone.
firewalld_remove_rich_rules() {
  local zone="$1" rule
  while IFS= read -r rule || [[ -n "$rule" ]]; do
    [[ -n "$rule" ]] || continue
    [[ "$rule" == *"ipset=\"${FIREWALLD_IPSET_PREFIX}-"* ]] || continue
    firewall-cmd --permanent --zone="$zone" --remove-rich-rule="$rule" >/dev/null 2>&1 || true
  done < <(firewall-cmd --permanent --zone="$zone" --list-rich-rules 2>/dev/null)
}

# Add the rich rule(s) for one set, honouring ports and protocols.
# Usage: firewalld_add_rules <zone> <set_name> <v4|v6> <ports> <protocols>
firewalld_add_rules() {
  local zone="$1" name="$2" fam="$3" ports="$4" protocols="$5"
  local rfamily
  rfamily=$(firewalld_family_rule "$fam")

  if [[ -z "$protocols" ]]; then
    firewall-cmd --permanent --zone="$zone" \
      --add-rich-rule="rule family=\"$rfamily\" source ipset=\"$name\" accept" >/dev/null 2>&1
    return 0
  fi

  local proto range
  for proto in $protocols; do
    if [[ "$ports" == "any" ]]; then
      firewall-cmd --permanent --zone="$zone" \
        --add-rich-rule="rule family=\"$rfamily\" source ipset=\"$name\" protocol value=\"$proto\" accept" >/dev/null 2>&1 \
        || return 1
    else
      for range in ${ports//,/ }; do
        [[ -n "$range" ]] || continue
        firewall-cmd --permanent --zone="$zone" \
          --add-rich-rule="rule family=\"$rfamily\" source ipset=\"$name\" port port=\"$range\" protocol=\"$proto\" accept" >/dev/null 2>&1 \
          || return 1
      done
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Ipsets
# ---------------------------------------------------------------------------

firewalld_create_set() {
  local name="$1" fam="$2" entries="$3"
  local fwfamily
  fwfamily=$(firewalld_family_type "$fam")

  firewall-cmd --permanent --delete-ipset="$name" >/dev/null 2>&1 || true
  if ! firewall-cmd --permanent --new-ipset="$name" --type=hash:net --family="$fwfamily" >/dev/null 2>&1; then
    log_error "firewalld: failed to create ipset $name"
    return 1
  fi

  if firewalld_supports_add_file; then
    if ! firewall-cmd --permanent --ipset="$name" --add-entries-from-file="$entries" >/dev/null 2>&1; then
      log_error "firewalld: failed to add entries to ipset $name"
      return 1
    fi
  else
    local entry
    while IFS= read -r entry || [[ -n "$entry" ]]; do
      [[ -n "$entry" ]] || continue
      firewall-cmd --permanent --ipset="$name" --add-entry="$entry" >/dev/null 2>&1 || true
    done <"$entries"
  fi
  return 0
}

# Delete ip-allowlist ipsets that are not in the desired list.
firewalld_remove_stale_sets() {
  local -a desired=("$@")
  local existing d keep
  local -a sets=()
  read -ra sets < <(firewall-cmd --permanent --get-ipsets 2>/dev/null)
  for existing in "${sets[@]:-}"; do
    [[ -n "$existing" ]] || continue
    [[ "$existing" == "${FIREWALLD_IPSET_PREFIX}-"* ]] || continue
    keep=0
    for d in "${desired[@]:-}"; do
      [[ -n "$d" ]] || continue
      if [[ "$d" == "$existing" ]]; then keep=1; break; fi
    done
    if (( keep == 0 )); then
      firewall-cmd --permanent --delete-ipset="$existing" >/dev/null 2>&1 || true
    fi
  done
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

# Reconcile firewalld ipsets and rich rules with all current source entries.
# Usage: firewalld_apply <state_dir>
firewalld_apply() {
  local state_dir="$1"
  local zone
  zone=$(firewalld_target_zone)
  if [[ -z "$zone" ]]; then
    log_error "firewalld: could not determine target zone"
    return 1
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "firewalld: dry-run, would reconcile ipsets in zone $zone"
    return 0
  fi

  # If the configured zone changed, clear our rich rules from the old zone.
  local old_zone
  old_zone=$(state_get_key "firewall.firewalld-zone")
  if [[ -n "$old_zone" && "$old_zone" != "$zone" ]]; then
    log_info "firewalld: zone changed from $old_zone to $zone; removing old rich rules"
    firewalld_remove_rich_rules "$old_zone"
  fi

  firewalld_remove_rich_rules "$zone"

  local -a desired=()
  local f base fam entries name ports protocol ipv4 ipv6 protocols
  for f in "$state_dir"/current/*.ips; do
    [[ -e "$f" ]] || continue
    base=$(basename -- "$f" .ips)
    ports=$(rule_spec_get "$state_dir" "$base" allow_ports any)
    protocol=$(rule_spec_get "$state_dir" "$base" allow_protocol any)
    ipv4=$(rule_spec_get "$state_dir" "$base" enable_ipv4 true)
    ipv6=$(rule_spec_get "$state_dir" "$base" enable_ipv6 true)
    protocols=$(effective_protocols "$protocol" "$ports")
    for fam in v4 v6; do
      if [[ "$fam" == "v4" ]]; then
        [[ "$ipv4" == "true" ]] || continue
      else
        [[ "$ipv6" == "true" ]] || continue
      fi
      entries=$(tmpfile "fw-${base}-${fam}")
      if [[ "$fam" == "v4" ]]; then
        grep -v ':' "$f" >"$entries" 2>/dev/null || true
      else
        grep ':' "$f" >"$entries" 2>/dev/null || true
      fi
      [[ -s "$entries" ]] || continue
      name=$(firewalld_set_name "$base" "$fam")
      desired+=("$name")
      if ! firewalld_create_set "$name" "$fam" "$entries"; then
        return 1
      fi
      if ! firewalld_add_rules "$zone" "$name" "$fam" "$ports" "$protocols"; then
        log_error "firewalld: failed to add rich rules for $name"
        return 1
      fi
    done
  done

  firewalld_remove_stale_sets "${desired[@]:-}"

  if ! firewall-cmd --reload >/dev/null 2>&1; then
    log_error "firewalld: reload failed"
    return 1
  fi
  state_set_key "firewall.firewalld-zone" "$zone"
  log_info "firewalld: applied ${#desired[@]} ipset(s) in zone $zone"
  return 0
}

# Verify that every expected ipset exists with the expected entry count.
# Usage: firewalld_verify <state_dir>
firewalld_verify() {
  local state_dir="$1"
  local -a sets=()
  read -ra sets < <(firewall-cmd --permanent --get-ipsets 2>/dev/null)
  local f base fam entries name expected actual
  for f in "$state_dir"/current/*.ips; do
    [[ -e "$f" ]] || continue
    base=$(basename -- "$f" .ips)
    for fam in v4 v6; do
      entries=$(tmpfile "fw-verify-${base}-${fam}")
      if [[ "$fam" == "v4" ]]; then
        grep -v ':' "$f" >"$entries" 2>/dev/null || true
      else
        grep ':' "$f" >"$entries" 2>/dev/null || true
      fi
      [[ -s "$entries" ]] || continue
      name=$(firewalld_set_name "$base" "$fam")
      if ! printf '%s\n' "${sets[@]:-}" | grep -Fxq -- "$name"; then
        log_error "firewalld verify: ipset $name missing"
        return 1
      fi
      expected=$(wc -l <"$entries")
      actual=$(firewall-cmd --ipset="$name" --get-entries 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l)
      if (( actual != expected )); then
        log_error "firewalld verify: ipset $name has $actual entries, expected $expected"
        return 1
      fi
    done
  done
  return 0
}

# ---------------------------------------------------------------------------
# Snapshot / cleanup / status
# ---------------------------------------------------------------------------

firewalld_snapshot() {
  local out="$1" zone
  zone=$(firewalld_target_zone)
  {
    firewall-cmd --permanent --zone="$zone" --list-all 2>/dev/null || true
    firewall-cmd --permanent --get-ipsets 2>/dev/null || true
  } >"$out"
}

firewalld_cleanup() {
  local zone existing
  zone=$(firewalld_target_zone)
  [[ -n "$zone" ]] && firewalld_remove_rich_rules "$zone"
  local -a sets=()
  read -ra sets < <(firewall-cmd --permanent --get-ipsets 2>/dev/null)
  for existing in "${sets[@]:-}"; do
    [[ -n "$existing" ]] || continue
    [[ "$existing" == "${FIREWALLD_IPSET_PREFIX}-"* ]] || continue
    firewall-cmd --permanent --delete-ipset="$existing" >/dev/null 2>&1 || true
  done
  firewall-cmd --reload >/dev/null 2>&1 || true
  log_info "firewalld: removed managed ipsets and rich rules"
}

firewalld_status() {
  if firewalld_available && firewalld_running; then
    local n zone
    n=$(firewall-cmd --permanent --get-ipsets 2>/dev/null | tr ' ' '\n' | grep -c "^${FIREWALLD_IPSET_PREFIX}-" || true)
    zone=$(firewalld_target_zone)
    printf 'active ipsets=%s zone=%s' "$n" "$zone"
  else
    printf 'inactive'
  fi
}
