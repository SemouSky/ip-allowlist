#!/usr/bin/env bash
# Shared setup for the bats unit tests.
# shellcheck shell=bash

ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export IP_ALLOWLIST_ROOT="$ROOT"
LOG_LEVEL=3
LOG_TARGET=stdout

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/source.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/state.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/fail2ban.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/firewall/nft.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/firewall/ufw.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/firewall/firewalld.sh"

mktmp() { mktemp -d; }
