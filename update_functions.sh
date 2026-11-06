#!/bin/bash
set -euo pipefail

# thefoxup - Common update functions for Debian/Ubuntu
# https://github.com/Morphilab/thefoxup

# Color support (only if running in a terminal)
init_colors() {
  if [[ -t 1 ]]; then
    RED=$(tput setaf 1 2>/dev/null || true)
    GREEN=$(tput setaf 2 2>/dev/null || true)
    YELLOW=$(tput setaf 3 2>/dev/null || true)
    BLUE=$(tput setaf 4 2>/dev/null || true)
    BOLD=$(tput bold 2>/dev/null || true)
    RESET=$(tput sgr0 2>/dev/null || true)
  else
    # shellcheck disable=SC2034  # BOLD is used by foxup.sh's interactive banner
    RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
  fi
}

LOG_DIR="${THEFOXUP_LOG_DIR:-/var/log/thefoxup}"
LOG_FILE=""
readonly LOG_DIR
readonly LOG_CLEAN_DAYS="${THEFOXUP_LOG_CLEAN_DAYS:-30}"
readonly REBOOT_DELAY="${THEFOXUP_REBOOT_DELAY:-10}"
readonly APT_TIMEOUT="${THEFOXUP_APT_TIMEOUT:-600}"
# Grace period between SIGTERM and SIGKILL for an apt command that stalls
# past its timeout. Must be >= 1 (`timeout -k 0` disables the SIGKILL).
readonly APT_KILL_AFTER="${THEFOXUP_APT_KILL_AFTER:-30}"
# Heartbeat interval for long apt commands; 0 disables the heartbeat.
readonly HEARTBEAT_INTERVAL="${THEFOXUP_HEARTBEAT_INTERVAL:-30}"
# Lock files that indicate a dpkg/apt transaction is running (or did not clean
# up). One list shared by the pre-flight check, the stall diagnostics and the
# post-stall leftover cleanup, so the three can never drift apart — a holder
# invisible to the diagnostics must not be eligible for the cleanup either.
readonly APT_LOCK_FILES=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
                         /var/cache/apt/archives/lock /var/lib/apt/lists/lock)

# Validate that an environment value is a non-negative integer
require_uint() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "${RED}❌ $name must be a non-negative integer (got: '$value')${RESET}" >&2; return 1; }
}

