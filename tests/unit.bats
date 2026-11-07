#!/usr/bin/env bats
# Functional tests for update_functions.sh.
# All externals are stubbed (PATH sandbox); nothing touches the system.
#
# NOTE for maintainers: tests in this file pin CURRENT behavior. The only
# intentional behavior change vs the previous release is covered separately
# ("unknown mode fails fast"), added together with that change.

load helpers/stubs

setup() { common_setup; }
teardown() { common_teardown; }

@test "require_uint accepts a plain integer" {
  load_sandboxed_library
  run require_uint "THEFOXUP_TEST_VAR" "42"
  [ "$status" -eq 0 ]
}

@test "require_uint rejects text with a clear error" {
  load_sandboxed_library
  run require_uint "THEFOXUP_TEST_VAR" "abc"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a non-negative integer"* ]]
  [[ "$output" == *"got: 'abc'"* ]]
}

@test "require_uint rejects negative numbers" {
  load_sandboxed_library
  run require_uint "THEFOXUP_TEST_VAR" "-3"
  [ "$status" -eq 1 ]
}

@test "require_uint rejects empty values" {
  load_sandboxed_library
  run require_uint "THEFOXUP_TEST_VAR" ""
  [ "$status" -eq 1 ]
}

@test "apt_with_retry succeeds on first attempt" {
  load_sandboxed_library
  init_test_log
  run apt_with_retry "Package list update" apt-get update
  [ "$status" -eq 0 ]
  local_lines=$(grep -c '^apt-get update$' "$STUBS/calls.log")
  [ "$local_lines" -eq 1 ]
}

@test "apt_with_retry retries on apt lock and then succeeds" {
  load_sandboxed_library
  init_test_log
  echo 2 > "$STUBS/apt-get.locks_left"
  run apt_with_retry "Package list update" apt-get update
  [ "$status" -eq 0 ]
  local_lines=$(grep -c '^apt-get update$' "$STUBS/calls.log")
  [ "$local_lines" -eq 3 ]
  [[ "$output" == *"retrying in 5s"* ]]
}

@test "apt_with_retry propagates non-lock failure exit code" {
  load_sandboxed_library
  init_test_log
  echo 7 > "$STUBS/apt-get.rc"
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  [ "$status" -eq 7 ]
  local_lines=$(grep -c '^apt-get dist-upgrade -y$' "$STUBS/calls.log")
  [ "$local_lines" -eq 1 ]
}

@test "apt_with_retry gives up after max attempts on persistent lock" {
  load_sandboxed_library
  init_test_log
  echo 99 > "$STUBS/apt-get.locks_left"
  run apt_with_retry "Package list update" apt-get update
  [ "$status" -eq 1 ]
  local_lines=$(grep -c '^apt-get update$' "$STUBS/calls.log")
  [ "$local_lines" -eq 3 ]
}

@test "execute_mode aborts on non-numeric env without running apt" {
  # Assign BEFORE loading: readonly constants capture values at source time
  THEFOXUP_APT_TIMEOUT=abc
  load_sandboxed_library
  run execute_mode lite
  [ "$status" -eq 1 ]
  [[ "$(cat "$STUBS/calls.log")" == "" ]]
}

@test "execute_mode check reports status read-only" {
  load_sandboxed_library
  printf 'nginx/focal-upgrades,focal 1.18.0 amd64 [upgradable from: 1.17]\n' > "$STUBS/apt.out"
  df_out='Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1        40G   12G   28G  30% /'
  printf '%s\n' "$df_out" > "$STUBS/df.out"
  run execute_mode check
  [ "$status" -eq 0 ]
  [[ "$output" == *"System status check"* ]]
  [[ "$output" == *"Upgradable packages"* ]]
  [[ "$output" == *"nginx/focal-upgrades"* ]]
  [[ "$output" == *"/dev/sda1"* ]]
  grep -q '^apt list --upgradable$' "$STUBS/calls.log"
  grep -q '^timeout -k 30 600 env LC_ALL=C apt list --upgradable$' "$STUBS/calls.log"
  ! grep -q '^apt-get' "$STUBS/calls.log"
  [[ ! -d "$SETUP_DIR/logs" ]]
}

@test "execute_mode dry-run lists upgrades without applying them" {
  load_sandboxed_library
  THEFOXUP_DRY_RUN=1 run execute_mode full
  [ "$status" -eq 0 ]
  grep -q '^apt-get update$' "$STUBS/calls.log"
  ! grep -q 'dist-upgrade' "$STUBS/calls.log"
  ! grep -q '^reboot ' "$STUBS/calls.log"
  grep -q 'Dry-run completed' "$SETUP_DIR/logs/update_test.log"
}

