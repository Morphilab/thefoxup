#!/bin/bash
set -euo pipefail

# thefoxup - Mode dispatcher
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/update_functions.sh"
init_colors

# Acquire the instance lock unless invoked under foxup.sh, which already
# holds it (THEFOXUP_LOCK_HELD is exported by foxup.sh before spawning us).
if [[ -z "${THEFOXUP_LOCK_HELD:-}" ]]; then
  LOCK_PATH="${THEFOXUP_LOCK:-/var/run/thefoxup.lock}"
  mkdir -p "$(dirname "$LOCK_PATH")"
  exec {LOCK_FD}>"$LOCK_PATH"
  flock -n "$LOCK_FD" || { echo "${YELLOW}🔒 Another instance is already running${RESET}"; exit 1; }
  trap 'exec {LOCK_FD}>&-' EXIT
fi

execute_mode "${1:?Usage: mode.sh <lite|full|off>}"
