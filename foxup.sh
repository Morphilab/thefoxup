#!/bin/bash
set -euo pipefail

# thefoxup v1.0.0 - Secure updater for Debian/Ubuntu servers
# Main orchestrator with local + remote SSH support (YAML config)
# https://github.com/Morphilab/thefoxup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/servers.yaml"
LOCK="${THEFOXUP_LOCK:-/var/run/thefoxup.lock}"
VERSION="1.0.0"

# Configurable constants (override via environment)
SSH_CONNECT_TIMEOUT="${THEFOXUP_SSH_CONNECT_TIMEOUT:-10}"
SSH_SERVER_ALIVE_INTERVAL="${THEFOXUP_SSH_ALIVE_INTERVAL:-30}"
SSH_STRICT_HOST_KEY_CHECKING="${THEFOXUP_SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"
APT_TIMEOUT="${THEFOXUP_APT_TIMEOUT:-600}"
MAX_PARALLEL="${THEFOXUP_MAX_PARALLEL:-10}"

# Load shared library and initialize colors
source "$SCRIPT_DIR/update_functions.sh"
init_colors

# Check if an SSH agent is available with loaded identities
has_ssh_agent() {
  [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l &>/dev/null
}

# SSH execution helper
run_remote() {
  local host="$1" user="$2" path="$3" mode="$4" server_idx="$5"
  local ssh_target
  local -a ssh_opts=()
  local -a prefix=()

  case "$mode" in
    lite|full|off) ;;
    *) echo "${RED}❌ Invalid mode '$mode' for server $((server_idx))${RESET}" >&2; return 1 ;;
  esac

  if [[ -n "$user" ]]; then
    ssh_target="${user}@${host}"
  else
    ssh_target="${host}"
  fi

  ssh_opts=(-t)
  ssh_opts+=(-o "ConnectTimeout=$SSH_CONNECT_TIMEOUT")
  ssh_opts+=(-o "ServerAliveInterval=$SSH_SERVER_ALIVE_INTERVAL")
  ssh_opts+=(-o "StrictHostKeyChecking=$SSH_STRICT_HOST_KEY_CHECKING")

  if [[ -n "${SUDO_USER:-}" ]]; then
    prefix=(sudo -u "$SUDO_USER")
  fi

  local b64_path
  b64_path=$(printf '%s' "$path" | base64 -w0)

  "${prefix[@]}" ssh "${ssh_opts[@]}" -- "$ssh_target" \
    "sudo timeout $APT_TIMEOUT bash -c '
       command -v base64 >/dev/null 2>&1 || { echo \"Missing base64 on remote\"; exit 1; }
       dir=\$(base64 -d <<< \"$b64_path\")
       if [[ ! -d \"\$dir\" ]]; then echo \"Remote path not found: \$dir\"; exit 1; fi
       cd \"\$dir\" && ./foxup.sh $mode --yes'"
}

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

# Check required dependencies
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
  echo "   Install the Go version of yq:" >&2
  echo "   sudo apt install yq    # Ubuntu 24.04+ / Debian 12+" >&2
  echo "   Or download from: https://github.com/mikefarah/yq/releases" >&2
  exit 1
fi

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

# Cleanup on exit / interrupt
trap 'exec {LOCK_FD}>&-; rm -f "$LOCK"' EXIT
trap 'echo; echo "${RED}⏹ Interrupted by user${RESET}" >&2; exit 130' INT TERM

# === SHARED FUNCTIONS (used by both CLI and interactive flows) ===

# Load servers from YAML config into global arrays
# Sets: USERS[], HOSTS[], PATHS[]
# Returns 0 on success, 1 on failure (prints diagnostic to stderr)
load_servers_yaml() {
  USERS=() HOSTS=() PATHS=()

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "${YELLOW}⚠️  servers.yaml not found${RESET}" >&2
    echo "   Copy servers.example.yaml to servers.yaml and configure it" >&2
    return 1
  fi

  if ! yq '.' "$CONFIG_FILE" &>/dev/null; then
    echo "${RED}❌ servers.yaml has invalid YAML syntax${RESET}" >&2
    return 2
  fi

  local password_warned=0

  while IFS= read -r user && IFS= read -r host && IFS= read -r path && IFS= read -r pwd; do
    USERS+=("$user")
    HOSTS+=("$host")
    PATHS+=("$path")
    pwd="${pwd#null}"; [[ -n "$pwd" ]] && password_warned=1
  done < <(yq -r '.servers[] | .user // "", .host // "", .path // "", (.password // null | tostring)' "$CONFIG_FILE" 2>/dev/null)

  if [[ "$password_warned" -eq 1 ]]; then
    echo "${YELLOW}⚠️  password field is deprecated and ignored — use key-based SSH auth only${RESET}" >&2
  fi

  if [[ ${#HOSTS[@]} -lt 1 ]]; then
    echo "${YELLOW}⚠️  No servers configured in servers.yaml${RESET}" >&2
    return 1
  fi

  return 0
}

# Validate servers loaded by load_servers_yaml()
# Returns 0 on success, 1 on failure (prints diagnostic to stderr)
validate_servers() {
  for i in "${!HOSTS[@]}"; do
    if [[ -z "${HOSTS[i]}" || -z "${PATHS[i]}" ]]; then
      echo "${RED}❌ Server $((i+1)) has an empty or missing host or path — check servers.yaml${RESET}" >&2
      return 1
    fi
    if [[ -n "${USERS[i]}" && ! "${USERS[i]}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      echo "${RED}❌ Server $((i+1)): invalid characters in user '${USERS[i]}'${RESET}" >&2
      echo "   Only alphanumeric, dots, dashes, and underscores allowed" >&2
      return 1
    fi
    if [[ -n "${HOSTS[i]}" && ! "${HOSTS[i]}" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
      echo "${RED}❌ Server $((i+1)): invalid characters in host '${HOSTS[i]}'${RESET}" >&2
      echo "   Only alphanumeric, dots, dashes, colons, and underscores allowed" >&2
      return 1
    fi
    if [[ -n "${PATHS[i]}" && ! "${PATHS[i]}" =~ ^/[a-zA-Z0-9/._-]+$ ]]; then
      echo "${RED}❌ Server $((i+1)): invalid characters in path '${PATHS[i]}'${RESET}" >&2
      echo "   Path must be absolute and use only safe characters" >&2
      return 1
    fi
  done
  return 0
}

# Run foxup on selected remote servers in parallel
# $1: mode (lite|full|off)
# $@: server indices (1-based), if none specified runs all servers
# Returns 0 if all servers succeed, 1 if any fail
run_remote_batch() {
  local mode="$1"; shift
  local -a selection
  local failed_servers=0

  if [[ $# -eq 0 ]]; then
    for ((i=1; i<=${#HOSTS[@]}; i++)); do selection+=("$i"); done
  else
    selection=("$@")
  fi

  local _effective_parallel=$MAX_PARALLEL
  if [[ ${#selection[@]} -gt 1 ]] && ! has_ssh_agent; then
    echo "${YELLOW}⚠️  No SSH agent detected — running servers sequentially${RESET}" >&2
    echo "   Tip: use ssh-agent for parallel execution (eval \$(ssh-agent) && ssh-add)" >&2
    _effective_parallel=1
  fi

  local job_pids=()
  local pid_labels=()

  for idx in "${selection[@]}"; do
    [[ "$idx" =~ ^[0-9]+$ ]] || { echo "${RED}❌ Invalid selection: '$idx' (not a number)${RESET}" >&2; continue; }
    [[ "$idx" -gt "${#HOSTS[@]}" || "$idx" -lt 1 ]] && { echo "${RED}❌ Invalid server number: $idx (must be 1-${#HOSTS[@]})${RESET}" >&2; continue; }
    local i=$((idx - 1))

    if [[ ${#job_pids[@]} -ge "$_effective_parallel" ]]; then
      wait -n 2>/dev/null || true
      local alive=()
      local alive_labels=()
      for j in "${!job_pids[@]}"; do
        if kill -0 "${job_pids[$j]}" 2>/dev/null; then
          alive+=("${job_pids[$j]}")
          alive_labels+=("${pid_labels[$j]}")
        fi
      done
      job_pids=("${alive[@]}")
      pid_labels=("${alive_labels[@]}")
    fi

    local label="${USERS[$i]:+${USERS[$i]}@}${HOSTS[$i]}"
    echo "${BLUE}🔄 Running on $label (mode $mode)...${RESET}"
    run_remote "${HOSTS[$i]}" "${USERS[$i]}" "${PATHS[$i]}" "$mode" "$idx" &
    job_pids+=($!)
    pid_labels+=("$label")
  done

  for i in "${!job_pids[@]}"; do
    wait "${job_pids[$i]}" || { echo "${RED}❌ Failed: ${pid_labels[$i]}${RESET}" >&2; ((++failed_servers)); }
  done

  if [[ "$failed_servers" -gt 0 ]]; then
    echo "${YELLOW}⚠️  $failed_servers server(s) failed${RESET}" >&2
    return 1
  fi
  return 0
}

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
  if [[ "$YES_MODE" -eq 0 ]]; then
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

# Select mode
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

# Select location
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
