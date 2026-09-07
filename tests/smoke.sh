#!/bin/bash
set -euo pipefail

# thefoxup v1.1.0 - Smoke test
# Lightweight validation that scripts load, parse flags, and exit cleanly.
# Does NOT touch the system, network, or /var/log.
# https://github.com/Morphilab/thefoxup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_NAME="thefoxup smoke test"
PASS=0
FAIL=0
FAILED_TESTS=()

# shellcheck disable=SC2317  # helpers are invoked throughout this script
pass() { echo "  ✅ $1"; ((++PASS)); }
# shellcheck disable=SC2317  # helpers are invoked throughout this script
fail() { echo "  ❌ $1"; ((++FAIL)); FAILED_TESTS+=("$1"); }

echo "═══════════════════════════════════════════════════════"
echo "  $TEST_NAME"
echo "═══════════════════════════════════════════════════════"
echo

# 1. All scripts are executable
echo "1. Executable permissions"
for f in foxup.sh mode.sh mode-lite.sh mode-full.sh mode-off.sh update_functions.sh remote_functions.sh; do
  if [[ -x "$SCRIPT_DIR/$f" ]]; then
    pass "$f is executable"
  else
    fail "$f is NOT executable (run: chmod +x $f)"
  fi
done
echo

# 2. Bash syntax check on every script
echo "2. Bash syntax (bash -n)"
for f in foxup.sh mode.sh mode-lite.sh mode-full.sh mode-off.sh update_functions.sh remote_functions.sh; do
  if bash -n "$SCRIPT_DIR/$f" 2>/dev/null; then
    pass "$f parses cleanly"
  else
    fail "$f has a syntax error"
  fi
done
echo

# 3. --version and --help exit 0 with expected output
echo "3. CLI flag handling"
if out=$("$SCRIPT_DIR/foxup.sh" --version 2>&1) && [[ "$out" == *"thefoxup v1.1.0"* ]]; then
  pass "--version prints the project version"
else
  fail "--version did not print expected version (got: $out)"
fi

if out=$("$SCRIPT_DIR/foxup.sh" --help 2>&1) && [[ "$out" == *"Usage:"* ]]; then
  pass "--help prints usage"
else
  fail "--help did not print usage (got: $out)"
fi

if out=$("$SCRIPT_DIR/foxup.sh" -h 2>&1) && [[ "$out" == *"Usage:"* ]]; then
  pass "-h short flag works"
else
  fail "-h short flag failed"
fi

if out=$("$SCRIPT_DIR/foxup.sh" -v 2>&1) && [[ "$out" == *"thefoxup"* ]]; then
  pass "-v short flag works"
else
  fail "-v short flag failed"
fi
echo

# 4. Unknown option exits non-zero with a clear message
echo "4. Unknown options are rejected"
if "$SCRIPT_DIR/foxup.sh" --bogus 2>/dev/null; then
  fail "--bogus should exit non-zero"
else
  pass "Unknown option rejected (exit code $?)"
fi
echo

# 5. update_functions.sh can be sourced in isolation
echo "5. Library is self-contained"
if (
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/update_functions.sh" && \
  declare -f init_colors >/dev/null && \
  declare -f validate_environment >/dev/null && \
  declare -f update_system >/dev/null && \
  declare -f execute_mode >/dev/null && \
  declare -f apt_with_retry >/dev/null
) 2>/dev/null; then
  pass "update_functions.sh sources and exposes required functions"
else
  fail "update_functions.sh is missing required functions"
fi
echo

# 6. mode-*.sh wrappers exist and are executable
echo "6. Mode wrappers exist and are executable"
for m in lite full off; do
  wrapper="$SCRIPT_DIR/mode-${m}.sh"
  if [[ -x "$wrapper" ]] && head -1 "$wrapper" | grep -q '/bin/bash'; then
    pass "mode-${m}.sh is a valid bash wrapper"
  else
    fail "mode-${m}.sh is missing or invalid"
  fi
done
echo

# 7. .shellcheckrc is present and well-formed
echo "7. ShellCheck config"
if [[ -f "$SCRIPT_DIR/.shellcheckrc" ]] && grep -q '^severity=' "$SCRIPT_DIR/.shellcheckrc"; then
  pass ".shellcheckrc is present and has severity setting"
else
  fail ".shellcheckrc missing or malformed"
fi
echo

# 8. .gitignore protects sensitive config
echo "8. Sensitive file handling"
if grep -q '^servers\.yaml$' "$SCRIPT_DIR/.gitignore"; then
  pass "servers.yaml is gitignored"
else
  fail "servers.yaml is NOT in .gitignore"
fi

if [[ ! -f "$SCRIPT_DIR/servers.yaml" ]]; then
  pass "No local servers.yaml present (clean checkout)"
elif git -C "$SCRIPT_DIR" ls-files --error-unmatch servers.yaml &>/dev/null; then
  fail "servers.yaml is TRACKED by git — should be gitignored"
else
  # File exists locally but is not tracked by git — expected for local developer setups
  pass "servers.yaml exists locally but is NOT tracked by git"
fi
echo

# 9. License present
echo "9. Project metadata"
if [[ -f "$SCRIPT_DIR/LICENSE" ]] && head -1 "$SCRIPT_DIR/LICENSE" | grep -qi 'MIT'; then
  pass "MIT license present"
else
  fail "MIT license missing"
fi
echo

# 10. CI workflow configured
echo "10. CI configuration"
if [[ -f "$SCRIPT_DIR/.github/workflows/shellcheck.yml" ]] && grep -q 'shellcheck' "$SCRIPT_DIR/.github/workflows/shellcheck.yml"; then
  pass "GitHub Actions ShellCheck workflow present"
else
  fail "CI workflow missing"
fi
echo

# 11. Numeric environment validation
echo "11. Numeric environment validation"
if (
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/update_functions.sh" && \
  init_colors && \
  declare -f require_uint >/dev/null && \
  ! require_uint "TEST_VAR" "abc" >/dev/null 2>&1 && \
  require_uint "TEST_VAR" "42" >/dev/null 2>&1
) 2>/dev/null; then
  pass "require_uint rejects non-numeric values and accepts integers"
else
  fail "require_uint missing or misbehaving"
fi
echo

# 12. Standalone mode dispatcher lock guard
echo "12. mode.sh standalone lock"
if grep -q 'flock' "$SCRIPT_DIR/mode.sh"; then
  pass "mode.sh guards concurrent execution with flock"
else
  fail "mode.sh is missing flock protection"
fi
echo

# 13. Split mode-execution subfunctions exist
echo "13. Mode execution subfunctions"
if (
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/update_functions.sh" && \
  declare -f run_mode_check >/dev/null && \
  declare -f run_dry_run >/dev/null && \
  declare -f run_update_flow >/dev/null
) 2>/dev/null; then
  pass "execute_mode delegates to extracted subfunctions"
else
  fail "run_mode_check / run_dry_run / run_update_flow missing"
fi
echo

# Summary
echo "═══════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo "  Results: $PASS passed, $FAIL failed ($TOTAL total)"
echo "═══════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  echo
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  • $t"
  done
  exit 1
fi

echo
echo "All smoke tests passed ✓"
exit 0