# Validate that an environment value is an integer >= min. Some values accept 0
# as "disabled", but the apt bounds do not: `timeout 0` removes the hard
# timeout and `timeout -k 0` removes the forced kill, which is the opposite of
# what those knobs exist for.
require_uint_min() {
  local name="$1" value="$2" min="$3" hint="${4:-}"
  require_uint "$name" "$value" || return 1
  [[ "$value" -ge "$min" ]] && return 0
  echo "${RED}❌ $name must be >= $min (got: '$value')${RESET}" >&2
  [[ -n "$hint" ]] && echo "   $hint" >&2
  return 1
}

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
  local -a extra_sources=()
  shopt -s nullglob
  extra_sources=(/etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
  shopt -u nullglob
  ((sources += ${#extra_sources[@]}))

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

  if command -v fuser >/dev/null 2>&1; then
    for lock in "${APT_LOCK_FILES[@]}"; do
      if [[ -f "$lock" ]] && fuser -s "$lock" 2>/dev/null; then
        echo "${RED}❌ dpkg/apt is locked by another process (${lock})${RESET}" >&2
        exit 1
      fi
    done
  else
    echo "${YELLOW}⚠️  fuser not available — skipping the apt/dpkg lock pre-check${RESET}" >&2
  fi

  echo "${GREEN}✅ Environment validated successfully${RESET}"
}

# Stop every background child of the watchdog. `jobs -p` is used instead of the
# tracked PID so a sleep forked in the window between `sleep &` and `sp=$!` is
# still caught: missing it would leave the sleep running as an orphan holding
# inherited descriptors (e.g. the flock) until its interval expires.
_apt_watchdog_cleanup() {
  local pids
  pids=$(jobs -p 2>/dev/null) || true
  [[ -n "$pids" ]] || return 0
  # shellcheck disable=SC2086  # unquoted on purpose: pids is a list
  kill $pids 2>/dev/null || true
}

# Periodic heartbeat while a long apt command runs. Started in the background
# by apt_with_retry and killed when the command finishes. The sleep child runs
# in the background so the trap can reap it on TERM/INT: a foreground sleep
# would survive as an orphan holding inherited descriptors (e.g. the flock)
# for up to one interval after the script exits.
_apt_watchdog() {
  local start="$1" label="$2"
  local now stop_at elapsed sp=""
  [[ "$HEARTBEAT_INTERVAL" -gt 0 ]] || return 0
  trap '_apt_watchdog_cleanup; exit 0' TERM INT
  stop_at=$((start + APT_TIMEOUT + APT_KILL_AFTER + HEARTBEAT_INTERVAL + 5))
  while :; do
    sleep "$HEARTBEAT_INTERVAL" &
    sp=$!
    wait "$sp" 2>/dev/null || return 0
    now=$(date +%s)
    elapsed=$((now - start))
    if [[ "$now" -ge "$stop_at" ]]; then
      return 0
    fi
    echo "${YELLOW}⏳ ${label} still running… (${elapsed}s elapsed)${RESET}" >&2
    log_event "${label}: still running (${elapsed}s elapsed)"
  done
}

# Best-effort forensic snapshot appended to the log when an apt command had to
# be stopped by the timeout. Must never fail the caller.
dump_stall_diagnostics() {
  local label="$1" log="$LOG_FILE"
  if (
    set +e
    {
      echo "--- stall diagnostics: ${label} ---"
      date '+time: %F %T'
      # shellcheck disable=SC2009  # pgrep cannot show state/etime/wchan columns
      ps -eo pid,ppid,stat,etime,wchan:28,args --sort=etime 2>/dev/null \
        | grep -E 'apt|dpkg|debconf|needrestart' | grep -v grep
      if command -v fuser >/dev/null 2>&1; then
        fuser -v "${APT_LOCK_FILES[@]}" 2>&1
      fi
      if [[ -f /var/log/dpkg.log ]]; then
        tail -n 15 /var/log/dpkg.log 2>/dev/null
      fi
      if [[ -f /var/log/apt/history.log ]]; then
        echo "--- apt history.log (tail) ---"
        tail -n 15 /var/log/apt/history.log 2>/dev/null
      fi
      if [[ -f /var/log/apt/term.log ]]; then
        echo "--- apt term.log (tail) ---"
        tail -n 15 /var/log/apt/term.log 2>/dev/null
      fi
      if command -v journalctl >/dev/null 2>&1; then
        journalctl -n 15 --no-pager 2>/dev/null
      fi
      echo "--- end stall diagnostics ---"
    } >> "$log" 2>&1
  ); then
    echo "${YELLOW}🩺 Stall diagnostics saved to ${log}${RESET}" >&2
  else
    echo "${YELLOW}⚠️  Could not save stall diagnostics to ${log}${RESET}" >&2
  fi
}

# True while $1 exists and is not a zombie (`kill -0` alone also matches
# zombies, which hold no locks anymore but cannot be signalled away).
_pid_is_running() {
  local state
  state=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  [[ -n "$state" && "$state" != Z* ]]
}

# Render PIDs as "1234(dpkg) 5678(apt-get)" for operator messages and logs.
_describe_pids() {
  local pid comm out=""
  for pid in "$@"; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=""
    out+="${out:+ }${pid}(${comm:-unknown})"
  done
  printf '%s' "$out"
}

# Ask whatever still holds the apt/dpkg locks to stop, after a command was
# stopped by the timeout. A lock holder at that point is either a leftover of
# that command or a concurrent apt/dpkg run, and both have to release the locks
# before the next run can work. SIGTERM goes first so a responsive apt/dpkg can
# abort cleanly and release the locks itself; only the processes that ignore it
# are force-stopped, which is what keeps TERM-immune leftovers from holding the
# locks (and the log pipe) forever. Best effort: never fails the caller.
_stop_leftover_lock_holders() {
  if ! command -v fuser >/dev/null 2>&1; then
    echo "${YELLOW}⚠️  fuser not available — leftover apt/dpkg lock holders were not stopped${RESET}" >&2
    log_event "fuser not available: leftover apt/dpkg lock holders were not stopped"
    return 0
  fi

  local pids pid
  pids=$(fuser "${APT_LOCK_FILES[@]}" 2>/dev/null) || true
  local -a targets=()
  for pid in $pids; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" -eq "$$" || "$pid" -eq "$PPID" ]] && continue
    targets+=("$pid")
  done
  [[ ${#targets[@]} -gt 0 ]] || return 0

  local desc
  desc=$(_describe_pids "${targets[@]}")
  echo "${YELLOW}🧹 Lock holders asked to stop: ${desc}${RESET}" >&2
  log_event "Leftover apt/dpkg lock holders asked to stop (SIGTERM): ${desc}"
  kill -TERM "${targets[@]}" 2>/dev/null || true

  # Bounded grace for a clean abort, then force-stop only the survivors.
  local waited=0
  while [[ "$waited" -lt "$APT_KILL_AFTER" ]]; do
    local -a alive=()
    for pid in "${targets[@]}"; do
      _pid_is_running "$pid" && alive+=("$pid")
    done
    [[ ${#alive[@]} -gt 0 ]] || return 0
    sleep 1
    ((++waited))
  done

  local -a stubborn=()
  for pid in "${targets[@]}"; do
    _pid_is_running "$pid" && stubborn+=("$pid")
  done
  [[ ${#stubborn[@]} -gt 0 ]] || return 0

  desc=$(_describe_pids "${stubborn[@]}")
  echo "${YELLOW}🧹 Lock holders that ignored SIGTERM were force-stopped: ${desc}${RESET}" >&2
  log_event "Leftover apt/dpkg lock holders force-stopped (ignored SIGTERM): ${desc}"
  kill -KILL "${stubborn[@]}" 2>/dev/null || true
  return 0
}

# Run an apt command under the hard timeout, streaming its output to the
# console and the log through a bounded reader: some timeout implementations
# (e.g. uutils) SIGKILL only the direct child, and a surviving child still
# holding the pipe open would otherwise make the reader wait forever.
# Returns the command's exit status; a reader that had to be stopped is logged.
_apt_run_bounded() {
  local label="$1"
  shift
  # The reader's deadline is strictly after the apt kill window, so it only
  # fires when a survivor is still holding the pipe.
  local deadline=$((APT_TIMEOUT + APT_KILL_AFTER + 5))
  local rc=0 reader_rc=0

  # SIGTERM at $APT_TIMEOUT; if the command ignores it, SIGKILL after
  # $APT_KILL_AFTER more seconds instead of waiting forever.
  # </dev/null stops a hidden maintainer-script/debconf read from blocking on
  # the caller's terminal. LC_ALL=C keeps apt lock-error messages predictable
  # regardless of locale.
  # Capture the exit statuses inside the || branch: with pipefail, an
  # unconditional `|| true` would clobber PIPESTATUS to 0 and mask failures.
  timeout -k "$APT_KILL_AFTER" "$APT_TIMEOUT" env LC_ALL=C "$@" </dev/null 2>&1 \
    | timeout -k 5 "$deadline" tee -a "$LOG_FILE" \
    || { rc=${PIPESTATUS[0]} reader_rc=${PIPESTATUS[1]:-0}; }

  if [[ "$reader_rc" -ne 0 ]]; then
    log_event "${label}: output reader stopped (survivors held the log pipe)"
  fi
  return "$rc"
}

# Run a read-only apt query bounded by the hard timeout, streaming its output
# to the console through a bounded reader and appending it to the log when one
# is active (check mode runs without a log file and must not create one, hence
# the /dev/null sink). A query that had to be stopped is reported on stderr, so
# a stopped query is never silently shown as "nothing to upgrade".
_apt_run_query() {
  local label="$1"
  shift
  local deadline=$((APT_TIMEOUT + APT_KILL_AFTER + 5))
  local rc=0

  timeout -k "$APT_KILL_AFTER" "$APT_TIMEOUT" env LC_ALL=C "$@" </dev/null 2>/dev/null \
    | timeout -k 5 "$deadline" tee -a "${LOG_FILE:-/dev/null}" \
    || rc=${PIPESTATUS[0]}

  if [[ "$rc" -ne 0 ]]; then
    echo "${YELLOW}⚠️  ${label} did not complete (rc=$rc) — results may be incomplete${RESET}" >&2
  fi
  return "$rc"
}

# Execute an apt command with a hard timeout, heartbeat and stall forensics
apt_with_retry() {
  local label="$1"
  shift
  local -a cmd=("$@")
  local max_attempts=3
  local attempt=1

  while [[ "$attempt" -le "$max_attempts" ]]; do
    echo "${BLUE}${label} (attempt $attempt/$max_attempts)...${RESET}"
    local _marker _start _wd_pid="" ret=0 _elapsed
    _marker="---apt_$(date +%s%N)---"
    echo "$_marker" >> "$LOG_FILE"
    _start=$(date +%s)

    if [[ "$HEARTBEAT_INTERVAL" -gt 0 ]]; then
      _apt_watchdog "$_start" "$label" &
      _wd_pid=$!
    fi

    _apt_run_bounded "$label" "${cmd[@]}" || ret=$?

    if [[ -n "$_wd_pid" ]]; then
      kill "$_wd_pid" 2>/dev/null || true
      wait "$_wd_pid" 2>/dev/null || true
    fi

    _elapsed=$(( $(date +%s) - _start ))

    if [[ "$ret" -eq 0 ]]; then
      log_event "$label succeeded (${_elapsed}s)"
      return 0
    fi

    case "$ret" in
      124|137|141|143)
        if [[ "$ret" -eq 137 ]]; then
          echo "${RED}⏱  ${label} was force-killed with SIGKILL (rc=137) — it ignored SIGTERM or the system killed it (e.g. OOM)${RESET}" >&2
        elif [[ "$ret" -eq 141 ]]; then
          echo "${RED}⏱  ${label} died on SIGPIPE (rc=141) — its output reader was stopped mid-run${RESET}" >&2
        elif [[ "$ret" -eq 124 ]]; then
          echo "${RED}⏱  ${label} timed out after ${APT_TIMEOUT}s and was stopped${RESET}" >&2
        else
          echo "${RED}⏱  ${label} was terminated by a signal (rc=$ret)${RESET}" >&2
        fi
        echo "   If dpkg was interrupted, run: sudo dpkg --configure -a" >&2
        log_event "$label stopped after ${_elapsed}s (rc=$ret; timeout=${APT_TIMEOUT}s kill-after=${APT_KILL_AFTER}s)"
        dump_stall_diagnostics "$label"
        # Some timeout implementations (e.g. uutils on Ubuntu 26.04) send the
        # SIGKILL only to the direct child, leaving TERM-immune dpkg children
        # alive and still holding the apt/dpkg locks. Release those locks so the
        # next run is not blocked by leftovers of this one.
        _stop_leftover_lock_holders
        return "$ret"
        ;;
    esac

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

# Run a best-effort apt sub-command: ordinary failures are tolerated, but being
# stopped by the timeout or by a signal (rc 124/137/141/143) is fatal — the
# system may need `dpkg --configure -a`, so the caller must not continue (e.g.
# to reboot).
apt_best_effort() {
  local rc=0
  apt_with_retry "$@" || rc=$?
  case "$rc" in
    124|137|141|143) return "$rc" ;;
  esac
  return 0
}

update_system() {
  check_apt_sources || { echo "${RED}❌ Cannot update: no apt sources configured${RESET}" >&2; return 1; }
  echo "${BLUE}📦 Updating package lists...${RESET}"
  apt_with_retry "Package list update" apt-get update || return 1

  echo "${BLUE}⬆️  Applying system upgrade...${RESET}"
  apt_with_retry "System upgrade" env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confold" || return 1

  echo "${BLUE}🧹 Cleaning up unnecessary packages...${RESET}"
  # shellcheck disable=SC2016  # ${Package} is a dpkg-query format field, not a shell expansion
  timeout -k "$APT_KILL_AFTER" "$APT_TIMEOUT" dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null \
    | awk -v k="linux-image-$(uname -r)" '$0 == k' 2>/dev/null \
    | xargs -r timeout -k "$APT_KILL_AFTER" "$APT_TIMEOUT" apt-mark manual 2>/dev/null || true
  apt_best_effort "Autoremove" apt-get autoremove -y || return 1
  apt_best_effort "Autoclean" apt-get autoclean || return 1

  echo "${GREEN}✅ System updated successfully${RESET}"
  return 0
}

do_reboot() {
  local prompt_confirm="$1"
  local answer=""
  if [[ "$prompt_confirm" -eq 1 ]]; then
    echo
    if ! read -r -p "System will REBOOT. Continue? [y/N] " answer; then
      echo "${RED}❌ No interactive input available — reboot aborted${RESET}" >&2
      log_event "Reboot aborted: no interactive input"
      return 1
    fi
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "${YELLOW}❌ Reboot cancelled${RESET}"; log_event "User cancelled reboot"; return 1; }
  fi
  echo "${YELLOW}🔄 Rebooting in ${REBOOT_DELAY} seconds... (Ctrl+C to cancel)${RESET}"
  log_event "FULL mode — rebooting in ${REBOOT_DELAY}s"
  sleep "$REBOOT_DELAY"
  reboot
}

do_shutdown() {
  local prompt_confirm="$1"
  local answer=""
  if [[ "$prompt_confirm" -eq 1 ]]; then
    echo
    if ! read -r -p "System will SHUT DOWN. Continue? [y/N] " answer; then
      echo "${RED}❌ No interactive input available — shutdown aborted${RESET}" >&2
      log_event "Shutdown aborted: no interactive input"
      return 1
    fi
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "${YELLOW}❌ Shutdown cancelled${RESET}"; log_event "User cancelled shutdown"; return 1; }
  fi
  echo "${RED}⏻ Shutting down in ${REBOOT_DELAY} seconds... (Ctrl+C to cancel)${RESET}"
  log_event "OFF mode — shutting down in ${REBOOT_DELAY}s"
  sleep "$REBOOT_DELAY"
  poweroff
}

# Read-only system status report (check mode)
run_mode_check() {
  echo "${BLUE}🔍 System status check...${RESET}"
  validate_environment
  echo
  echo "${BLUE}📦 Upgradable packages:${RESET}"
  _apt_run_query "Package query" apt list --upgradable | grep -v '^Listing\.\.\.' || echo "  (none)"
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
}

# Dry-run: refresh cache and show what would be updated, apply nothing.
# Caller must have initialized logging ($LOG_FILE).
run_dry_run() {
  echo "${BLUE}📋 Dry-run: refreshing package cache...${RESET}"
  local rc=0
  _apt_run_bounded "Dry-run cache refresh" apt-get update || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "${YELLOW}⚠️  Package cache refresh failed (rc=$rc) — results below may be stale${RESET}" >&2
    log_event "Dry-run cache refresh failed ($rc)"
  fi
  echo "${BLUE}📦 Packages that would be upgraded:${RESET}"
  _apt_run_query "Package listing" apt list --upgradable || true
  log_event "Dry-run completed"
}

# Apply updates and finish according to mode (lite|full|off)
run_update_flow() {
  local mode="$1"
  local prompt_confirm="$2"

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
  esac
}

# Unified mode execution
execute_mode() {
  local mode="$1"
  local dry_run="${THEFOXUP_DRY_RUN:-0}"
  local prompt_confirm="${THEFOXUP_PROMPT_CONFIRM:-1}"

  # Reject non-numeric environment overrides early (defense in depth)
  require_uint "THEFOXUP_DRY_RUN" "$dry_run" || return 1
  require_uint "THEFOXUP_PROMPT_CONFIRM" "$prompt_confirm" || return 1
  require_uint_min "THEFOXUP_APT_TIMEOUT" "$APT_TIMEOUT" 1 \
    "0 would disable the hard timeout and break the log reader deadline" || return 1
  require_uint_min "THEFOXUP_APT_KILL_AFTER" "$APT_KILL_AFTER" 1 \
    "0 would disable the forced kill" || return 1
  require_uint "THEFOXUP_HEARTBEAT_INTERVAL" "$HEARTBEAT_INTERVAL" || return 1
  require_uint "THEFOXUP_REBOOT_DELAY" "$REBOOT_DELAY" || return 1
  require_uint "THEFOXUP_LOG_CLEAN_DAYS" "$LOG_CLEAN_DAYS" || return 1

  # Check mode: read-only system status
  if [[ "$mode" == "check" ]]; then
    run_mode_check
    return
  fi

  # Unknown modes are rejected before any system operation (fail fast)
  case "$mode" in
    lite|full|off) ;;
    *)
      echo "${RED}❌ Unknown mode: $mode${RESET}" >&2
      return 1
      ;;
  esac

  validate_environment
  init_logging
  local hostname_str
  hostname_str=$(timeout 2 hostname -f 2>/dev/null || hostname)
  log_event "thefoxup started — mode=$mode dry_run=$dry_run host=$hostname_str"
  log_event "Environment validated"

  if [[ "$dry_run" -eq 1 ]]; then
    run_dry_run
    return 0
  fi

  run_update_flow "$mode" "$prompt_confirm"
}
