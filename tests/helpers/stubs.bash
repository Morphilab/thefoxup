#!/bin/bash
# Shared stub helpers for thefoxup bats suites.
# Sourced by *.bats files via bats' `load` macro. Creates sandboxed stub
# commands that record their invocations in $STUBS/calls.log so tests can
# assert which external commands ran and in what order.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Record-only stub: appends "name args" to calls.log, prints $STUBS/<name>.out
# if present, exits 0.
make_record_stub() {
  local name="$1"
  cat > "$STUBS/$name" <<EOF
#!/bin/bash
printf '%s %s\n' "$name" "\$*" >> "$STUBS/calls.log"
[[ -f "$STUBS/$name.out" ]] && cat "$STUBS/$name.out"
exit 0
EOF
  chmod +x "$STUBS/$name"
}

# timeout shim: records its arguments. Drops an optional "-k <grace>" and the
# duration, then execs the real command. If $STUBS/timeout.rc exists, exits
# with that code instead (simulates timeout stopping the command).
make_timeout_stub() {
  cat > "$STUBS/timeout" <<EOF
#!/bin/bash
printf 'timeout %s\n' "\$*" >> "$STUBS/calls.log"
if [[ -f "$STUBS/timeout.rc" ]]; then
  exit "\$(<"$STUBS/timeout.rc")"
fi
if [[ "\${1:-}" == "-k" ]]; then shift 2; fi
shift
exec "\$@"
EOF
  chmod +x "$STUBS/timeout"
}

# Real-sleep stub used by heartbeat tests: the default sleep stub returns
# instantly, which would make the watchdog busy-spin instead of waiting.
make_real_sleep_stub() {
  cat > "$STUBS/sleep" <<'EOF'
#!/bin/bash
exec /bin/sleep "$@"
EOF
  chmod +x "$STUBS/sleep"
}

# Stateful apt-get stub. Behavior controlled by files inside $STUBS:
#   apt-get.locks_left -> first N calls print an apt lock error and exit 100
#   apt-get.rc         -> exit code for normal calls        (default 0)
#   apt-get.out        -> stdout for normal calls           (default empty)
#   apt-get.delay      -> sleep N seconds before answering (slow apt)
#   apt-get.read_stdin -> try to read one line from stdin and echo it back
make_apt_get_stub() {
  cat > "$STUBS/apt-get" <<EOF
#!/bin/bash
printf '%s %s\n' "apt-get" "\$*" >> "$STUBS/calls.log"
if [[ -f "$STUBS/apt-get.delay" ]]; then
  /bin/sleep "\$(<"$STUBS/apt-get.delay")"
fi
if [[ -f "$STUBS/apt-get.read_stdin" ]]; then
  if read -r line; then printf 'STDIN:%s\n' "\$line"; fi
fi
locks_file="$STUBS/apt-get.locks_left"
if [[ -f "\$locks_file" ]]; then
  left=\$(<"\$locks_file")
  if [[ "\$left" -gt 0 ]]; then
    printf '%s\n' "\$((left - 1))" > "\$locks_file"
    echo "E: Could not get lock /var/lib/dpkg/lock-frontend - open (11: Resource temporarily unavailable)"
    exit 100
  fi
fi
rc=0
[[ -f "$STUBS/apt-get.rc" ]] && rc=\$(<"$STUBS/apt-get.rc")
[[ -f "$STUBS/apt-get.out" ]] && cat "$STUBS/apt-get.out"
exit "\$rc"
EOF
  chmod +x "$STUBS/apt-get"
  echo 0 > "$STUBS/apt-get.rc"
}

# Full sandbox used by most unit tests: stub bin dir first in PATH plus a
# sourced library whose root-only paths are neutralized.
common_setup() {
  SETUP_DIR="$(mktemp -d)"
  STUBS="$SETUP_DIR/bin"
  mkdir -p "$STUBS"
  : > "$STUBS/calls.log"
  PATH="$STUBS:$PATH"
  # Keep the apt heartbeat watchdog off by default in tests: the stubbed sleep
  # returns instantly, which would make it spin instead of waiting. The
  # heartbeat test overrides this and installs a real sleep stub.
  export THEFOXUP_HEARTBEAT_INTERVAL=0

  make_timeout_stub
  make_apt_get_stub
  make_record_stub apt
  make_record_stub reboot
  make_record_stub poweroff
  make_record_stub hostname
  make_record_stub df
  make_record_stub fuser
  make_record_stub dpkg-query
  make_record_stub apt-mark
  make_record_stub sleep
  unset SUDO_USER
  make_record_stub sudo
  make_ssh_stub
  echo testhost > "$STUBS/hostname.out"
}

common_teardown() {
  [[ -n "${SETUP_DIR:-}" && -d "$SETUP_DIR" ]] && rm -rf "$SETUP_DIR"
  return 0
}

# Point $LOG_FILE at the sandbox without touching /var/log.
# Called explicitly by tests exercising low-level helpers directly.
init_test_log() {
  mkdir -p "$SETUP_DIR/logs"
  LOG_FILE="$SETUP_DIR/logs/update_test.log"
  : > "$LOG_FILE"
}

# ssh stub: records full invocation into calls.log, exit code via
# $STUBS/ssh.rc (default 0).
make_ssh_stub() {
  cat > "$STUBS/ssh" <<EOF
#!/bin/bash
printf 'ssh %s\n' "\$*" >> "$STUBS/calls.log"
[[ -f "$STUBS/ssh.rc" ]] && exit \$(<"$STUBS/ssh.rc")
exit 0
EOF
  chmod +x "$STUBS/ssh"
}

# Source both libraries (remote functions depend on colors from the update
# library). Set THEFOXUP_* overrides BEFORE calling: readonly constants
# capture values at source time.
load_remote_library() {
  # shellcheck source=../update_functions.sh
  source "$PROJECT_ROOT/update_functions.sh"
  # shellcheck source=../remote_functions.sh
  source "$PROJECT_ROOT/remote_functions.sh"
  init_colors
}

# Source update_functions.sh and neutralize the root-only helpers so unit
# tests exercise mode logic without EUID 0 or /var/log access.
load_sandboxed_library() {
  # shellcheck source=../update_functions.sh
  source "$PROJECT_ROOT/update_functions.sh"
  init_colors
  # shellcheck disable=SC2317,SC2329 # sandbox redefinitions, invoked by bats
  validate_environment() { :; }
  # shellcheck disable=SC2317,SC2329 # sandbox redefinitions, invoked by bats
  init_logging() { init_test_log; }
}
