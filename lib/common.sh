#!/usr/bin/env bash
# ip-allowlist common utilities
# Sourced by the main script; do not execute directly.

# Guard against double-sourcing
[[ -n "${_IP_ALLOWLIST_COMMON_LOADED:-}" ]] && return 0
_IP_ALLOWLIST_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly IP_ALLOWLIST_DEFAULT_UA="ip-allowlist"
readonly IP_ALLOWLIST_HTTP_TIMEOUT=30
readonly IP_ALLOWLIST_HTTP_RETRIES=3
readonly IP_ALLOWLIST_LOCK_TIMEOUT=60
readonly IP_ALLOWLIST_MAX_DOWNLOAD_BYTES=10485760 # 10 MiB

# Log levels (ordered)
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

# ---------------------------------------------------------------------------
# Global runtime state (set by main / config loader)
# ---------------------------------------------------------------------------

LOG_LEVEL="${LOG_LEVEL:-$LOG_LEVEL_INFO}"
LOG_TARGET="${LOG_TARGET:-auto}"
LOG_FORMAT="${LOG_FORMAT:-text}"
LOG_FILE="${LOG_FILE:-}"
# Do not clobber values already set by the CLI argument parser.
QUIET="${QUIET:-0}"
RUN_ID="${RUN_ID:-}"
DRY_RUN="${DRY_RUN:-0}"
LOG_COMPONENT="${LOG_COMPONENT:-main}"

# Derived log routing (set by log_configure_targets from LOG_TARGET).
LOG_EMIT_STDOUT=1
LOG_EMIT_FILE=0
LOG_EMIT_SYSLOG=0
LOG_SILENT=0

# Resolve LOG_TARGET (a comma separated list or a single value) into the
# LOG_EMIT_* flags. Valid values: auto, stdout, file, syslog, none.
log_configure_targets() {
  LOG_EMIT_STDOUT=0
  LOG_EMIT_FILE=0
  LOG_EMIT_SYSLOG=0
  LOG_SILENT=0
  local item
  local -a items=()
  IFS=',' read -ra items <<<"${LOG_TARGET:-auto}"
  for item in "${items[@]}"; do
    item=$(trim "$item")
    case "$item" in
      auto)   LOG_EMIT_STDOUT=1 ;;
      stdout) LOG_EMIT_STDOUT=1 ;;
      file)   LOG_EMIT_FILE=1 ;;
      syslog) LOG_EMIT_SYSLOG=1 ;;
      none)   LOG_SILENT=1 ;;
      "")     ;;
      *)      die "config: invalid log_target entry '$item'" ;;
    esac
  done
  if (( LOG_SILENT == 1 )); then
    LOG_EMIT_STDOUT=0
    LOG_EMIT_FILE=0
    LOG_EMIT_SYSLOG=0
  fi
  if (( LOG_EMIT_FILE == 1 )) && [[ -z "$LOG_FILE" ]]; then
    die "config: log_target includes 'file' but log_file is empty"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# Print a message to stdout unless quiet.
out() {
  [[ $QUIET -eq 1 ]] && return 0
  printf '%s\n' "$*"
}

# Print an error message to stderr.
err() {
  printf '%s\n' "$*" >&2
}

# Print a fatal error and exit.
die() {
  err "ERROR: $*"
  exit 1
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# Map a level name to its numeric value.
log_level_value() {
  case "$1" in
    debug) echo "$LOG_LEVEL_DEBUG" ;;
    info)  echo "$LOG_LEVEL_INFO" ;;
    warn)  echo "$LOG_LEVEL_WARN" ;;
    error) echo "$LOG_LEVEL_ERROR" ;;
    *)     echo "$LOG_LEVEL_INFO" ;;
  esac
}

# Map a level name to a syslog priority.
log_syslog_priority() {
  case "$1" in
    debug) echo "debug" ;;
    info)  echo "info" ;;
    warn)  echo "warning" ;;
    error) echo "err" ;;
    *)     echo "info" ;;
  esac
}

