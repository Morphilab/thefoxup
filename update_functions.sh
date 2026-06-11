#!/bin/bash
set -euo pipefail

# thefoxup v1.0.0 - Common update functions for Debian/Ubuntu
# https://github.com/Morphilab/thefoxup

# Color support (only if running in a terminal)
init_colors() {
  if [[ -t 1 ]]; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
  else
    RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
  fi
}

# Logging
LOG_DIR="/var/log/thefoxup"
LOG_FILE=""
readonly LOG_DIR
readonly LOG_CLEAN_DAYS="${THEFOXUP_LOG_CLEAN_DAYS:-30}"
readonly REBOOT_DELAY="${THEFOXUP_REBOOT_DELAY:-10}"
readonly APT_TIMEOUT="${THEFOXUP_APT_TIMEOUT:-600}"

init_logging() {
  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  mkdir -p "$LOG_DIR" || { echo "${RED}❌ Cannot create log directory: $LOG_DIR${RESET}" >&2; exit 1; }
  LOG_FILE="$LOG_DIR/update_${ts}.log"
  touch "$LOG_FILE" || { echo "${RED}❌ Cannot create log file: $LOG_FILE${RESET}" >&2; exit 1; }
  chmod 600 "$LOG_FILE"
  find "$LOG_DIR" -name "update_*.log" -type f -mtime "+$LOG_CLEAN_DAYS" -delete 2>/dev/null || true
}

log_event() {
  local msg="$1"
  printf '[%s] %s\n' "$(date '+%F %T')" "$msg" >> "$LOG_FILE"
}

check_apt_sources() {
  local sources=0
  [[ -f /etc/apt/sources.list ]] && ((++sources))
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    ((++sources))
  done
  shopt -u nullglob

  if [[ "$sources" -eq 0 ]]; then
    echo "${YELLOW}⚠️  No apt sources found.${RESET}" >&2
    return 1
  fi
  return 0
}

validate_environment() {
  [[ "$EUID" -eq 0 ]] || { echo "${RED}❌ Error: This script must be run as root (use sudo)${RESET}"; exit 1; }

  check_apt_sources || true

  local avail
  avail=$(df -k /var/cache/apt --output=avail 2>/dev/null | tail -1 || echo 0)
  if [[ ! "$avail" =~ ^[0-9]+$ ]] || [[ "$avail" -lt 102400 ]]; then
    echo "${YELLOW}⚠️  Low disk space on /var/cache/apt (${avail}K available). Updates may fail.${RESET}" >&2
  fi

  for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; do
    if [[ -f "$lock" ]] && command -v fuser &>/dev/null; then
      if fuser -s "$lock" 2>/dev/null; then
        echo "${RED}❌ dpkg/apt is locked by another process (${lock})${RESET}" >&2
        exit 1
      fi
    fi
  done

  echo "${GREEN}✅ Environment validated successfully${RESET}"
}

# Execute an apt command with retry on lock conflict
apt_with_retry() {
  local label="$1"
  shift
  local -a cmd=("$@")
  local max_attempts=3
  local attempt=1

  while [[ "$attempt" -le "$max_attempts" ]]; do
    echo "${BLUE}${label} (attempt $attempt/$max_attempts)...${RESET}"
    local _marker
    _marker="---apt_$(date +%s%N)---"
    echo "$_marker" >> "$LOG_FILE"
    timeout "$APT_TIMEOUT" "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE" || true
    local ret=${PIPESTATUS[0]}
    if [[ "$ret" -eq 0 ]]; then
      log_event "$label succeeded"
      return 0
    fi
    if sed -n "/$_marker/,\$p" "$LOG_FILE" 2>/dev/null | grep -q "Could not get lock\|is locked by another process"; then
      echo "${YELLOW}⚠️  apt lock held, retrying in 5s...${RESET}"
      sleep 5
      ((++attempt))
    else
      log_event "$label failed ($ret)"
      return "$ret"
    fi
  done

  log_event "$label failed after $max_attempts attempts"
  return 1
}

