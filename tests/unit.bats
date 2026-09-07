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
