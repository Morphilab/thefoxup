#!/bin/bash
set -euo pipefail

# thefoxup v1.1.0 - Remote execution functions (SSH batch layer)
# https://github.com/Morphilab/thefoxup

# Configurable constants (override via environment)
readonly SSH_CONNECT_TIMEOUT="${THEFOXUP_SSH_CONNECT_TIMEOUT:-10}"
readonly SSH_SERVER_ALIVE_INTERVAL="${THEFOXUP_SSH_ALIVE_INTERVAL:-30}"
readonly SSH_STRICT_HOST_KEY_CHECKING="${THEFOXUP_SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"
readonly MAX_PARALLEL="${THEFOXUP_MAX_PARALLEL:-10}"
# Total time budget for a whole remote session (update + upgrade + cleanup).
# Separate from THEFOXUP_APT_TIMEOUT, which bounds each remote apt command.
readonly REMOTE_SESSION_TIMEOUT="${THEFOXUP_REMOTE_SESSION_TIMEOUT:-1800}"

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
    "sudo timeout $REMOTE_SESSION_TIMEOUT bash -c '
       command -v base64 >/dev/null 2>&1 || { echo \"Missing base64 on remote\"; exit 1; }
       dir=\$(base64 -d <<< \"$b64_path\")
       if [[ ! -d \"\$dir\" ]]; then echo \"Remote path not found: \$dir\"; exit 1; fi
       cd \"\$dir\" && ./foxup.sh $mode --yes'"
}
# === SHARED FUNCTIONS (used by both CLI and interactive flows) ===

# Load servers from YAML config into global arrays
# Sets: USERS[], HOSTS[], PATHS[]
# Returns 0 on success, 1 if the config file is missing, 2 on invalid YAML syntax
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
      # Wait for the oldest job specifically so its exit status is never lost.
      local oldest_pid="${job_pids[0]}"
      local oldest_label="${pid_labels[0]}"
      if ! wait "$oldest_pid"; then
        echo "${RED}❌ Failed: ${oldest_label}${RESET}" >&2
        ((++failed_servers))
      fi
      job_pids=("${job_pids[@]:1}")
      pid_labels=("${pid_labels[@]:1}")
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
