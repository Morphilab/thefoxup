#!/usr/bin/env bats
# Integration tests: run mode.sh as a subprocess.
# Only covers paths reachable WITHOUT root; root-required flows are skipped.

load helpers/stubs

MODE_SH="$PROJECT_ROOT/mode.sh"

setup() {
  SETUP_DIR="$(mktemp -d)"
  export THEFOXUP_LOCK="$SETUP_DIR/thefoxup.lock"
}

teardown() { common_teardown; }

@test "mode.sh without arguments prints usage and exits non-zero" {
  run "$MODE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "mode.sh rejects unknown mode before the root check" {
  run "$MODE_SH" bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown mode: bogus"* ]]
  [[ "$output" != *"as root"* ]]
}

@test "mode.sh refuses to run while another instance holds the lock" {
  exec 9>"$THEFOXUP_LOCK"
  flock -n 9   # hold the lock for this test process
  run "$MODE_SH" lite
  [ "$status" -eq 1 ]
  [[ "$output" == *"Another instance is already running"* ]]
  exec 9>&-
}

@test "mode.sh lite reaches the root check when unprivileged" {
  if [[ $EUID -eq 0 ]]; then
    skip "running as root: root-check path not exercised"
  fi
  run "$MODE_SH" lite
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be run as root"* ]]
}
