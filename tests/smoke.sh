#!/bin/bash
set -euo pipefail

# thefoxup v1.0.0 - Smoke test
# Lightweight validation that scripts load, parse flags, and exit cleanly.
# Does NOT touch the system, network, or /var/log.
# https://github.com/Morphilab/thefoxup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_NAME="thefoxup smoke test"
PASS=0
FAIL=0
FAILED_TESTS=()

pass() { echo "  ✅ $1"; ((++PASS)); }
fail() { echo "  ❌ $1"; ((++FAIL)); FAILED_TESTS+=("$1"); }

echo "═══════════════════════════════════════════════════════"
echo "  $TEST_NAME"
echo "═══════════════════════════════════════════════════════"
echo

# 1. All scripts are executable
echo "1. Executable permissions"
for f in foxup.sh mode.sh mode-lite.sh mode-full.sh mode-off.sh update_functions.sh; do
  if [[ -x "$SCRIPT_DIR/$f" ]]; then
    pass "$f is executable"
  else
    fail "$f is NOT executable (run: chmod +x $f)"
  fi
done
echo

# 2. Bash syntax check on every script
echo "2. Bash syntax (bash -n)"
for f in foxup.sh mode.sh mode-lite.sh mode-full.sh mode-off.sh update_functions.sh; do
  if bash -n "$SCRIPT_DIR/$f" 2>/dev/null; then
    pass "$f parses cleanly"
  else
    fail "$f has a syntax error"
  fi
done
echo

# 3. --version and --help exit 0 with expected output
echo "3. CLI flag handling"
if out=$("$SCRIPT_DIR/foxup.sh" --version 2>&1) && [[ "$out" == *"thefoxup v1.0.0"* ]]; then
  pass "--version prints 'thefoxup v1.0.0'"
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

# 6. mode-*.sh wrappers delegate correctly to mode.sh
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
  # File exists locally but is not tracked by git — expected for dev setups
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
