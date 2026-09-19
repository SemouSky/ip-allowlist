#!/usr/bin/env bash
# ip-allowlist installer.
#
# Two modes:
#   1. Local: run from a checkout, i.e. this script sits next to ip-allowlist,
#      lib/, config/, systemd/.
#   2. Bootstrap: run when there is no local tree (for example
#      `curl -fsSL .../install.sh | sudo bash`). The project archive is
#      downloaded from the latest release (or the main branch as a fallback)
#      and installed from a temporary directory.
#
# Offline installs can use --from-dir DIR or --from-tarball FILE.
set -euo pipefail

REPO="${IP_ALLOWLIST_REPO:-SemouSky/ip-allowlist}"
PREFIX="/usr/local"
CONFIG_DIR="/etc/ip-allowlist"
SOURCES_DIR="$CONFIG_DIR/sources.d"
STATE_DIR="/var/lib/ip-allowlist"
SYSTEMD_DIR="/etc/systemd/system"
LOGROTATE_DIR="/etc/logrotate.d"

REQUEST_VERSION=""
FROM_TARBALL=""
FROM_DIR=""

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --prefix=DIR        Install prefix (default: /usr/local)
  --version VER       Install a specific release (default: latest release)
  --from-dir DIR      Install from an unpacked project tree
  --from-tarball FILE Install from a release tarball
  --yes, -y           Accepted for compatibility (never prompts)
  -h, --help          Show this help