@test "execute_mode lite runs full update sequence without reboot" {
  load_sandboxed_library
  run execute_mode lite
  [ "$status" -eq 0 ]
  grep -q '^apt-get update$' "$STUBS/calls.log"
  grep -q '^apt-get dist-upgrade -y -o Dpkg::Options::=--force-confold$' "$STUBS/calls.log"
  grep -q '^apt-get autoremove -y$' "$STUBS/calls.log"
  grep -q '^apt-get autoclean$' "$STUBS/calls.log"
  ! grep -q '^reboot ' "$STUBS/calls.log"
  ! grep -q '^poweroff ' "$STUBS/calls.log"
  [[ "$output" == *"LITE mode completed"* ]]
}

@test "execute_mode full reboots when confirmation is disabled" {
  load_sandboxed_library
  THEFOXUP_PROMPT_CONFIRM=0 THEFOXUP_REBOOT_DELAY=0 run execute_mode full
  [ "$status" -eq 0 ]
  grep -q '^reboot $' "$STUBS/calls.log"
}

@test "execute_mode off shuts down when confirmation is disabled" {
  load_sandboxed_library
  THEFOXUP_PROMPT_CONFIRM=0 THEFOXUP_REBOOT_DELAY=0 run execute_mode off
  [ "$status" -eq 0 ]
  grep -q '^poweroff $' "$STUBS/calls.log"
}

@test "execute_mode full cancels reboot when prompt is declined" {
  load_sandboxed_library
  THEFOXUP_REBOOT_DELAY=0 run execute_mode full <<< "n"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Reboot cancelled"* ]]
  ! grep -q '^reboot ' "$STUBS/calls.log"
}

@test "execute_mode lite propagates update failure" {
  load_sandboxed_library
  echo 1 > "$STUBS/apt-get.rc"
  run execute_mode lite
  [ "$status" -eq 1 ]
  [[ "$output" != *"LITE mode completed"* ]]
  grep -q 'System update FAILED' "$SETUP_DIR/logs/update_test.log"
}

@test "init_logging honors THEFOXUP_LOG_DIR override" {
  # Fresh process without the sandboxed overrides: exercise the real helper
  SETUP_DIR="$(mktemp -d)"
  export PATH="/usr/bin:/bin"
  PROJECT_ROOT="${BATS_TEST_DIRNAME}/.."
  export THEFOXUP_LOG_DIR="$SETUP_DIR/logs"
  run bash -c '
    source "'"$PROJECT_ROOT"'/update_functions.sh"
    init_colors
    init_logging
    case "$LOG_FILE" in "'"$SETUP_DIR"'/logs/"update_*.log) ;; *) exit 9 ;; esac
    [[ -s "$LOG_FILE" ]] || exit 10
  '
  local rc=$?
  unset THEFOXUP_LOG_DIR
  [ "$rc" -eq 0 ]
}

@test "execute_mode rejects unknown mode before touching the system" {
  load_sandboxed_library
  run execute_mode bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown mode: bogus"* ]]
  [[ "$(cat "$STUBS/calls.log")" == "" ]]
  [[ ! -f "$SETUP_DIR/logs/update_test.log" ]]
}

@test "apt_with_retry passes kill-after grace and duration to timeout" {
  load_sandboxed_library
  init_test_log
  run apt_with_retry "Package list update" apt-get update
  [ "$status" -eq 0 ]
  grep -q '^timeout -k 30 600 env LC_ALL=C apt-get update$' "$STUBS/calls.log"
}

@test "apt_with_retry honors THEFOXUP_APT_KILL_AFTER override" {
  THEFOXUP_APT_KILL_AFTER=45
  load_sandboxed_library
  init_test_log
  run apt_with_retry "Package list update" apt-get update
  [ "$status" -eq 0 ]
  grep -q '^timeout -k 45 600 env LC_ALL=C apt-get update$' "$STUBS/calls.log"
}

