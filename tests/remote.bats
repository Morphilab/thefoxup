#!/usr/bin/env bats
# Functional tests for remote_functions.sh.
# ssh is stubbed (records invocations); yq is REAL so YAML parsing is genuine.

load helpers/stubs

setup() { common_setup; }
teardown() { common_teardown; }

# --- run_remote -------------------------------------------------------

@test "run_remote rejects invalid mode" {
  load_remote_library
  run run_remote "h1" "admin" "/opt/x" "bogus" "1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid mode 'bogus'"* ]]
  [[ "$(cat "$STUBS/calls.log")" == "" ]]
}

@test "run_remote targets user@host and passes ssh hardening options" {
  THEFOXUP_SSH_CONNECT_TIMEOUT=7
  THEFOXUP_SSH_STRICT_HOST_KEY_CHECKING=no
  load_remote_library
  run run_remote "10.0.0.5" "admin" "/opt/thefoxup" "lite" "1"
  [ "$status" -eq 0 ]
  line=$(grep '^ssh ' "$STUBS/calls.log")
  [[ "$line" == *"-o ConnectTimeout=7"* ]]
  [[ "$line" == *"StrictHostKeyChecking=no"* ]]
  [[ "$line" == *"ServerAliveInterval=30"* ]]
  [[ "$line" == *"-- admin@10.0.0.5"* ]]
}

@test "run_remote omits user prefix when user is empty" {
  load_remote_library
  run run_remote "10.0.0.5" "" "/opt/thefoxup" "lite" "1"
  [ "$status" -eq 0 ]
  [[ "$(grep '^ssh ' "$STUBS/calls.log")" == *"-- 10.0.0.5 "* ]]
}

@test "run_remote embeds correct b64 path, session timeout and mode" {
  THEFOXUP_REMOTE_SESSION_TIMEOUT=77
  load_remote_library
  run run_remote "h1" "admin" "/opt/deploy dir" "full" "2"
  [ "$status" -eq 0 ]
  expected_b64=$(printf '%s' "/opt/deploy dir" | base64 -w0)
  # The remote command spans multiple lines, so match against the whole log
  local_log=$(cat "$STUBS/calls.log")
  [[ "$local_log" == *"$expected_b64"* ]]
  [[ "$local_log" == *"timeout 77 bash -c"* ]]
  [[ "$local_log" == *"./foxup.sh full --yes"* ]]
}

@test "run_remote wraps in sudo -u when SUDO_USER is set" {
  load_remote_library
  SUDO_USER=monkey run run_remote "h1" "admin" "/opt/x" "lite" "1"
  [ "$status" -eq 0 ]
  grep -q '^sudo -u monkey ssh ' "$STUBS/calls.log"
}

# --- load_servers_yaml -----------------------------------------------

write_config() {
  CONFIG_FILE="$SETUP_DIR/servers.yaml"
  printf '%s\n' "$@" > "$CONFIG_FILE"
}

@test "load_servers_yaml loads users, hosts and paths" {
  load_remote_library
  write_config \
    "servers:" \
    "  - user: admin" \
    "    host: web1.example.com" \
    "    path: /opt/thefoxup" \
    "  - user: root" \
    "    host: 192.168.1.20" \
    "    path: /srv/thefoxup"
  load_servers_yaml 2>/dev/null
  [ "${#HOSTS[@]}" -eq 2 ]
  [ "${HOSTS[0]}" = "web1.example.com" ]
  [ "${USERS[1]}" = "root" ]
  [ "${PATHS[1]}" = "/srv/thefoxup" ]
}

@test "load_servers_yaml fails when config file is missing" {
  load_remote_library
  CONFIG_FILE="$SETUP_DIR/nope.yaml"
  run load_servers_yaml
  [ "$status" -eq 1 ]
  [[ "$output" == *"servers.yaml not found"* ]]
}

@test "load_servers_yaml fails on invalid YAML syntax" {
  load_remote_library
  write_config "servers: [unclosed"
  run load_servers_yaml
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid YAML syntax"* ]]
}

@test "load_servers_yaml fails when no servers configured" {
  load_remote_library
  write_config "servers: []"
  run load_servers_yaml
  [ "$status" -eq 1 ]
  [[ "$output" == *"No servers configured"* ]]
}

