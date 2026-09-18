#!/usr/bin/env bash
# ip-allowlist uninstaller.
set -euo pipefail

PREFIX="/usr/local"
CONFIG_DIR="/etc/ip-allowlist"
STATE_DIR="/var/lib/ip-allowlist"
SYSTEMD_DIR="/etc/systemd/system"
LOGROTATE_DIR="/etc/logrotate.d"
PURGE=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --prefix=*) PREFIX="${arg#*=}" ;;
    -h|--help)
      cat <<'EOF'
Usage: uninstall.sh [--purge] [--yes] [--prefix=/usr/local]

Removes ip-allowlist binaries and systemd units.
  --purge   Also remove config, state and logs.
EOF
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

INSTALL_LIB="$PREFIX/lib/ip-allowlist"
SYMLINK="$PREFIX/sbin/ip-allowlist"

log()  { printf '[uninstall] %s\n' "$*"; }
warn() { printf '[uninstall] WARNING: %s\n' "$*" >&2; }
die()  { printf '[uninstall] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "must be run as root (try: sudo $0)"
  fi
}

stop_services() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl disable --now ip-allowlist.timer 2>/dev/null || true
  systemctl disable --now ip-allowlist-boot.service 2>/dev/null || true
  systemctl stop ip-allowlist.service 2>/dev/null || true
  rm -f -- \
    "$SYSTEMD_DIR/ip-allowlist.service" \
    "$SYSTEMD_DIR/ip-allowlist.timer" \
    "$SYSTEMD_DIR/ip-allowlist-boot.service"
  systemctl daemon-reload 2>/dev/null || true
  log "removed systemd units"
}

read_config_value() {
  local key="$1" default="$2"
  local conf="$CONFIG_DIR/config.conf"
  [[ -f "$conf" ]] || { printf '%s' "$default"; return 0; }
  local value
  value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$conf" | tail -n1)
  value=$(printf '%s' "$value" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s' "${value:-$default}"
}

remove_firewall_state() {
  local nft_bin family table
  nft_bin=$(command -v nft 2>/dev/null || true)
  [[ -n "$nft_bin" ]] || return 0
  family=$(read_config_value firewall_table_family inet)
  table=$(read_config_value firewall_chain_name ip-allowlist)
  case "$family" in inet|ip|ip6) ;; *) family=inet ;; esac
  [[ "$table" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || table=ip-allowlist
  if nft list table "$family" "$table" >/dev/null 2>&1; then
    nft delete table "$family" "$table" 2>/dev/null || true
    log "removed nftables table $family $table"
  fi
}

remove_fail2ban_dropin() {
  local dropin="/etc/fail2ban/ip-allowlist.conf"
  if [[ -f "$dropin" ]]; then
    rm -f -- "$dropin"
    log "removed fail2ban drop-in $dropin"
    if command -v fail2ban-client >/dev/null 2>&1; then
      fail2ban-client reload >/dev/null 2>&1 || true
    fi
  fi
}

remove_files() {
  rm -f -- "$SYMLINK"
  rm -rf -- "$INSTALL_LIB"
  rm -f -- "$LOGROTATE_DIR/ip-allowlist"
  log "removed binaries"
}

purge_data() {
  rm -rf -- "$CONFIG_DIR" "$STATE_DIR"
  rm -f -- /var/log/ip-allowlist.log
  log "purged config, state and logs"
}

main() {
  require_root

  if (( ASSUME_YES == 0 )); then
    local extra=""
    (( PURGE == 1 )) && extra=" and purge all data"
    printf 'Uninstall ip-allowlist%s? [y/N] ' "$extra"
    local answer=""
    read -r answer || true
    case "$answer" in y|Y|yes|YES) ;; *) echo "aborted"; exit 0 ;; esac
  fi

  remove_firewall_state
  remove_fail2ban_dropin
  stop_services
  remove_files

  if (( PURGE == 1 )); then
    purge_data
  else
    log "config and state preserved (use --purge to remove)"
  fi

  log "uninstall complete"
}

main