update_system() {
  check_apt_sources || { echo "${RED}❌ Cannot update: no apt sources configured${RESET}" >&2; return 1; }
  echo "${BLUE}📦 Updating package lists...${RESET}"
  apt_with_retry "Package list update" apt-get update || return 1

  echo "${BLUE}⬆️  Applying system upgrade...${RESET}"
  apt_with_retry "System upgrade" env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confold" || return 1

  echo "${BLUE}🧹 Cleaning up unnecessary packages...${RESET}"
  dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null \
    | awk -v k="linux-image-$(uname -r)" '$0 == k' 2>/dev/null \
    | xargs -r apt-mark manual 2>/dev/null || true
  apt_with_retry "Autoremove" apt-get autoremove -y || true
  apt_with_retry "Autoclean" apt-get autoclean || true

  echo "${GREEN}✅ System updated successfully${RESET}"
  return 0
}

# Reboot helper
do_reboot() {
  local prompt_confirm="$1"
  if [[ "$prompt_confirm" -eq 1 ]]; then
    echo
    read -r -p "System will REBOOT. Continue? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "${YELLOW}❌ Reboot cancelled${RESET}"; log_event "User cancelled reboot"; return 1; }
  fi
  echo "${YELLOW}🔄 Rebooting in ${REBOOT_DELAY} seconds... (Ctrl+C to cancel)${RESET}"
  log_event "FULL mode — rebooting in ${REBOOT_DELAY}s"
  sleep "$REBOOT_DELAY"
  reboot
}

# Shutdown helper
do_shutdown() {
  local prompt_confirm="$1"
  if [[ "$prompt_confirm" -eq 1 ]]; then
    echo
    read -r -p "System will SHUT DOWN. Continue? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "${YELLOW}❌ Shutdown cancelled${RESET}"; log_event "User cancelled shutdown"; return 1; }
  fi
  echo "${RED}⏻ Shutting down in ${REBOOT_DELAY} seconds... (Ctrl+C to cancel)${RESET}"
  log_event "OFF mode — shutting down in ${REBOOT_DELAY}s"
  sleep "$REBOOT_DELAY"
  poweroff
}

# Unified mode execution
execute_mode() {
  local mode="$1"
  local dry_run="${THEFOXUP_DRY_RUN:-0}"
  local prompt_confirm="${THEFOXUP_PROMPT_CONFIRM:-0}"

  # Check mode: read-only system status
  if [[ "$mode" == "check" ]]; then
    echo "${BLUE}🔍 System status check...${RESET}"
    validate_environment
    echo
    echo "${BLUE}📦 Upgradable packages:${RESET}"
    apt list --upgradable 2>/dev/null | grep -v '^Listing...' || echo "  (none)"
    echo
    echo "${BLUE}💾 Disk usage:${RESET}"
    df -h / /var /var/cache/apt 2>/dev/null | sed 's/^/  /'
    echo
    echo "${BLUE}📋 Last log:${RESET}"
    local last_log
    last_log=$(find "$LOG_DIR" -name 'update_*.log' -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    if [[ -n "$last_log" ]]; then
      echo "  File: $last_log"
      tail -5 "$last_log" 2>/dev/null | sed 's/^/  /'
    else
      echo "  (no logs yet)"
    fi
    return 0
  fi

  validate_environment
  init_logging
  local hostname_str
  hostname_str=$(timeout 2 hostname -f 2>/dev/null || hostname)
  log_event "thefoxup started — mode=$mode dry_run=$dry_run host=$hostname_str"
  log_event "Environment validated"

  # Dry-run: refresh cache and show what would be updated, then exit
  if [[ "$dry_run" -eq 1 ]]; then
    echo "${BLUE}📋 Dry-run: refreshing package cache...${RESET}"
    apt-get update 2>&1 | tee -a "$LOG_FILE" || true
    echo "${BLUE}📦 Packages that would be upgraded:${RESET}"
    apt list --upgradable 2>/dev/null | tee -a "$LOG_FILE" || true
    log_event "Dry-run completed"
    return 0
  fi

  update_system || { log_event "System update FAILED"; return 1; }
  log_event "System update completed"

  case "$mode" in
    lite)
      echo "${GREEN}🎉 LITE mode completed (no reboot)${RESET}"
      log_event "LITE mode finished — no reboot"
      ;;
    full)
      do_reboot "$prompt_confirm" || return 1
      ;;
    off)
      do_shutdown "$prompt_confirm" || return 1
      ;;
    *)
      echo "${RED}❌ Unknown mode: $mode${RESET}"
      log_event "ERROR: Unknown mode ($mode)"
      return 1
      ;;
  esac
}