@test "apt_with_retry reports a clean stop when apt is TERM-killed (rc=124)" {
  load_sandboxed_library
  init_test_log
  echo 124 > "$STUBS/timeout.rc"
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  [ "$status" -eq 124 ]
  [[ "$output" == *"timed out after 600s"* ]]
  [[ "$output" == *"dpkg --configure -a"* ]]
  [[ "$output" == *"Stall diagnostics saved"* ]]
  [ "$(grep -c '^timeout -k 30 600 env ' "$STUBS/calls.log")" -eq 1 ]
  grep -q 'stopped after .*s (rc=124; timeout=600s kill-after=30s)' "$SETUP_DIR/logs/update_test.log"
  grep -q 'stall diagnostics: System upgrade' "$SETUP_DIR/logs/update_test.log"
  # The diagnostics must report every lock the cleanup could act on.
  grep -q '^fuser -v /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock$' "$STUBS/calls.log"
  # Nothing held the locks, so no lock-holder intervention is attempted.
  [[ "$output" != *"Lock holders"* ]]
  ! grep -q '^fuser -k' "$STUBS/calls.log"
}

@test "apt_with_retry reports a force-kill when SIGTERM is ignored (rc=137)" {
  load_sandboxed_library
  init_test_log
  echo 137 > "$STUBS/timeout.rc"
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  [ "$status" -eq 137 ]
  [[ "$output" == *"force-killed"* ]]
  [ "$(grep -c '^timeout -k 30 600 env ' "$STUBS/calls.log")" -eq 1 ]
  grep -q 'rc=137; timeout=600s kill-after=30s' "$SETUP_DIR/logs/update_test.log"
}

@test "apt_with_retry closes stdin so a stray read cannot block" {
  load_sandboxed_library
  init_test_log
  touch "$STUBS/apt-get.read_stdin"
  run apt_with_retry "Package list update" apt-get update <<< "DANGER"
  [ "$status" -eq 0 ]
  [[ "$output" != *"STDIN:DANGER"* ]]
}

@test "apt_with_retry heartbeats while a long command runs" {
  THEFOXUP_HEARTBEAT_INTERVAL=1
  load_sandboxed_library
  init_test_log
  make_real_sleep_stub
  echo 4 > "$STUBS/apt-get.delay"
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"still running"* ]]
  grep -q 'still running' "$SETUP_DIR/logs/update_test.log"
}

@test "execute_mode dry-run warns when the cache refresh fails" {
  load_sandboxed_library
  echo 1 > "$STUBS/apt-get.rc"
  THEFOXUP_DRY_RUN=1 run execute_mode full
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache refresh failed"* ]]
  grep -q 'Dry-run cache refresh failed (1)' "$SETUP_DIR/logs/update_test.log"
}

@test "execute_mode full aborts cleanly when no interactive input is available" {
  load_sandboxed_library
  THEFOXUP_REBOOT_DELAY=0 run execute_mode full </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"No interactive input"* ]]
  ! grep -q '^reboot ' "$STUBS/calls.log"
}

@test "init_colors survives a broken terminal environment" {
  command -v script >/dev/null 2>&1 || skip "script command not available"
  run script -qec "env -u TERM bash -c 'source \"$PROJECT_ROOT/update_functions.sh\"; init_colors; echo COLORS_OK'" /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"COLORS_OK"* ]]
}

@test "apt watchdog traps TERM and reaps its sleep child" {
  THEFOXUP_HEARTBEAT_INTERVAL=30
  load_sandboxed_library
  make_real_sleep_stub
  _apt_watchdog "$(date +%s)" "Test label" &
  wd=$!
  sleep 0.2
  kill "$wd"
  wait "$wd" 2>/dev/null || true
  sleep 0.2
  ! pgrep -f '^/bin/sleep 30$' >/dev/null
}

@test "apt_best_effort swallows ordinary failures but not stalls" {
  load_sandboxed_library
  init_test_log
  echo 7 > "$STUBS/apt-get.rc"
  run apt_best_effort "Autoremove" apt-get autoremove -y
  [ "$status" -eq 0 ]
  echo 137 > "$STUBS/timeout.rc"
  run apt_best_effort "Autoremove" apt-get autoremove -y
  [ "$status" -eq 137 ]
  echo 141 > "$STUBS/timeout.rc"
  run apt_best_effort "Autoremove" apt-get autoremove -y
  [ "$status" -eq 141 ]
}

@test "dump_stall_diagnostics reports when the log is not writable" {
  load_sandboxed_library
  LOG_FILE=""
  run dump_stall_diagnostics "System upgrade"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not save stall diagnostics"* ]]
}

