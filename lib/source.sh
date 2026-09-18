#!/usr/bin/env bash
# ip-allowlist source handling: fetch, parse, validate, canonicalize.
# Sourced by the main script; do not execute directly.

[[ -n "${_IP_ALLOWLIST_SOURCE_LOADED:-}" ]] && return 0
_IP_ALLOWLIST_SOURCE_LOADED=1

# ---------------------------------------------------------------------------
# IPv4 validation and arithmetic
# ---------------------------------------------------------------------------

# Return 0 if the argument is a valid dotted-quad IPv4 address.
valid_ipv4_dotted() {
  local ip="$1"
  local IFS=.
  local -a octets
  read -ra octets <<<"$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local o
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

# Return 0 if the argument is a valid IPv4 address or CIDR.
valid_ipv4_cidr() {
  local cidr="$1"
  local ip len
  if [[ "$cidr" == */* ]]; then
    [[ "$cidr" == */*/* ]] && return 1
    ip="${cidr%%/*}"
    len="${cidr##*/}"
    is_uint "$len" || return 1
    (( len >= 0 && len <= 32 )) || return 1
  else
    ip="$cidr"
  fi
  valid_ipv4_dotted "$ip"
}

# Convert a dotted-quad IPv4 address to a 32-bit unsigned integer.
ipv4_to_int() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<<"$ip"
  printf '%s' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

# Convert a 32-bit unsigned integer to a dotted-quad IPv4 address.
int_to_ipv4() {
  local n="$1"
  printf '%s.%s.%s.%s' \
    "$(( (n >> 24) & 255 ))" \
    "$(( (n >> 16) & 255 ))" \
    "$(( (n >> 8) & 255 ))" \
    "$(( n & 255 ))"
}

# Normalize an IPv4 address or CIDR to canonical form (network address, /len).
ipv4_cidr_normalize() {
  local cidr="$1"
  local ip len n mask
  if [[ "$cidr" == */* ]]; then
    ip="${cidr%%/*}"
    len="${cidr##*/}"
  else
    ip="$cidr"
    len=32
  fi
  n=$(ipv4_to_int "$ip")
  if (( len == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
  fi
  n=$(( n & mask ))
  printf '%s/%s' "$(int_to_ipv4 "$n")" "$len"
}

# ---------------------------------------------------------------------------
# IPv6 validation, expansion, compression
# ---------------------------------------------------------------------------

# Expand an IPv6 address (no prefix) to 32 lowercase hex characters.
# Returns non-zero if invalid.
ipv6_expand() {
  local addr="${1,,}"

  # Convert an embedded dotted-quad tail into hex groups.
  if [[ "$addr" == *.* ]]; then
    local v4part="${addr##*:}"
    valid_ipv4_dotted "$v4part" || return 1
    local a b c d
    IFS=. read -r a b c d <<<"$v4part"
    local hex
    hex=$(printf '%02x%02x:%02x%02x' "$((10#$a))" "$((10#$b))" "$((10#$c))" "$((10#$d))")
    addr="${addr%:*}:$hex"
  fi

  local head tail
  local -a hgroups=() tgroups=()
  local -a groups=()

  if [[ "$addr" == *"::"* ]]; then
    head="${addr%%::*}"
    tail="${addr#*::}"
    [[ "$tail" == *"::"* ]] && return 1
    [[ -n "$head" ]] && IFS=: read -ra hgroups <<<"$head"
    [[ -n "$tail" ]] && IFS=: read -ra tgroups <<<"$tail"
    local total=$(( ${#hgroups[@]} + ${#tgroups[@]} ))
    (( total <= 7 )) || return 1
    local missing=$(( 8 - total ))
    local i
    for i in "${hgroups[@]}"; do groups+=("$i"); done
    for (( i = 0; i < missing; i++ )); do groups+=("0"); done
    for i in "${tgroups[@]}"; do groups+=("$i"); done
  else
    IFS=: read -ra groups <<<"$addr"
    (( ${#groups[@]} == 8 )) || return 1
  fi

  local g out=""
  for g in "${groups[@]}"; do
    [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    out+=$(printf '%04x' "0x$g")
  done
  printf '%s' "$out"
}

# Compress 32 hex characters into canonical IPv6 notation.
ipv6_compress() {
  local hex="$1"
  local -a g=()
  local i
  for (( i = 0; i < 8; i++ )); do
    g+=("${hex:$((i * 4)):4}")
  done

  local best_start=-1 best_len=0
  local cur_start=-1 cur_len=0
  for (( i = 0; i < 8; i++ )); do
    if [[ "${g[i]}" == "0000" ]]; then
      if (( cur_start < 0 )); then
        cur_start=$i
        cur_len=1
      else
        cur_len=$(( cur_len + 1 ))
      fi
      if (( cur_len > best_len )); then
        best_len=$cur_len
        best_start=$cur_start
      fi
    else
      cur_start=-1
      cur_len=0
    fi
  done
  if (( best_len < 2 )); then
    best_start=-1
    best_len=0
  fi

  local out=""
  if (( best_start < 0 )); then
    for (( i = 0; i < 8; i++ )); do
      if [[ -n "$out" ]]; then out+=":"; fi
      out+=$(printf '%x' "0x${g[i]}")
    done
  else
    for (( i = 0; i < best_start; i++ )); do
      if [[ -n "$out" ]]; then out+=":"; fi
      out+=$(printf '%x' "0x${g[i]}")
    done
    out+="::"
    for (( i = best_start + best_len; i < 8; i++ )); do
      out+=$(printf '%x' "0x${g[i]}")
      if (( i < 7 )); then out+=":"; fi
    done
  fi
  printf '%s' "$out"
}

# Return 0 if the argument is a valid IPv6 address or CIDR.
valid_ipv6_cidr() {
  local cidr="$1"
  local ip len
  if [[ "$cidr" == */* ]]; then
    [[ "$cidr" == */*/* ]] && return 1
    ip="${cidr%%/*}"
    len="${cidr##*/}"
    is_uint "$len" || return 1
    (( len >= 0 && len <= 128 )) || return 1
  else
    ip="$cidr"
  fi
  ipv6_expand "$ip" >/dev/null
}

# Normalize an IPv6 address or CIDR to canonical compressed form.
ipv6_cidr_normalize() {
  local cidr="$1"
  local ip len expanded
  if [[ "$cidr" == */* ]]; then
    ip="${cidr%%/*}"
    len="${cidr##*/}"
  else
    ip="$cidr"
    len=128
  fi
  expanded=$(ipv6_expand "$ip") || return 1
  printf '%s/%s' "$(ipv6_compress "$expanded")" "$len"
}

# ---------------------------------------------------------------------------
# Generic CIDR helpers
# ---------------------------------------------------------------------------

# Return 0 if the argument is a valid IPv4 or IPv6 address/CIDR.
valid_cidr() {
  if [[ "$1" == *:* ]]; then
    valid_ipv6_cidr "$1"
  else
    valid_ipv4_cidr "$1"
  fi
}

# ---------------------------------------------------------------------------
# Rule parameters: ports, protocol, address families
# ---------------------------------------------------------------------------

# Return 0 if the argument is a valid TCP/UDP port number.
valid_port_number() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Return 0 for "any", "all", an empty value, or a comma/space separated list
# of port numbers and ranges (lo-hi).
valid_ports_spec() {
  local spec="${1,,}"
  case "$spec" in
    any|all|"") return 0 ;;
  esac
  local -a parts=()
  local IFS=','
  read -ra parts <<<"${spec// /,}"
  local p lo hi
  for p in "${parts[@]}"; do
    [[ -n "$p" ]] || continue
    if [[ "$p" == *-* ]]; then
      lo="${p%-*}"
      hi="${p#*-}"
      valid_port_number "$lo" || return 1
      valid_port_number "$hi" || return 1
      (( 10#$lo <= 10#$hi )) || return 1
    else
      valid_port_number "$p" || return 1
    fi
  done
  return 0
}

# Normalize a ports spec to "any" or a sorted, unique comma separated list.
normalize_ports() {
  local spec="${1,,}"
  case "$spec" in
    any|all|"") printf 'any'; return 0 ;;
  esac
  local -a parts=()
  local IFS=','
  read -ra parts <<<"${spec// /,}"
  local -a out=()
  local p lo hi
  for p in "${parts[@]}"; do
    [[ -n "$p" ]] || continue
    if [[ "$p" == *-* ]]; then
      lo=$(( 10#${p%-*} ))
      hi=$(( 10#${p#*-} ))
      out+=("${lo}-${hi}")
    else
      out+=("$(( 10#$p ))")
    fi
  done
  if (( ${#out[@]} == 0 )); then
    printf 'any'
    return 0
  fi
  local joined
  joined=$(printf '%s\n' "${out[@]}" | sort -u | paste -sd, -)
  printf '%s' "$joined"
}

# Return 0 for any/all/tcp/udp/tcp+udp (comma forms accepted).
valid_protocol_spec() {
  case "${1,,}" in
    any|all|tcp|udp|tcp+udp|udp+tcp|tcp,udp|udp,tcp) return 0 ;;
    *) return 1 ;;
  esac
}

# Normalize a protocol spec to any|tcp|udp|tcp+udp.
normalize_protocol() {
  case "${1,,}" in
    any|all|"") printf 'any' ;;
    tcp) printf 'tcp' ;;
    udp) printf 'udp' ;;
    tcp+udp|udp+tcp|tcp,udp|udp,tcp) printf 'tcp+udp' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Print the L4 protocols a rule must match, space separated.
# Empty output means "match all traffic" (no protocol restriction).
# Usage: effective_protocols <normalized_protocol> <normalized_ports>
effective_protocols() {
  local protocol="$1" ports="$2"
  if [[ "$ports" == "any" ]]; then
    case "$protocol" in
      any) printf '' ;;
      tcp+udp) printf 'tcp udp' ;;
      *) printf '%s' "$protocol" ;;
    esac
  else
    case "$protocol" in
      any|tcp+udp) printf 'tcp udp' ;;
      *) printf '%s' "$protocol" ;;
    esac
  fi
}

# Replace range separators for ufw (uses "lo:hi").
ports_to_ufw() {
  printf '%s' "${1//-/:}"
}

# Print one port/range per line from a normalized ports spec.
# Usage: ports_lines <normalized_ports>
ports_lines() {
  [[ "$1" == "any" ]] && return 0
  printf '%s\n' "${1//,/$'\n'}"
}

# Read one key from a source's rule spec sidecar, with a default.
# Usage: rule_spec_get <state_dir> <name> <key> <default>
rule_spec_get() {
  local f="$1/rules/$2.conf" key="$3" def="$4" line
  if [[ -f "$f" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "$key="* ]]; then
        printf '%s' "${line#*=}"
        return 0
      fi
    done <"$f"
  fi
  printf '%s' "$def"
}

# Hash a source's entries together with its effective rule parameters, so that
# changing allow_ports/allow_protocol/enable_ipv4/enable_ipv6 is treated as a
# change even when the fetched data is identical.
# Usage: source_effective_hash <state_dir> <name> <ports> <protocol> <ipv4> <ipv6>
source_effective_hash() {
  local sd="$1" name="$2" ports="$3" protocol="$4" ipv4="$5" ipv6="$6"
  local tmp
  tmp=$(tmpfile "effhash-${name}")
  {
    cat -- "$sd/current/${name}.ips" 2>/dev/null || true
    printf 'ports=%s\nprotocol=%s\nipv4=%s\nipv6=%s\n' "$ports" "$protocol" "$ipv4" "$ipv6"
  } >"$tmp"
  hash_file "$tmp"
}

# ---------------------------------------------------------------------------
# IPv4 range merging
# ---------------------------------------------------------------------------

# Emit the minimal set of CIDRs covering [start, end].
range_to_cidrs() {
  local start="$1" end="$2"
  while (( start <= end )); do
    local maxsize=32
    if (( start != 0 )); then
      local tz=0 x=$start
      while (( (x & 1) == 0 && tz < 32 )); do
        tz=$(( tz + 1 ))
        x=$(( x >> 1 ))
      done
      maxsize=$tz
    fi
    local rem=$(( end - start + 1 ))
    local size=0
    while (( (1 << size) <= rem )); do
      size=$(( size + 1 ))
    done
    size=$(( size - 1 ))
    if (( maxsize > size )); then maxsize=$size; fi
    printf '%s/%s\n' "$(int_to_ipv4 "$start")" "$(( 32 - maxsize ))"
    start=$(( start + (1 << maxsize) ))
  done
}

# Read normalized IPv4 CIDRs from stdin; emit merged minimal CIDRs.
ipv4_merge_cidrs() {
  local cidr ip len n start end
  local -a ranges=()
  while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    ip="${cidr%%/*}"
    len="${cidr##*/}"
    n=$(ipv4_to_int "$ip")
    if (( len == 0 )); then
      start=0
    else
      start=$(( n & ((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF) ))
    fi
    end=$(( start + (1 << (32 - len)) - 1 ))
    ranges+=("$start $end")
  done

  [[ ${#ranges[@]} -eq 0 ]] && return 0

  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "${ranges[@]}" | sort -n -k1,1)

  local cur_s="" cur_e="" s e
  for entry in "${sorted[@]}"; do
    s="${entry%% *}"
    e="${entry##* }"
    if [[ -z "$cur_s" ]]; then
      cur_s="$s"
      cur_e="$e"
      continue
    fi
    if (( s <= cur_e + 1 )); then
      if (( e > cur_e )); then cur_e="$e"; fi
    else
      range_to_cidrs "$cur_s" "$cur_e"
      cur_s="$s"
      cur_e="$e"
    fi
  done
  if [[ -n "$cur_s" ]]; then
    range_to_cidrs "$cur_s" "$cur_e"
  fi
}

# ---------------------------------------------------------------------------
# Canonicalization pipeline
# ---------------------------------------------------------------------------

# Read raw/candidate text from stdin and write canonical entries to stdout.
# Output: sorted, deduplicated, one entry per line. IPv4 entries merged.
canonicalize_stream() {
  local line token
  local -a v4=() v6=() v6sort=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line=$(trim "$line")
    [[ -z "$line" ]] && continue
    local -a toks=()
    IFS=$' \t,' read -ra toks <<<"$line"
    for token in "${toks[@]}"; do
      token=$(trim "$token")
      [[ -z "$token" ]] && continue
      case "$token" in
        *:*)
          if valid_ipv6_cidr "$token"; then
            v6+=("$(ipv6_cidr_normalize "$token")")
          else
            log_debug "ignoring invalid IPv6 entry: $token"
          fi
          ;;
        *.*)
          if valid_ipv4_cidr "$token"; then
            v4+=("$(ipv4_cidr_normalize "$token")")
          else
            log_debug "ignoring invalid IPv4 entry: $token"
          fi
          ;;
        *)
          log_debug "ignoring unrecognized entry: $token"
          ;;
      esac
    done
  done

  # IPv4: dedupe, sort numerically, merge overlapping/adjacent ranges.
  if [[ ${#v4[@]} -gt 0 ]]; then
    local -a v4uniq=()
    mapfile -t v4uniq < <(printf '%s\n' "${v4[@]}" | sort -u)
    printf '%s\n' "${v4uniq[@]}" | ipv4_merge_cidrs
  fi

  # IPv6: dedupe, sort by expanded form, preserve canonical compressed output.
  if [[ ${#v6[@]} -gt 0 ]]; then
    local c expanded
    local -a keyed=()
    for c in "${v6[@]}"; do
      expanded=$(ipv6_expand "${c%%/*}")
      keyed+=("$expanded $c")
    done
    mapfile -t v6sort < <(printf '%s\n' "${keyed[@]}" | sort -u -k1,1)
    local entry
    for entry in "${v6sort[@]}"; do
      printf '%s\n' "${entry#* }"
    done
  fi
}

# Count lines in a file (or empty string).
count_lines() {
  local file="$1"
  [[ -f "$file" ]] || { echo 0; return 0; }
  local n
  n=$(wc -l <"$file")
  printf '%s' "$(( n ))"
}

# ---------------------------------------------------------------------------
# Source configuration
# ---------------------------------------------------------------------------

# Load a source config file into the named associative array.
# Applies defaults and validates required keys.
# Usage: source_load_config <array_name> <file>
source_load_config() {
  local -n _src="$1"
  local file="$2"
  _src=()
  kv_load_file "$1" "$file"

  # Defaults
  _src[enabled]="${_src[enabled]:-true}"
  _src[min_entries]="${_src[min_entries]:-1}"
  _src[max_shrink_ratio]="${_src[max_shrink_ratio]:-0.5}"

  local name="${_src[name]:-}"
  local type="${_src[type]:-}"

  [[ -n "$name" ]] || die "source $file: missing required key 'name'"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "source $file: invalid name '$name' (use letters, digits, _ and -)"
  [[ -n "$type" ]] || die "source $file: missing required key 'type'"
  case "$type" in
    http|file) ;;
    *) die "source $file: invalid type '$type' (expected http or file)" ;;
  esac

  _src[enabled]=$(normalize_bool "${_src[enabled]}")
  case "${_src[enabled]}" in
    true|false) ;;
    *) die "source $file: invalid enabled value '${_src[enabled]}'" ;;
  esac

  is_uint "${_src[min_entries]}" || die "source $file: min_entries must be a non-negative integer"
  [[ "${_src[max_shrink_ratio]}" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] \
    || die "source $file: max_shrink_ratio must be between 0 and 1"
  if [[ -n "${_src[update_interval]:-}" ]]; then
    is_uint "${_src[update_interval]}" || die "source $file: update_interval must be a non-negative integer"
  fi

  case "$type" in
    http)
      [[ -n "${_src[urls]:-}" ]] || die "source $file: http source requires 'urls'"
      ;;
    file)
      [[ -n "${_src[file_path]:-}" ]] || die "source $file: file source requires 'file_path'"
      ;;
  esac

  _src[source_file]="$file"
}

# List enabled source config files, sorted by name.
# Usage: source_list_files <sources_dir>
source_list_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.conf; do
    [[ -e "$f" ]] || continue
    printf '%s\n' "$f"
  done | sort
}

# ---------------------------------------------------------------------------
# Source fetch
# ---------------------------------------------------------------------------

# Fetch raw content for a source. Usage: source_fetch <array_name_in_scope>
# Reads the associative array named by $1 (by reference is awkward here, so we
# accept explicit fields).
# Usage: source_fetch <type> <urls_or_path> <base_dir>
source_fetch() {
  local type="$1" target="$2" base_dir="$3"

  case "$type" in
    http)
      local -a urls=()
      local IFS=','
      read -ra urls <<<"$target"
      local url
      for url in "${urls[@]}"; do
        url=$(trim "$url")
        [[ -z "$url" ]] && continue
        case "$url" in
          http://*|https://*) ;;
          *) log_error "invalid URL (must be http/https): $url"; return 1 ;;
        esac
        log_debug "fetching $url"
        if ! http_fetch "$url"; then
          log_error "failed to fetch $url"
          return 1
        fi
        printf '\n'
      done
      ;;
    file)
      local path
      path=$(resolve_path "$base_dir" "$target")
      if [[ ! -f "$path" ]]; then
        log_error "source file not found: $path"
        return 1
      fi
      log_debug "reading $path"
      cat -- "$path"
      ;;
    *)
      log_error "unsupported source type: $type"
      return 1
      ;;
  esac
  return 0
}

# Resolve a source's fetch target from its config array.
# Usage: source_target <array_name>
# shellcheck disable=SC2178
source_target() {
  local -n _st="$1"
  if [[ "${_st[type]}" == "http" ]]; then
    printf '%s' "${_st[urls]}"
  else
    printf '%s' "${_st[file_path]}"
  fi
}

# ---------------------------------------------------------------------------
# Source processing
# ---------------------------------------------------------------------------

# Fetch, canonicalize, and validate one source, writing canonical entries to
# <out_file>. Compares against <old_file> (if present) for shrink warnings.
# Returns non-zero on any per-source failure; callers decide how to handle it.
# Usage: source_build <array_name> <base_dir> <out_file> <old_file>
# shellcheck disable=SC2178
source_build() {
  local -n _sb="$1"
  local base_dir="$2" out_file="$3" old_file="$4"
  local name="${_sb[name]}"

  local raw canonical target
  raw=$(tmpfile "src-${name}")
  canonical=$(tmpfile "canon-${name}")
  target=$(source_target "$1")

  if ! source_fetch "${_sb[type]}" "$target" "$base_dir" >"$raw"; then
    log_error "source $name: fetch failed"
    return 1
  fi

  if ! canonicalize_stream <"$raw" >"$canonical"; then
    log_error "source $name: canonicalization failed"
    return 1
  fi

  local n
  n=$(count_lines "$canonical")
  local min="${_sb[min_entries]}"
  if (( n < min )); then
    log_error "source $name: found $n entries, below min_entries=$min"
    return 1
  fi

  local old_count=0 ratio
  if [[ -f "$old_file" ]]; then
    old_count=$(count_lines "$old_file")
  fi
  if (( old_count > 0 && n < old_count )); then
    ratio=$(awk -v n="$n" -v o="$old_count" 'BEGIN { printf "%.4f", (o - n) / o }')
    local max="${_sb[max_shrink_ratio]}"
    if awk -v r="$ratio" -v m="$max" 'BEGIN { exit !(r > m) }'; then
      log_warn "source $name: entries shrank ${ratio} (${old_count} -> ${n}), exceeds max_shrink_ratio=$max"
    fi
  fi

  atomic_install "$canonical" "$out_file" "0644"
  _sb[_entries]="$n"
  return 0
}

# Process one source and install its canonical entries into the state dir.
# Usage: source_process <array_name> <state_dir> <base_dir>
# shellcheck disable=SC2178
source_process() {
  local -n _sp="$1"
  local state_dir="$2" base_dir="$3"
  local name="${_sp[name]}"
  local current_file="$state_dir/current/${name}.ips"

  mkdir -p -- "$state_dir/current"
  if ! source_build "$1" "$base_dir" "$current_file" "$current_file"; then
    return 1
  fi

  _sp[_current_file]="$current_file"
  log_info "source $name: ${_sp[_entries]} entries"
  return 0
}

# Split a canonical entries file into v4 and v6 counts.
count_v4_v6() {
  local file="$1"
  local n4=0 n6=0 line
  [[ -f "$file" ]] || { printf '0 0'; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then
      n6=$(( n6 + 1 ))
    else
      n4=$(( n4 + 1 ))
    fi
  done <"$file"
  printf '%s %s' "$n4" "$n6"
}

# Check whether a source is due for update based on its interval.
# Usage: source_is_due <state_dir> <name> <interval_seconds>
source_is_due() {
  local state_dir="$1" name="$2" interval="$3"
  local stamp="$state_dir/status/${name}.last_run"
  [[ -f "$stamp" ]] || return 0
  local last now age
  last=$(cat -- "$stamp" 2>/dev/null || echo 0)
  is_uint "$last" || return 0
  now=$(date +%s)
  age=$(( now - last ))
  (( age >= interval ))
}
