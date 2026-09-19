#!/usr/bin/env bash
# ip-allowlist fail2ban integration: union ignoreip drop-in management.
# Sourced by the main script; do not execute directly.

[[ -n "${_IP_ALLOWLIST_FAIL2BAN_LOADED:-}" ]] && return 0
_IP_ALLOWLIST_FAIL2BAN_LOADED=1

# Default fail2ban locations.
FAIL2BAN_JAIL_CONF="${FAIL2BAN_JAIL_CONF:-/etc/fail2ban/jail.conf}"
FAIL2BAN_JAIL_LOCAL="${FAIL2BAN_JAIL_LOCAL:-/etc/fail2ban/jail.local}"
FAIL2BAN_JAIL_D="${FAIL2BAN_JAIL_D:-/etc/fail2ban/jail.d}"

# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------

# Extract candidate IP tokens from ignoreip lines in a file.
# Handles backslash line continuations and comma/space separators.
fail2ban_extract_ips_from_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local line buffer="" collecting=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if (( collecting == 0 )); then
      # Match an ignoreip assignment anywhere in the line.
      if [[ "$line" =~ ^[[:space:]]*ignoreip[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        buffer="${BASH_REMATCH[1]}"
        collecting=1
      else
        continue
      fi
    else
      buffer+="$line"
    fi

    if [[ "$buffer" == *"\\" ]]; then
      buffer="${buffer%\\}"
      continue
    fi
    collecting=0
    # Strip inline comments.
    buffer="${buffer%%#*}"
    local IFS=$' \t,'
    local -a toks=()
    read -ra toks <<<"$buffer"
    local t
    for t in "${toks[@]}"; do
      t=$(trim "$t")
      [[ -z "$t" ]] && continue
      printf '%s\n' "$t"
    done
    buffer=""
  done <"$file"
}

# Collect all user-defined ignoreip entries, excluding our own drop-in.
# Usage: fail2ban_collect_user_ips <our_dropin_path>
fail2ban_collect_user_ips() {
  local own="$1"
  local -a files=()

  [[ -f "$FAIL2BAN_JAIL_CONF" ]] && files+=("$FAIL2BAN_JAIL_CONF")
  [[ -f "$FAIL2BAN_JAIL_LOCAL" ]] && files+=("$FAIL2BAN_JAIL_LOCAL")

  if [[ -d "$FAIL2BAN_JAIL_D" ]]; then
    local f
    for f in "$FAIL2BAN_JAIL_D"/*.conf "$FAIL2BAN_JAIL_D"/*.local; do
      [[ -e "$f" ]] || continue
      files+=("$f")
    done
  fi

  local f
  for f in "${files[@]}"; do
    # Never read our own drop-in.
    if [[ "$(readlink -f -- "$f" 2>/dev/null)" == "$(readlink -f -- "$own" 2>/dev/null)" ]]; then
      continue
    fi
    fail2ban_extract_ips_from_file "$f"
  done
}

# Normalize a bare IP or CIDR for fail2ban union purposes.
# Accepts IPv4/IPv6 with optional CIDR; echoes canonical entry or nothing.
fail2ban_normalize_entry() {
  local entry="$1"
  local cidr="$entry"
  if [[ "$entry" != */* ]]; then
    if [[ "$entry" == *:* ]]; then
      cidr="${entry}/128"
    else
      cidr="${entry}/32"
    fi
  fi
  if valid_cidr "$cidr"; then
    if [[ "$cidr" == *:* ]]; then
      ipv6_cidr_normalize "$cidr"
    else
      ipv4_cidr_normalize "$cidr"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Render / apply
# ---------------------------------------------------------------------------

# Render the fail2ban drop-in content for the given union file.
# Usage: fail2ban_render <union_file>
fail2ban_render() {
  local union_file="$1"
  printf '# Managed by ip-allowlist - do not edit\n'
  printf '# Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '[DEFAULT]\n'
  local entries
  entries=$(tr '\n' ' ' <"$union_file" | sed 's/[[:space:]]*$//')
  printf 'ignoreip = %s\n' "$entries"
}

# Compute the union of all current source entries and extra user entries.
# Usage: fail2ban_build_union <state_dir> <own_dropin> <output_file>
# shellcheck disable=SC2129
fail2ban_build_union() {
  local state_dir="$1" own="$2" output="$3"
  local combined
  combined=$(tmpfile "f2b-combined")

  : >"$combined"

  # Current canonical entries from every source.
  local f
  for f in "$state_dir"/current/*.ips; do
    [[ -e "$f" ]] || continue
    cat -- "$f" >>"$combined"
  done

  # User-defined entries, normalized. Skipped when merging is disabled.
  local raw entry norm
  if [[ "${FAIL2BAN_MERGE_EXISTING:-true}" == "true" ]]; then
    raw=$(tmpfile "f2b-user")
    fail2ban_collect_user_ips "$own" >"$raw"
    while IFS= read -r entry || [[ -n "$entry" ]]; do
      entry=$(trim "$entry")
      [[ -z "$entry" ]] && continue
      norm=$(fail2ban_normalize_entry "$entry")
      [[ -n "$norm" ]] && printf '%s\n' "$norm" >>"$combined"
    done <"$raw"
  fi

  canonicalize_stream <"$combined" >"$output"
}

# True if the fail2ban drop-in is currently present.
fail2ban_dropin_present() {
  local path="$1"
  [[ -f "$path" ]]
}

# Apply the fail2ban drop-in. If the union is empty, remove the drop-in.
# Usage: fail2ban_apply <state_dir> <dropin_path>
fail2ban_apply() {
  local state_dir="$1" dropin="$2"

  local dropin_dir
  dropin_dir=$(dirname -- "$dropin")
  if [[ ! -d "$dropin_dir" ]]; then
    log_warn "fail2ban: $dropin_dir does not exist; skipping drop-in (is fail2ban installed?)"
    return 0
  fi
  if ! ( : >"$dropin_dir/.ip-allowlist.wtest" ) 2>/dev/null; then
    log_warn "fail2ban: $dropin_dir is not writable; skipping drop-in"
    return 0
  fi
  rm -f -- "$dropin_dir/.ip-allowlist.wtest"

  local union
  union="$state_dir/fail2ban/union.ips"
  mkdir -p -- "$state_dir/fail2ban"
  fail2ban_build_union "$state_dir" "$dropin" "$union"

  local count
  count=$(count_lines "$union")
  local hash
  hash=$(hash_file "$union")

  if (( count == 0 )); then
    if fail2ban_dropin_present "$dropin"; then
      log_info "fail2ban: union empty, removing drop-in $dropin"
      rm -f -- "$dropin"
    fi
    state_set_fail2ban_hash ""
    printf '%s' "removed"
    return 0
  fi

  if [[ "$hash" == "$(state_fail2ban_hash)" ]] && fail2ban_dropin_present "$dropin"; then
    log_debug "fail2ban: drop-in unchanged ($hash)"
    printf '%s' "unchanged"
    return 0
  fi

  local rendered backup=""
  rendered=$(tmpfile "f2b-render")
  fail2ban_render "$union" >"$rendered"
  if fail2ban_dropin_present "$dropin"; then
    backup=$(tmpfile "f2b-backup")
    cp -- "$dropin" "$backup"
  fi
  atomic_install "$rendered" "$dropin" "0644"

  # Validate the resulting fail2ban configuration before keeping it.
  if have fail2ban-client; then
    if ! fail2ban-client -t >/dev/null 2>&1; then
      log_error "fail2ban: configuration test failed; restoring previous drop-in"
      if [[ -n "$backup" ]]; then
        atomic_install "$backup" "$dropin" "0644"
      else
        rm -f -- "$dropin"
      fi
      return 1
    fi
  fi

  state_set_fail2ban_hash "$hash"
  log_info "fail2ban: wrote $count entries to $dropin"
  printf '%s' "updated"
}

# Remove the drop-in managed by ip-allowlist.
fail2ban_cleanup() {
  local dropin="$1"
  if fail2ban_dropin_present "$dropin"; then
    rm -f -- "$dropin"
    log_info "fail2ban: removed $dropin"
  fi
  state_set_fail2ban_hash ""
}

# Reload fail2ban if it is running.
fail2ban_reload() {
  [[ "${FAIL2BAN_RELOAD:-true}" == "true" ]] || return 0
  if have fail2ban-client && fail2ban-client ping >/dev/null 2>&1; then
    if fail2ban-client reload >/dev/null 2>&1; then
      log_info "fail2ban: reloaded"
    else
      log_warn "fail2ban: reload failed"
    fi
  else
    log_debug "fail2ban: not running, skipping reload"
  fi
}