# Emit a log record. Usage: log_at <level> <message...>
log_at() {
  local level="$1"; shift
  local level_value
  level_value=$(log_level_value "$level")
  [[ $level_value -lt $LOG_LEVEL ]] && return 0
  [[ $QUIET -eq 1 && $level_value -lt $LOG_LEVEL_WARN ]] && return 0

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local record

  if [[ "$LOG_FORMAT" == "json" ]]; then
    local escaped
    escaped=$(json_escape "$*")
    record=$(printf '{"ts":"%s","level":"%s","component":"%s","run_id":"%s","msg":"%s"}' \
      "$ts" "$level" "$(json_escape "$LOG_COMPONENT")" "$RUN_ID" "$escaped")
  else
    record=$(printf '%s [%s] (%s/%s) %s' "$ts" "${level^^}" "$LOG_COMPONENT" "$RUN_ID" "$*")
  fi

  if (( LOG_SILENT == 1 )); then
    return 0
  fi
  if (( LOG_EMIT_STDOUT == 1 )); then
    err "$record"
  fi

  if (( LOG_EMIT_SYSLOG == 1 )) && have logger; then
    printf '%s\n' "$record" \
      | logger -t ip-allowlist -p "user.$(log_syslog_priority "$level")" 2>/dev/null || true
  fi
  if (( LOG_EMIT_FILE == 1 )) && [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$record" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

log_debug() { log_at debug "$@"; }
log_info()  { log_at info "$@"; }
log_warn()  { log_at warn "$@"; }
log_error() { log_at error "$@"; }

# ---------------------------------------------------------------------------
# JSON escaping
# ---------------------------------------------------------------------------

# Escape a string for inclusion in a JSON string literal.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# General helpers
# ---------------------------------------------------------------------------

# True if the named command exists.
have() {
  command -v "$1" >/dev/null 2>&1
}

# Trim leading/trailing whitespace.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Return 0 if argument is a positive integer.
is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# Normalise boolean-ish value to true/false.
normalize_bool() {
  case "$1" in
    true|1|yes|on) echo "true" ;;
    false|0|no|off) echo "false" ;;
    *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# KV parsing
# ---------------------------------------------------------------------------

# Read a config file into the caller's associative array / variables.
# Usage: kv_load_file <array_name> <file>
# Assigns ARRAY[key]=value. Comments (#) and blank lines ignored.
# Strict key=value only; no shell expansion, no eval.
kv_load_file() {
  local -n _kv_out="$1"
  local file="$2"
  local line key value lineno=0

  [[ -f "$file" ]] || die "config file not found: $file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    # Strip comments (only at start of a key portion; keep # inside values)
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*=(.*)$ ]]; then
      die "config: malformed line $lineno in $file: $line"
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value=$(trim "$value")
    # A quoted value wins; anything after the closing quote is a comment.
    # Otherwise strip an unquoted trailing comment (quote a value to keep '#').
    if [[ "$value" =~ ^\"([^\"]*)\" ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'([^\']*)\' ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value="${value%%#*}"
      value=$(trim "$value")
    fi
    _kv_out["$key"]="$value"
  done <"$file"
}

# Reject keys that are not in the allowed list.
# Usage: kv_reject_unknown <array_name> <file> <allowed> <allowed> ...
kv_reject_unknown() {
  local -n _kv_in="$1"; shift
  local file="$1"; shift
  local key allowed ok
  for key in "${!_kv_in[@]}"; do
    ok=0
    for allowed in "$@"; do
      if [[ "$key" == "$allowed" ]]; then ok=1; break; fi
    done
    (( ok == 1 )) || die "config: unknown key '$key' in $file"
  done
}

# Parse a duration into seconds. Accepts a bare number (seconds) or a
# number with an s/m/h/d/w suffix, e.g. 30, 15m, 1d, 2h, 1w.
# Usage: parse_duration <value>
parse_duration() {
  local raw="$1" num unit
  if [[ "$raw" =~ ^([0-9]+)([smhdw]?)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    die "config: invalid duration '$raw' (use <n> or <n>s|m|h|d|w)"
  fi
  case "$unit" in
    "")  printf '%s' "$(( 10#$num ))" ;;
    s)   printf '%s' "$(( 10#$num ))" ;;
    m)   printf '%s' "$(( 10#$num * 60 ))" ;;
    h)   printf '%s' "$(( 10#$num * 3600 ))" ;;
    d)   printf '%s' "$(( 10#$num * 86400 ))" ;;
    w)   printf '%s' "$(( 10#$num * 604800 ))" ;;
    *)   die "config: invalid duration unit in '$raw'" ;;
  esac
}

# ---------------------------------------------------------------------------
# Path handling
# ---------------------------------------------------------------------------

# Resolve a possibly-relative path against a base directory.
# Usage: resolve_path <base_dir> <path>
resolve_path() {
  local base="$1" path="$2"
  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
  else
    printf '%s/%s' "${base%/}" "$path"
  fi
}

# Return 0 if a path contains no whitespace.
path_has_no_spaces() {
  [[ "$1" != *[[:space:]]* ]]
}

# ---------------------------------------------------------------------------
# Temporary files
# ---------------------------------------------------------------------------

