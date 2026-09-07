#!/bin/bash
set -euo pipefail

# thefoxup v1.1.0 - Secure updater for Debian/Ubuntu servers
# Main orchestrator with local + remote SSH support (YAML config)
# https://github.com/Morphilab/thefoxup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Consumed by load_servers_yaml() in remote_functions.sh
# shellcheck disable=SC2034
CONFIG_FILE="$SCRIPT_DIR/servers.yaml"
LOCK="${THEFOXUP_LOCK:-/var/run/thefoxup.lock}"
VERSION="1.1.0"

source "$SCRIPT_DIR/update_functions.sh"
source "$SCRIPT_DIR/remote_functions.sh"
init_colors

# === HELP AND VERSION ===
show_help() {
  cat << EOF
🚀 thefoxup v${VERSION} - Secure Debian/Ubuntu Updater

Usage:
  ./foxup.sh [lite|full|off] [flags]  # Non-interactive (ideal for SSH)
  ./foxup.sh                          # Interactive mode

Modes:
  lite   → Update packages only (no reboot)
  full   → Update packages and reboot
  off    → Update packages and shutdown

Options:
  -n, --dry-run   Show available updates without applying changes
  -y, --yes       Skip all confirmation prompts
  -c, --check     Check system status (read-only, no changes)
  --remote        Run on remote servers only (requires servers.yaml)
  --all           Run on local machine and all remote servers
  -h, --help      Show this help
  -v, --version   Show version information

Examples:
  ./foxup.sh full              # Update + reboot locally
  ./foxup.sh full --yes        # Update + reboot (no prompts)
  ./foxup.sh full --remote     # Update + reboot all remotes
  ./foxup.sh full --all --yes  # Update + reboot local + all remotes
  ./foxup.sh lite --dry-run    # Show what would be updated, then exit

Tips:
  - Run with sudo to inherit your SSH keys:  sudo ./foxup.sh
  - For parallel remote execution, load your SSH key into the agent first:
    eval \$(ssh-agent) && ssh-add
EOF
  exit 0
}

show_version() {
echo "thefoxup v${VERSION}"
echo "Secure updater for Debian/Ubuntu servers"
echo "https://github.com/Morphilab/thefoxup"
  exit 0
}

[[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]] && show_help
[[ "${1:-}" == "--version" ]] || [[ "${1:-}" == "-v" ]] && show_version

for cmd in yq flock timeout base64; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "${RED}❌ Error: '$cmd' is required${RESET}"
    case "$cmd" in
      yq)      echo "   Install with: sudo apt install yq" ;;
      flock)   echo "   Install with: sudo apt install util-linux" ;;
      timeout) echo "   Install with: sudo apt install coreutils" ;;
      base64)  echo "   Install with: sudo apt install coreutils" ;;
    esac
    exit 1
  fi
done

# yq must be able to evaluate basic expressions
if ! echo '{"a":1}' | yq -r '.a' &>/dev/null; then
  echo "${RED}❌ Error: yq is not working correctly${RESET}" >&2
  echo "   Install yq with: sudo apt install yq    # Ubuntu 24.04+ / Debian 12+" >&2
  echo "   Or download from: https://github.com/mikefarah/yq/releases" >&2
  exit 1
fi

# Validate numeric environment overrides early (defense in depth)
require_uint "THEFOXUP_SSH_CONNECT_TIMEOUT" "$SSH_CONNECT_TIMEOUT" || exit 1
require_uint "THEFOXUP_SSH_ALIVE_INTERVAL" "$SSH_SERVER_ALIVE_INTERVAL" || exit 1
require_uint "THEFOXUP_MAX_PARALLEL" "$MAX_PARALLEL" || exit 1
require_uint "THEFOXUP_REMOTE_SESSION_TIMEOUT" "$REMOTE_SESSION_TIMEOUT" || exit 1

# Require root early (before interactive menu)
if [[ "$EUID" -ne 0 ]]; then
  echo "${RED}❌ Error: This script must be run as root (use sudo)${RESET}" >&2
  echo "   Example: sudo $0 $*" >&2
  exit 1
fi

# Lock (atomic via flock, auto-released when FD closes on exit)
mkdir -p "$(dirname "$LOCK")"
exec {LOCK_FD}>"$LOCK"
flock -n "$LOCK_FD" || { echo "${YELLOW}🔒 Another instance is already running${RESET}"; exit 1; }
export THEFOXUP_LOCK_HELD=1

# Cleanup on exit / interrupt
# Keep the lockfile on disk (only close the FD) — unlinking it would open a
# race where a second instance locks the old inode while a third recreates it.
trap 'exec {LOCK_FD}>&-' EXIT
trap 'echo; echo "${RED}⏹ Interrupted by user${RESET}" >&2; exit 130' INT TERM

# === CLI ARGUMENT PARSING ===
MODE=""
DRY_RUN=0
YES_MODE=0
LOCATION="local"