Bootstrap example:
  curl -fsSL https://raw.githubusercontent.com/SemouSky/ip-allowlist/main/install.sh | sudo bash
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) shift ;;
    --prefix)
      shift; [[ $# -gt 0 ]] || { echo "--prefix requires a value" >&2; exit 64; }; PREFIX="$1"; shift ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --version)
      shift; [[ $# -gt 0 ]] || { echo "--version requires a value" >&2; exit 64; }; REQUEST_VERSION="$1"; shift ;;
    --version=*) REQUEST_VERSION="${1#*=}"; shift ;;
    --from-dir)
      shift; [[ $# -gt 0 ]] || { echo "--from-dir requires a value" >&2; exit 64; }; FROM_DIR="$1"; shift ;;
    --from-dir=*) FROM_DIR="${1#*=}"; shift ;;
    --from-tarball)
      shift; [[ $# -gt 0 ]] || { echo "--from-tarball requires a value" >&2; exit 64; }; FROM_TARBALL="$1"; shift ;;
    --from-tarball=*) FROM_TARBALL="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
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
    die "must be run as root (re-run with sudo)"
  fi
}

# Locate this script's directory when running from a file. When piped through
# bash, BASH_SOURCE is unset, so bootstrap mode is used instead.
SELF="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [[ -n "$SELF" && -f "$SELF" ]]; then
  SCRIPT_DIR="$(cd -P "$(dirname -- "$SELF")" && pwd)"
fi

SRC_DIR=""
WORK_DIR=""
ARCHIVE=""
STAGING=""

cleanup() {
  [[ -n "$STAGING" ]] && rm -rf -- "$STAGING"
  [[ -n "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"
  [[ -n "$ARCHIVE" ]] && rm -f -- "$ARCHIVE"
  release_lock
  return 0
}
trap cleanup EXIT

check_prereqs() {
  local missing=()
  command -v bash >/dev/null 2>&1 || missing+=("bash")
  if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    die "bash 4.4 or newer is required (found ${BASH_VERSION})"
  fi
  command -v tar >/dev/null 2>&1 || missing+=("tar")
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing+=("curl or wget")
  fi
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    missing+=("sha256sum or shasum")
  fi
  (( ${#missing[@]} == 0 )) || die "missing required commands: ${missing[*]}"
}

http_get() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 15 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O - --tries=3 --timeout=15 "$url"
  else
    die "neither curl nor wget is available"
  fi
}

download() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 15 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" --tries=3 --timeout=15 "$url"
  else
    die "neither curl nor wget is available"
  fi
}

latest_version() {
  local tag=""
  tag="$(http_get "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
    | sed 's/.*"\([^"]*\)"$/\1/')" || true
  printf '%s' "${tag#v}"
}

extract_archive() {
  local archive="$1" top="" d
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ip-allowlist-src.XXXXXX")"
  tar -xzf "$archive" -C "$WORK_DIR" || die "failed to extract $archive"
  for d in "$WORK_DIR"/*/; do
    [[ -d "$d" ]] || continue
    top="${d%/}"
    break
  done
  [[ -n "$top" ]] || die "unexpected archive layout in $archive"
  SRC_DIR="$top"
}

resolve_sources() {
  if [[ -n "$FROM_DIR" ]]; then
    [[ -f "$FROM_DIR/ip-allowlist" ]] || die "--from-dir is not an ip-allowlist tree: $FROM_DIR"
    SRC_DIR="$(cd -P "$FROM_DIR" && pwd)"
    return 0
  fi
  if [[ -n "$FROM_TARBALL" ]]; then
    [[ -f "$FROM_TARBALL" ]] || die "tarball not found: $FROM_TARBALL"
    extract_archive "$FROM_TARBALL"
    return 0
  fi
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/ip-allowlist" && -f "$SCRIPT_DIR/lib/common.sh" ]]; then
    SRC_DIR="$SCRIPT_DIR"
    return 0
  fi

  local ver="$REQUEST_VERSION" url
  if [[ -z "$ver" ]]; then
    ver="$(latest_version)"
  fi
  if [[ -z "$ver" ]]; then
    warn "no published release found; falling back to the main branch"
    url="https://github.com/${REPO}/archive/refs/heads/main.tar.gz"
  else
    url="https://github.com/${REPO}/archive/refs/tags/v${ver#v}.tar.gz"
  fi
  log "downloading $url"
  ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/ip-allowlist.XXXXXX.tar.gz")"
  download "$url" "$ARCHIVE" || die "download failed: $url"
  extract_archive "$ARCHIVE"
  rm -f -- "$ARCHIVE"
  ARCHIVE=""
  [[ -f "$SRC_DIR/ip-allowlist" ]] || die "downloaded archive is missing ip-allowlist"
}

syntax_check() {
  local f
  for f in \
    "$SRC_DIR/ip-allowlist" \
    "$SRC_DIR/lib/common.sh" \
    "$SRC_DIR/lib/source.sh" \
    "$SRC_DIR/lib/state.sh" \
    "$SRC_DIR/lib/fail2ban.sh" \
    "$SRC_DIR/lib/firewall/nft.sh" \
    "$SRC_DIR/lib/firewall/ufw.sh" \
    "$SRC_DIR/lib/firewall/firewalld.sh" \
    "$SRC_DIR/install.sh" \
    "$SRC_DIR/uninstall.sh"; do
    [[ -f "$f" ]] || die "missing expected file: $f"
    bash -n "$f" || die "syntax error in $f"
  done
}

stage_files() {
  local staging="$1"
  mkdir -p "$staging"
  install -d -m 0755 "$staging/lib" "$staging/lib/firewall"

  install -m 0755 "$SRC_DIR/ip-allowlist" "$staging/ip-allowlist"
  install -m 0644 "$SRC_DIR/lib/common.sh"   "$staging/lib/common.sh"
  install -m 0644 "$SRC_DIR/lib/source.sh"   "$staging/lib/source.sh"
  install -m 0644 "$SRC_DIR/lib/state.sh"    "$staging/lib/state.sh"
  install -m 0644 "$SRC_DIR/lib/fail2ban.sh" "$staging/lib/fail2ban.sh"
  install -m 0644 "$SRC_DIR/lib/firewall/nft.sh" "$staging/lib/firewall/nft.sh"
  install -m 0644 "$SRC_DIR/lib/firewall/ufw.sh" "$staging/lib/firewall/ufw.sh"
  install -m 0644 "$SRC_DIR/lib/firewall/firewalld.sh" "$staging/lib/firewall/firewalld.sh"

  if [[ -f "$SRC_DIR/version.txt" ]]; then
    install -m 0644 "$SRC_DIR/version.txt" "$staging/version.txt"
  else
    printf '0.0.0\n' >"$staging/version.txt"
  fi

  install -m 0755 "$SRC_DIR/install.sh"   "$staging/install.sh"
  install -m 0755 "$SRC_DIR/uninstall.sh" "$staging/uninstall.sh"
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
    if [[ -f "$SRC_DIR/config/config.conf.example" ]]; then
      install -m 0640 "$SRC_DIR/config/config.conf.example" "$CONFIG_DIR/config.conf"
      log "installed default config: $CONFIG_DIR/config.conf"
    else
      warn "config template not found; create $CONFIG_DIR/config.conf manually"
    fi
  else
    log "existing config preserved: $CONFIG_DIR/config.conf"
  fi
  if [[ ! -f "$SOURCES_DIR/cloudflare.conf" ]]; then
    local tmpl=""
    if [[ -f "$SRC_DIR/config/sources.d/cloudflare.conf.example" ]]; then
      tmpl="$SRC_DIR/config/sources.d/cloudflare.conf.example"
    elif [[ -f "$SRC_DIR/sources.d/cloudflare.conf.example" ]]; then
      tmpl="$SRC_DIR/sources.d/cloudflare.conf.example"
    fi
    if [[ -n "$tmpl" ]]; then
      install -m 0640 "$tmpl" "$SOURCES_DIR/cloudflare.conf"
      log "installed default source: $SOURCES_DIR/cloudflare.conf"
    fi
  fi
}

# Fall back to cron when systemd is unavailable.
install_cron() {
  local cron_dir="/etc/cron.d"
  [[ -d "$cron_dir" ]] || { warn "no /etc/cron.d; cannot schedule updates"; return 0; }
  local raw minutes backend
  raw=$(sed -n 's/^[[:space:]]*timer_interval[[:space:]]*=[[:space:]]*//p' "$CONFIG_DIR/config.conf" 2>/dev/null | tail -n1)
  raw=$(printf '%s' "$raw" | tr -d '\r' | tr -d '"'"'"'')
  minutes=15
  case "$raw" in
    *w) minutes=$(( ${raw%w} * 10080 )) ;;
    *d) minutes=$(( ${raw%d} * 1440 )) ;;
    *h) minutes=$(( ${raw%h} * 60 )) ;;
    *m) minutes=${raw%m} ;;
    '') ;;
    *) minutes=$(( raw / 60 )) ;;
  esac
  (( minutes >= 1 )) || minutes=1
  backend=$(sed -n 's/^[[:space:]]*firewall_backend[[:space:]]*=[[:space:]]*//p' "$CONFIG_DIR/config.conf" 2>/dev/null | tail -n1)
  backend=$(printf '%s' "$backend" | tr -d '\r' | tr -d '"'"'"'')
  {
    printf 'SHELL=/bin/sh\n'
    printf 'PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n'
    printf '*/%s * * * * root IP_ALLOWLIST_TIMER=1 /usr/local/sbin/ip-allowlist sync\n' "$minutes"
    if [[ "$backend" == "nft" ]]; then
      printf '@reboot root /usr/local/sbin/ip-allowlist apply-offline\n'
    fi
  } >"$cron_dir/ip-allowlist"
  chmod 0644 "$cron_dir/ip-allowlist"
  log "installed cron schedule (/etc/cron.d/ip-allowlist, every ${minutes}m)"
}