# Create a secure temporary file and echo its path.
# Usage: tmpfile <prefix>
TMP_FILES=()
tmpfile() {
  local prefix="${1:-ip-allowlist}"
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || die "mktemp failed"
  TMP_FILES+=("$f")
  printf '%s' "$f"
}

# Create a secure temporary directory and echo its path.
TMP_DIRS=()
tmpdir() {
  local prefix="${1:-ip-allowlist}"
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || die "mktemp -d failed"
  TMP_DIRS+=("$d")
  printf '%s' "$d"
}

# Clean up all registered temporary files/directories.
cleanup_tmp() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "$f" && -e "$f" ]] && rm -f -- "$f"
  done
  for f in "${TMP_DIRS[@]:-}"; do
    [[ -n "$f" && -d "$f" ]] && rm -rf -- "$f"
  done
  TMP_FILES=()
  TMP_DIRS=()
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------

LOCK_FD=""

# Acquire an exclusive flock on the given lock file. Blocks up to timeout.
# Usage: lock_acquire <lock_file>
lock_acquire() {
  local lock_file="$1"
  local lock_dir
  lock_dir=$(dirname -- "$lock_file")
  mkdir -p -- "$lock_dir"
  exec {LOCK_FD}>"$lock_file" || die "cannot open lock file: $lock_file"
  if ! flock -w "${LOCK_WAIT:-$IP_ALLOWLIST_LOCK_TIMEOUT}" "$LOCK_FD"; then
    die "another instance is running (lock: $lock_file)"
  fi
  printf '%s' "$$" >"$lock_file" 2>/dev/null || true
}

# Try to acquire the lock without blocking. Returns non-zero when busy.
# Usage: lock_try <lock_file>
lock_try() {
  local lock_file="$1"
  local lock_dir
  lock_dir=$(dirname -- "$lock_file")
  mkdir -p -- "$lock_dir"
  exec {LOCK_FD}>"$lock_file" || return 1
  if ! flock -n "$LOCK_FD"; then
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_FD=""
    return 1
  fi
  printf '%s' "$$" >"$lock_file" 2>/dev/null || true
  return 0
}

# Release the lock if held.
lock_release() {
  if [[ -n "$LOCK_FD" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_FD=""
  fi
}

# ---------------------------------------------------------------------------
# Atomic file writes
# ---------------------------------------------------------------------------

# Atomically install content from a source file to a destination path.
# Usage: atomic_install <src> <dest> [mode]
atomic_install() {
  local src="$1" dest="$2" mode="${3:-0644}"
  local dest_dir
  dest_dir=$(dirname -- "$dest")
  mkdir -p -- "$dest_dir"
  local staged
  staged="$dest_dir/.$(basename -- "$dest").staged.$$"
  cp -- "$src" "$staged" || die "failed to stage $dest"
  chmod "$mode" "$staged" || true
  mv -f -- "$staged" "$dest" || die "failed to install $dest"
}

# ---------------------------------------------------------------------------
# HTTP fetch
# ---------------------------------------------------------------------------

# Fetch a URL to stdout using curl or wget with timeout and retries.
# Usage: http_fetch <url>
http_fetch() {
  local url="$1"
  local ua="${IP_ALLOWLIST_DEFAULT_UA}/${IP_ALLOWLIST_VERSION:-unknown}"

  if have curl; then
    curl -fsSL \
      --user-agent "$ua" \
      --connect-timeout "$IP_ALLOWLIST_HTTP_TIMEOUT" \
      --max-time "$((IP_ALLOWLIST_HTTP_TIMEOUT * 3))" \
      --retry "$IP_ALLOWLIST_HTTP_RETRIES" \
      --retry-delay 2 \
      --max-filesize "$IP_ALLOWLIST_MAX_DOWNLOAD_BYTES" \
      "$url"
  elif have wget; then
    wget -q -O - \
      --user-agent="$ua" \
      --timeout="$IP_ALLOWLIST_HTTP_TIMEOUT" \
      --tries="$IP_ALLOWLIST_HTTP_RETRIES" \
      "$url"
  else
    die "neither curl nor wget is available"
  fi
}

# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------

# Compute a stable SHA-256 hash of a file.
hash_file() {
  local file="$1"
  if have sha256sum; then
    sha256sum -- "$file" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 -- "$file" | awk '{print $1}'
  else
    die "no sha256 utility available (need sha256sum or shasum)"
  fi
}

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

# Locate and read the version file, searching upward from the script dir.
read_version() {
  local dir="${IP_ALLOWLIST_ROOT:-}"
  if [[ -z "$dir" ]]; then
    dir=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  fi
  if [[ -f "$dir/version.txt" ]]; then
    tr -d '[:space:]' <"$dir/version.txt"
  else
    echo "0.0.0"
  fi
}