@test "apt_with_retry force-kills a TERM-immune command with the real timeout" {
  THEFOXUP_APT_TIMEOUT=1
  THEFOXUP_APT_KILL_AFTER=1
  load_sandboxed_library
  init_test_log
  rm -f "$STUBS/timeout"
  cat > "$STUBS/apt-get" <<'EOF'
#!/bin/bash
trap '' TERM
while :; do /bin/sleep 0.2; done
EOF
  chmod +x "$STUBS/apt-get"
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  [ "$status" -eq 137 ]
  [[ "$output" == *"force-killed"* ]]
  grep -q 'rc=137; timeout=1s kill-after=1s' "$SETUP_DIR/logs/update_test.log"
}

@test "apt_with_retry concludes when a killed command leaves a pipe holder" {
  THEFOXUP_APT_TIMEOUT=1
  THEFOXUP_APT_KILL_AFTER=1
  load_sandboxed_library
  init_test_log
  rm -f "$STUBS/timeout"
  cat > "$STUBS/apt-get" <<'EOF'
#!/bin/bash
( /bin/sleep 15 ) &
exit 137
EOF
  chmod +x "$STUBS/apt-get"
  start=$(date +%s)
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 137 ]
  [ "$elapsed" -le 11 ]
  [[ "$output" == *"force-killed"* ]]
  grep -q 'output reader stopped (survivors held the log pipe)' "$SETUP_DIR/logs/update_test.log"
}

@test "dry-run bounds its log reader like the update path" {
  load_sandboxed_library
  init_test_log
  run run_dry_run
  [ "$status" -eq 0 ]
  grep -q '^timeout -k 30 600 env LC_ALL=C apt-get update$' "$STUBS/calls.log"
  grep -q '^timeout -k 30 600 env LC_ALL=C apt list --upgradable$' "$STUBS/calls.log"
  grep -q '^timeout -k 5 635 tee -a ' "$STUBS/calls.log"
}

@test "dry-run concludes when a killed cache refresh leaves a pipe holder" {
  THEFOXUP_APT_TIMEOUT=1
  THEFOXUP_APT_KILL_AFTER=1
  load_sandboxed_library
  init_test_log
  rm -f "$STUBS/timeout"
  cat > "$STUBS/apt-get" <<'EOF'
#!/bin/bash
( /bin/sleep 15 ) &
exit 137
EOF
  chmod +x "$STUBS/apt-get"
  start=$(date +%s)
  run run_dry_run
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  [ "$elapsed" -le 11 ]
  [[ "$output" == *"cache refresh failed (rc=137)"* ]]
  grep -q 'Dry-run cache refresh: output reader stopped (survivors held the log pipe)' \
    "$SETUP_DIR/logs/update_test.log"
}

@test "apt_with_retry treats a SIGPIPE death as a stall" {
  load_sandboxed_library
  init_test_log
  echo 141 > "$STUBS/timeout.rc"
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  [ "$status" -eq 141 ]
  [[ "$output" == *"SIGPIPE"* ]]
  [[ "$output" == *"dpkg --configure -a"* ]]
  grep -q 'rc=141; timeout=600s kill-after=30s' "$SETUP_DIR/logs/update_test.log"
  grep -q 'stall diagnostics: System upgrade' "$SETUP_DIR/logs/update_test.log"
}

@test "apt_with_retry asks leftover lock holders to stop with SIGTERM" {
  load_sandboxed_library
  init_test_log
  /bin/sleep 30 &
  holder=$!
  echo "$holder" > "$STUBS/fuser.out"
  echo 124 > "$STUBS/timeout.rc"
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  [ "$status" -eq 124 ]
  [[ "$output" == *"Lock holders asked to stop"* ]]
  [[ "$output" != *"force-stopped"* ]]
  wait "$holder" 2>/dev/null || true
  ! kill -0 "$holder" 2>/dev/null
  grep -q 'lock holders asked to stop (SIGTERM)' "$SETUP_DIR/logs/update_test.log"
  # The cleanup queries the same lock list the diagnostics report on.
  grep -q '^fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock$' "$STUBS/calls.log"
}

@test "apt_with_retry force-stops a lock holder that ignores SIGTERM" {
  THEFOXUP_APT_KILL_AFTER=1
  load_sandboxed_library
  init_test_log
  /bin/bash -c 'trap "" TERM; while :; do /bin/sleep 0.2; done' &
  holder=$!
  echo "$holder" > "$STUBS/fuser.out"
  echo 124 > "$STUBS/timeout.rc"
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  [ "$status" -eq 124 ]
  [[ "$output" == *"ignored SIGTERM were force-stopped"* ]]
  wait "$holder" 2>/dev/null || true
  ! kill -0 "$holder" 2>/dev/null
  grep -q 'force-stopped (ignored SIGTERM)' "$SETUP_DIR/logs/update_test.log"
}

