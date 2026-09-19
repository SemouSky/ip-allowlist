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

remove_firewall_state() {
  # Prefer the installed tool: it knows the configured backend and paths.
  if [[ -x "$SYMLINK" && -f "$CONFIG_DIR/config.conf" ]]; then
    "$SYMLINK" cleanup >/dev/null 2>&1 || true
  fi

  # nft tables (current and pre-rename names).
  local t
  if command -v nft >/dev/null 2>&1; then
    for t in ip_allowlist ip-allowlist; do
      if nft list table inet "$t" >/dev/null 2>&1; then
        nft delete table inet "$t" 2>/dev/null || true
        log "removed nftables table inet $t"
      fi
    done
  fi

  # ufw rules tagged with our comment.
  if command -v ufw >/dev/null 2>&1; then
    local line spec
    local -a argv=()
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == *"ip-allowlist:"* ]] || continue
      spec="${line#ufw }"
      read -ra argv <<<"$spec"
      ufw delete "${argv[@]}" >/dev/null 2>&1 || true
    done < <(ufw show added 2>/dev/null)
  fi

  # firewalld ipsets and rich rules created by ip-allowlist.
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    local z r s
    for z in $(firewall-cmd --get-zones 2>/dev/null); do
      while IFS= read -r r || [[ -n "$r" ]]; do
        [[ "$r" == *'ipset="ia-'* ]] || continue
        firewall-cmd --permanent --zone="$z" --remove-rich-rule="$r" >/dev/null 2>&1 || true
      done < <(firewall-cmd --permanent --zone="$z" --list-rich-rules 2>/dev/null)
    done
    while IFS= read -r s || [[ -n "$s" ]]; do
      [[ "$s" == ia-* ]] || continue
      firewall-cmd --permanent --delete-ipset="$s" >/dev/null 2>&1 || true
    done < <(firewall-cmd --permanent --get-ipsets 2>/dev/null | tr ' ' '\n')
    firewall-cmd --reload >/dev/null 2>&1 || true
    log "removed firewalld ip-allowlist ipsets and rich rules"
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
  rm -f -- /etc/cron.d/ip-allowlist
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

LOCK_FILE="${LOCK_FILE:-/run/ip-allowlist.lock}"
LOCK_FD=""
acquire_lock() {
  install -d -m 0700 "$(dirname -- "$LOCK_FILE")" 2>/dev/null || true
  exec {LOCK_FD}>"$LOCK_FILE" || die "cannot open lock file: $LOCK_FILE"
  if ! flock -w 30 "$LOCK_FD"; then
    die "another ip-allowlist instance is running (lock: $LOCK_FILE)"
  fi
}
release_lock() {
  if [[ -n "$LOCK_FD" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_FD=""
  fi
}

main() {
  require_root
  acquire_lock
  trap 'release_lock' EXIT

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
