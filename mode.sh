#!/bin/bash
set -euo pipefail

# thefoxup v1.0.0 - Mode dispatcher
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/update_functions.sh"
init_colors
execute_mode "${1:?Usage: mode.sh <lite|full|off>}"