install_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; using cron for scheduling"
    rm -f -- "$SYSTEMD_DIR/ip-allowlist.service" "$SYSTEMD_DIR/ip-allowlist.timer" "$SYSTEMD_DIR/ip-allowlist-boot.service"
    install_cron
    return 0
  fi
  rm -f -- /etc/cron.d/ip-allowlist
  if [[ ! -f "$SRC_DIR/systemd/ip-allowlist.service" ]]; then
    warn "systemd unit files not found; skipping"
    return 0
  fi
  install -d -m 0755 "$SYSTEMD_DIR"
  install -m 0644 "$SRC_DIR/systemd/ip-allowlist.service" "$SYSTEMD_DIR/ip-allowlist.service"
  install -m 0644 "$SRC_DIR/systemd/ip-allowlist-boot.service" "$SYSTEMD_DIR/ip-allowlist-boot.service"

  # The timer interval comes from the config; regenerate the unit so changes to
  # timer_interval take effect on the next install/upgrade.
  local interval
  interval=$(sed -n 's/^[[:space:]]*timer_interval[[:space:]]*=[[:space:]]*//p' "$CONFIG_DIR/config.conf" 2>/dev/null | tail -n1)
  interval=$(printf '%s' "$interval" | tr -d '\r' | tr -d '"'"'"'')
  [[ "$interval" =~ ^[0-9]+[smhdw]?$ ]] || interval=15m
  cat >"$SYSTEMD_DIR/ip-allowlist.timer" <<EOF