for arg in "$@"; do
  case "$arg" in
    lite|full|off) MODE="$arg" ;;
    --dry-run|-n)  DRY_RUN=1 ;;
    --yes|-y)      YES_MODE=1 ;;
    --check|-c)    MODE="check" ;;
    --remote)      LOCATION="remote" ;;
    --all)         LOCATION="all" ;;
    -h|--help)     show_help ;;
    -v|--version)  show_version ;;
    *)             echo "Unknown option: $arg"; echo "Use -h for help"; exit 1 ;;
  esac
done

# === NON-INTERACTIVE CLI MODE ===
if [[ -n "$MODE" ]]; then
  export THEFOXUP_DRY_RUN=$DRY_RUN
  # Confirmation prompts default to enabled (update_functions.sh); --yes overrides
  if [[ "$YES_MODE" -eq 1 ]]; then
    export THEFOXUP_PROMPT_CONFIRM=0
  else
    export THEFOXUP_PROMPT_CONFIRM=1
  fi

  overall_fail=0

  if [[ "$LOCATION" == "remote" || "$LOCATION" == "all" ]]; then
    _yaml_rc=0
    load_servers_yaml || _yaml_rc=$?
    if [[ $_yaml_rc -eq 0 ]]; then
      validate_servers || exit 1
      run_remote_batch "$MODE" || { overall_fail=1; }
    elif [[ $_yaml_rc -eq 2 ]] || [[ "$LOCATION" == "remote" ]]; then
      exit 1
    fi
  fi

  if [[ "$LOCATION" == "local" || "$LOCATION" == "all" ]]; then
    execute_mode "$MODE" || exit 1
  fi

  if [[ "$overall_fail" -eq 0 ]]; then
    exit 0
  elif [[ "$LOCATION" == "all" ]]; then
    echo "${YELLOW}⚠️  Remote execution had failures (local update completed successfully)${RESET}" >&2
    exit 1
  else
    echo "${RED}❌ Remote execution failed${RESET}" >&2
    exit 1
  fi
fi

# === INTERACTIVE MODE ===
clear
echo "${BLUE}╔════════════════════════════════════════════════════════════╗${RESET}"
echo "${BLUE}║${RESET}                🚀 ${BOLD}thefoxup v${VERSION}${RESET}                          ${BLUE}║${RESET}"
echo "${BLUE}║${RESET}         Secure updater for Debian/Ubuntu servers           ${BLUE}║${RESET}"
echo "${BLUE}╚════════════════════════════════════════════════════════════╝${RESET}"
echo
echo "${GREEN}Starting thefoxup...${RESET}"
echo "A safe way to update your servers"
echo

echo "Select operation mode:"
select mode in lite full off check "Cancel"; do
  [[ "$mode" == "Cancel" ]] && { echo "${YELLOW}❌ Operation cancelled by user.${RESET}"; exit 1; }
  [[ "$mode" ]] && break
  echo "Please choose 1-5"
done

# Check mode is always local (read-only)
if [[ "$mode" == "check" ]]; then
  execute_mode check || exit 1
  exit 0
fi

echo
echo "Where do you want to run thefoxup?"
select location in "Local only" "Remotes only" "Local + Remotes" "Cancel"; do
  [[ "$location" == "Cancel" ]] && { echo "${YELLOW}❌ Operation cancelled by user.${RESET}"; exit 1; }
  [[ "$location" ]] && break
  echo "Please choose 1-4"
done

overall_fail=0

case "$location" in
  "Local only")
    bash "$SCRIPT_DIR/mode-${mode}.sh" || overall_fail=1
    ;;
  "Remotes only" | "Local + Remotes")
    _yaml_rc=0
    load_servers_yaml || _yaml_rc=$?
    if [[ $_yaml_rc -eq 0 ]]; then
      validate_servers || exit 1

      echo "Available servers:"
      for i in "${!HOSTS[@]}"; do
        echo "  $((i+1))) ${USERS[$i]:+${USERS[$i]}@}${HOSTS[$i]} → ${PATHS[$i]}"
      done
      echo
      read -r -p "Enter numbers separated by space (empty = all): " -a raw_selection
      if [[ ${#raw_selection[@]} -eq 0 ]]; then
        run_remote_batch "$mode" || overall_fail=1
      else
        readarray -t selection < <(printf '%s\n' "${raw_selection[@]}" | sort -nu)
        run_remote_batch "$mode" "${selection[@]}" || overall_fail=1
      fi
    elif [[ $_yaml_rc -eq 2 ]] || [[ "$location" == "Remotes only" ]]; then
      exit 1
    fi

    if [[ "$location" == "Local + Remotes" ]]; then
      bash "$SCRIPT_DIR/mode-${mode}.sh" || overall_fail=1
    fi
    ;;
esac

if [[ "$overall_fail" -eq 0 ]]; then
  echo
  echo "${GREEN}✅ thefoxup v${VERSION} completed successfully${RESET}"
else
  echo
  echo "${RED}❌ thefoxup v${VERSION} completed with errors${RESET}" >&2
  exit 1
fi
