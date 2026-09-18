#!/usr/bin/env bash
# ip-allowlist installer. Performs an atomic staged install/upgrade.
set -euo pipefail

PREFIX="/usr/local"
CONFIG_DIR="/etc/ip-allowlist"
SOURCES_DIR="$CONFIG_DIR/sources.d"
STATE_DIR="/var/lib/ip-allowlist"
SYSTEMD_DIR="/etc/systemd/system"
LOGROTATE_DIR="/etc/logrotate.d"

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ;;  # accepted for compatibility; install.sh never prompts
    --prefix=*) PREFIX="${arg#*=}" ;;
    -h|--help)
      cat <<'EOF'
Usage: install.sh [--yes] [--prefix=/usr/local]

Installs ip-allowlist to the given prefix, installs default config,
systemd units and logrotate configuration, then enables the timer.
EOF
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

INSTALL_LIB="$PREFIX/lib/ip-allowlist"
INSTALL_BIN="$PREFIX/sbin"
SYMLINK="$INSTALL_BIN/ip-allowlist"

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "must be run as root (try: sudo $0)"
  fi
}

SCRIPT_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGING=""

check_prereqs() {
  local missing=()
  command -v bash >/dev/null 2>&1 || missing+=("bash")
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing+=("curl or wget")
  fi
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    missing+=("sha256sum or shasum")
  fi
  (( ${#missing[@]} == 0 )) || die "missing required commands: ${missing[*]}"
}

stage_files() {
  local staging="$1"
  mkdir -p "$staging"
  install -d -m 0755 "$staging/lib" "$staging/lib/firewall"

  install -m 0755 "$SCRIPT_DIR/ip-allowlist" "$staging/ip-allowlist"
  install -m 0644 "$SCRIPT_DIR/lib/common.sh"   "$staging/lib/common.sh"
  install -m 0644 "$SCRIPT_DIR/lib/source.sh"   "$staging/lib/source.sh"
  install -m 0644 "$SCRIPT_DIR/lib/state.sh"    "$staging/lib/state.sh"
  install -m 0644 "$SCRIPT_DIR/lib/fail2ban.sh" "$staging/lib/fail2ban.sh"
  install -m 0644 "$SCRIPT_DIR/lib/firewall/nft.sh" "$staging/lib/firewall/nft.sh"
  install -m 0644 "$SCRIPT_DIR/lib/firewall/ufw.sh" "$staging/lib/firewall/ufw.sh"
  install -m 0644 "$SCRIPT_DIR/lib/firewall/firewalld.sh" "$staging/lib/firewall/firewalld.sh"

  if [[ -f "$SCRIPT_DIR/version.txt" ]]; then
    install -m 0644 "$SCRIPT_DIR/version.txt" "$staging/version.txt"
  else
    printf '0.0.0\n' >"$staging/version.txt"
  fi

  install -m 0755 "$SCRIPT_DIR/install.sh"   "$staging/install.sh"
  install -m 0755 "$SCRIPT_DIR/uninstall.sh" "$staging/uninstall.sh"
}

atomic_swap_dir() {
  local staging="$1" target="$2"
  local parent
  parent="$(dirname -- "$target")"
  mkdir -p "$parent"
  local backup="${target}.bak.$$"
  if [[ -e "$target" ]]; then
    mv -- "$target" "$backup"
  fi
  if ! mv -- "$staging" "$target"; then
    [[ -e "$backup" ]] && mv -- "$backup" "$target"
    die "failed to install to $target"
  fi
  rm -rf -- "$backup"
}

install_binary() {
  install -d -m 0755 "$INSTALL_BIN"
  ln -sfn "$INSTALL_LIB/ip-allowlist" "$SYMLINK"
}

install_config() {
  install -d -m 0750 "$CONFIG_DIR" "$SOURCES_DIR"
  if [[ ! -f "$CONFIG_DIR/config.conf" ]]; then
    if [[ -f "$SCRIPT_DIR/config/config.conf.example" ]]; then
      install -m 0640 "$SCRIPT_DIR/config/config.conf.example" "$CONFIG_DIR/config.conf"
      log "installed default config: $CONFIG_DIR/config.conf"
    else
      warn "config template not found; create $CONFIG_DIR/config.conf manually"
    fi
  else
    log "existing config preserved: $CONFIG_DIR/config.conf"
  fi
  if [[ ! -f "$SOURCES_DIR/cloudflare.conf" && -f "$SCRIPT_DIR/sources.d/cloudflare.conf.example" ]]; then
    install -m 0640 "$SCRIPT_DIR/sources.d/cloudflare.conf.example" "$SOURCES_DIR/cloudflare.conf"
    log "installed default source: $SOURCES_DIR/cloudflare.conf"
  fi
}

install_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; skipping systemd unit installation"
    return 0
  fi
  if [[ ! -f "$SCRIPT_DIR/systemd/ip-allowlist.service" ]]; then
    warn "systemd unit files not found; skipping"
    return 0
  fi
  install -d -m 0755 "$SYSTEMD_DIR"
  install -m 0644 "$SCRIPT_DIR/systemd/ip-allowlist.service" "$SYSTEMD_DIR/ip-allowlist.service"
  install -m 0644 "$SCRIPT_DIR/systemd/ip-allowlist.timer"   "$SYSTEMD_DIR/ip-allowlist.timer"
  install -m 0644 "$SCRIPT_DIR/systemd/ip-allowlist-boot.service" "$SYSTEMD_DIR/ip-allowlist-boot.service"

  # Honour update_on_boot from the installed config.
  if grep -qiE '^[[:space:]]*update_on_boot[[:space:]]*=[[:space:]]*(true|1|yes|on)' "$CONFIG_DIR/config.conf" 2>/dev/null; then
    : >"$CONFIG_DIR/update-on-boot"
  else
    rm -f -- "$CONFIG_DIR/update-on-boot"
  fi

  systemctl daemon-reload || warn "systemctl daemon-reload failed"
  systemctl enable --now ip-allowlist.timer || warn "failed to enable ip-allowlist.timer"
  if [[ -f "$CONFIG_DIR/update-on-boot" ]]; then
    systemctl enable ip-allowlist-boot.service || warn "failed to enable ip-allowlist-boot.service"
  fi
  log "systemd timer enabled"
}

install_logrotate() {
  [[ -d "$LOGROTATE_DIR" ]] || return 0
  cat >"$LOGROTATE_DIR/ip-allowlist" <<'EOF'
/var/log/ip-allowlist.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
  log "installed logrotate configuration"
}

install_state_dir() {
  install -d -m 0700 "$STATE_DIR"
}

main() {
  require_root
  check_prereqs

  log "installing ip-allowlist from $SCRIPT_DIR"

  STAGING="$(mktemp -d "${TMPDIR:-/tmp}/ip-allowlist-stage.XXXXXX")"
  trap 'rm -rf -- "${STAGING:-}"' EXIT

  stage_files "$STAGING"
  atomic_swap_dir "$STAGING" "$INSTALL_LIB"
  STAGING=""
  install_binary
  install_state_dir
  install_config
  install_systemd
  install_logrotate

  log "installation complete"
  log "edit $CONFIG_DIR/config.conf and run: ip-allowlist sync"
}

main