[Unit]
Description=Run ip-allowlist periodically
Documentation=https://github.com/SemouSky/ip-allowlist

[Timer]
OnBootSec=2min
OnUnitActiveSec=${interval}
AccuracySec=1min
RandomizedDelaySec=30s
Persistent=true
Unit=ip-allowlist.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$SYSTEMD_DIR/ip-allowlist.timer"

  # The boot rebuild service only applies to the nft backend and is gated by
  # update_on_boot.
  local backend=""
  backend=$(sed -n 's/^[[:space:]]*firewall_backend[[:space:]]*=[[:space:]]*//p' "$CONFIG_DIR/config.conf" 2>/dev/null | tail -n1)
  backend=$(printf '%s' "$backend" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ "$backend" == "nft" ]] \
    && grep -qiE '^[[:space:]]*update_on_boot[[:space:]]*=[[:space:]]*(true|1|yes|on)' "$CONFIG_DIR/config.conf" 2>/dev/null; then
    : >"$CONFIG_DIR/update-on-boot"
  else
    rm -f -- "$CONFIG_DIR/update-on-boot"
  fi

  # Warn when the system's own nftables ruleset flushes everything at boot.
  if [[ -f /etc/nftables.conf ]] && grep -qiE '^[[:space:]]*flush[[:space:]]+ruleset' /etc/nftables.conf; then
    warn "/etc/nftables.conf contains 'flush ruleset'; it may remove the ip_allowlist table at boot"
  fi

  systemctl daemon-reload || warn "systemctl daemon-reload failed"
  systemctl enable --now ip-allowlist.timer || warn "failed to enable ip-allowlist.timer"
  if [[ -f "$CONFIG_DIR/update-on-boot" ]]; then
    systemctl enable ip-allowlist-boot.service || warn "failed to enable ip-allowlist-boot.service"
  else
    systemctl disable ip-allowlist-boot.service 2>/dev/null || true
  fi
  log "systemd timer enabled"
}

install_logrotate() {
  [[ -d "$LOGROTATE_DIR" ]] || return 0
  local target
  target=$(sed -n 's/^[[:space:]]*log_target[[:space:]]*=[[:space:]]*//p' "$CONFIG_DIR/config.conf" 2>/dev/null | tail -n1)
  target=$(printf '%s' "$target" | tr -d '\r' | tr -d '"'"'"'')
  case ",$target," in
    *,file,*) ;;
    *)
      rm -f -- "$LOGROTATE_DIR/ip-allowlist"
      return 0
      ;;
  esac
  if [[ -f "$SRC_DIR/config/logrotate.d/ip-allowlist" ]]; then
    install -m 0644 "$SRC_DIR/config/logrotate.d/ip-allowlist" "$LOGROTATE_DIR/ip-allowlist"
  else
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
  fi
  log "installed logrotate configuration"
}

install_state_dir() {
  install -d -m 0700 "$STATE_DIR"
  local version_file="$SRC_DIR/version.txt"
  local version="0.0.0"
  [[ -f "$version_file" ]] && version=$(tr -d '[:space:]' <"$version_file")
  printf '%s\n' "$version" >"$STATE_DIR/version"
  local commit="" source
  if command -v git >/dev/null 2>&1 && git -C "$SRC_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
    commit=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || true)
  fi
  if [[ -n "$commit" ]]; then
    source="${REPO:-local}@${version}+${commit}"
  else
    source="${REPO:-local}@${version}"
  fi
  printf '%s\n' "$source" >"$STATE_DIR/install-source"
}

install_log_file() {
  local log="/var/log/ip-allowlist.log"
  [[ -d /var/log ]] || return 0
  touch "$log" 2>/dev/null || return 0
  chmod 0640 "$log" 2>/dev/null || true
  log "prepared log file $log"
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
  check_prereqs
  acquire_lock
  resolve_sources
  syntax_check

  log "installing ip-allowlist from $SRC_DIR"

  STAGING="$(mktemp -d "${TMPDIR:-/tmp}/ip-allowlist-stage.XXXXXX")"
  stage_files "$STAGING"
  atomic_swap_dir "$STAGING" "$INSTALL_LIB"
  STAGING=""
  install_binary
  install_state_dir
  install_log_file
  install_config
  install_systemd
  install_logrotate

  log "installation complete"
  log "edit $CONFIG_DIR/config.conf and run: ip-allowlist sync"
}

main