@test "apt_with_retry leaves lock holders alone on an ordinary failure" {
  load_sandboxed_library
  init_test_log
  echo 7 > "$STUBS/apt-get.rc"
  run apt_with_retry "System upgrade" apt-get dist-upgrade -y
  [ "$status" -eq 7 ]
  [[ "$output" != *"Lock holders"* ]]
  ! grep -q '^fuser ' "$STUBS/calls.log"
}

@test "check mode concludes when the query leaves a pipe holder" {
  THEFOXUP_APT_TIMEOUT=1
  THEFOXUP_APT_KILL_AFTER=1
  load_sandboxed_library
  rm -f "$STUBS/timeout"
  cat > "$STUBS/apt" <<'EOF'
#!/bin/bash
( /bin/sleep 15 ) &
exit 124
EOF
  chmod +x "$STUBS/apt"
  start=$(date +%s)
  run execute_mode check
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  [ "$elapsed" -le 11 ]
  [[ "$output" == *"Package query did not complete (rc=124)"* ]]
  [[ ! -d "$SETUP_DIR/logs" ]]
}

@test "kernel marking runs under the hard timeout" {
  load_sandboxed_library
  init_test_log
  printf 'linux-image-%s\n' "$(uname -r)" > "$STUBS/dpkg-query.out"
  run update_system
  [ "$status" -eq 0 ]
  grep -q "^timeout -k 30 600 dpkg-query -W " "$STUBS/calls.log"
  grep -q "^timeout -k 30 600 apt-mark manual linux-image-$(uname -r)$" "$STUBS/calls.log"
}

@test "stall cleanup warns when fuser is not available" {
  load_sandboxed_library
  init_test_log
  # PATH with only what the warning path needs (date for the log line), so
  # `command -v fuser` genuinely finds nothing.
  mkdir -p "$STUBS/minbin"
  ln -sf "$(command -v date)" "$STUBS/minbin/date"
  saved_path="$PATH"
  PATH="$STUBS/minbin"
  run _stop_leftover_lock_holders
  PATH="$saved_path"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fuser not available — leftover apt/dpkg lock holders were not stopped"* ]]
  grep -q 'fuser not available: leftover apt/dpkg lock holders were not stopped' "$SETUP_DIR/logs/update_test.log"
}

@test "execute_mode rejects a zero apt timeout before running apt" {
  THEFOXUP_APT_TIMEOUT=0
  load_sandboxed_library
  run execute_mode lite
  [ "$status" -eq 1 ]
  [[ "$output" == *"THEFOXUP_APT_TIMEOUT must be >= 1"* ]]
  [[ "$(cat "$STUBS/calls.log")" == "" ]]
}

@test "execute_mode rejects a zero kill-after before running apt" {
  THEFOXUP_APT_KILL_AFTER=0
  load_sandboxed_library
  run execute_mode lite
  [ "$status" -eq 1 ]
  [[ "$output" == *"THEFOXUP_APT_KILL_AFTER must be >= 1"* ]]
  [[ "$(cat "$STUBS/calls.log")" == "" ]]
}

@test "watchdog cleanup kills a sleep child forked just before the trap" {
  load_sandboxed_library
  make_real_sleep_stub
  /bin/sleep 30 &
  child=$!
  _apt_watchdog_cleanup
  wait "$child" 2>/dev/null || true
  ! kill -0 "$child" 2>/dev/null
}

@test "watchdog leaves no orphan sleep when TERM lands as it starts" {
  THEFOXUP_HEARTBEAT_INTERVAL=30
  load_sandboxed_library
  make_real_sleep_stub
  # Runs in a subshell with the harness traps cleared: the watchdog is killed
  # before it can install its own trap, and a signal death of that background
  # job must not be reported as a test failure by the inherited ERR trap.
  (
    trap - ERR DEBUG EXIT
    for _ in 1 2 3 4 5; do
      _apt_watchdog "$(date +%s)" "Test label" &
      wd=$!
      kill "$wd" 2>/dev/null || true
      wait "$wd" 2>/dev/null || true
    done
  )
  sleep 0.3
  ! pgrep -f '^/bin/sleep 30$' >/dev/null
}