@test "load_servers_yaml warns about deprecated password field" {
  load_remote_library
  write_config \
    "servers:" \
    "  - user: admin" \
    "    host: h1" \
    "    path: /opt/x" \
    "    password: secret"
  run load_servers_yaml
  [ "$status" -eq 0 ]
  [[ "$output" == *"password field is deprecated"* ]]
}

# --- validate_servers -------------------------------------------------

@test "validate_servers accepts a valid configuration" {
  load_remote_library
  USERS=("admin") HOSTS=("web1.example.com") PATHS=("/opt/thefoxup")
  run validate_servers
  [ "$status" -eq 0 ]
}

@test "validate_servers rejects empty host" {
  load_remote_library
  USERS=("admin") HOSTS=("") PATHS=("/opt/x")
  run validate_servers
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty or missing host or path"* ]]
}

@test "validate_servers rejects illegal characters in user" {
  load_remote_library
  USERS=("bad;user") HOSTS=("h1") PATHS=("/opt/x")
  run validate_servers
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid characters in user 'bad;user'"* ]]
}

@test "validate_servers rejects illegal characters in host" {
  load_remote_library
  USERS=("admin") HOSTS=("h1;\$(reboot)") PATHS=("/opt/x")
  run validate_servers
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid characters in host"* ]]
}

@test "validate_servers rejects relative paths" {
  load_remote_library
  USERS=("admin") HOSTS=("h1") PATHS=("relative/path")
  run validate_servers
  [ "$status" -eq 1 ]
  [[ "$output" == *"Path must be absolute"* ]]
}

# --- run_remote_batch -------------------------------------------------

load_batch_fixture() {
  load_remote_library
  has_ssh_agent() { return 0; }   # force parallel-capable branch deterministically
  USERS=("admin" "root" "" "deploy")
  HOSTS=("h1" "h2" "h3" "h4")
  PATHS=("/a" "/b" "/c" "/d")
}

@test "run_remote_batch succeeds when every server succeeds" {
  load_batch_fixture
  run run_remote_batch lite
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ssh ' "$STUBS/calls.log")" -eq 4 ]
  [[ "$output" == *"Running on admin@h1"* ]]
  [[ "$output" != *"Failed:"* ]]
}

@test "run_remote_batch reports failure and returns non-zero" {
  load_batch_fixture
  echo 1 > "$STUBS/ssh.rc"
  run run_remote_batch lite
  [ "$status" -eq 1 ]
  [ "$(grep -c 'Failed:' <<<"$output")" -eq 4 ]
  [[ "$output" == *"4 server(s) failed"* ]]
}

@test "run_remote_batch preserves statuses while throttling parallel jobs" {
  THEFOXUP_MAX_PARALLEL=2
  load_batch_fixture
  # Only server #2 fails; its status must survive the throttled wait order.
  cat > "$STUBS/ssh" <<EOF
#!/bin/bash
printf 'ssh %s\n' "\$*" >> "$STUBS/calls.log"
case "\$*" in *"-- root@h2 "*) exit 1 ;; *) exit 0 ;; esac
EOF
  chmod +x "$STUBS/ssh"
  run run_remote_batch lite
  [ "$status" -eq 1 ]
  [ "$(grep -c '^ssh ' "$STUBS/calls.log")" -eq 4 ]
  [ "$(grep -c 'Failed:' <<<"$output")" -eq 1 ]
  [[ "$output" == *"Failed: root@h2"* ]]
  [[ "$output" == *"1 server(s) failed"* ]]
}

@test "run_remote_batch skips out-of-range selections gracefully" {
  load_batch_fixture
  run run_remote_batch lite 99
  [ "$status" -eq 0 ]
  [[ "$output" == *"Invalid server number: 99"* ]]
  [[ "$(cat "$STUBS/calls.log")" == "" ]]
}

@test "run_remote_batch skips non-numeric selections gracefully" {
  load_batch_fixture
  run run_remote_batch lite abc
  [ "$status" -eq 0 ]
  [[ "$output" == *"Invalid selection: 'abc'"* ]]
  [[ "$(cat "$STUBS/calls.log")" == "" ]]
}

@test "run_remote_batch falls back to sequential without ssh agent" {
  load_batch_fixture
  has_ssh_agent() { return 1; }
  run run_remote_batch lite
  [ "$status" -eq 0 ]
  [[ "$output" == *"No SSH agent detected — running servers sequentially"* ]]
  [ "$(grep -c '^ssh ' "$STUBS/calls.log")" -eq 4 ]
}
