# Changelog

## [1.1.0] - 2026-09-06

### Fixed
- Confirmation prompts before reboot/shutdown are now enabled by default on
  every entrypoint (CLI without `--yes`, interactive menu, and direct
  `mode-*.sh` wrappers), matching the documented behavior
- Remote batch execution no longer loses exit statuses of SSH jobs that finish
  while new servers are being launched, which could report success despite a
  failed server
- apt lock-conflict retry detection no longer depends on the system locale
  (`LC_ALL=C` enforced for apt output parsing)
- Numeric environment variables are validated at startup; invalid values abort
  with a clear error instead of failing later (or being interpolated into
  remote commands)
- `apt_with_retry` now propagates the real apt exit status; previously
  `PIPESTATUS` was clobbered by an unconditional `|| true` under pipefail,
  making failed apt commands report success

### Added
- `THEFOXUP_REMOTE_SESSION_TIMEOUT` (default `1800`) bounds the whole remote
  session independently from the per-command `THEFOXUP_APT_TIMEOUT`, so long
  upgrades are no longer killed mid-dpkg by an outer timeout
- Direct `mode.sh` / `mode-*.sh` invocations are now protected by the same
  `flock` instance lock as `foxup.sh`
- Functional test suite (bats-core) covering mode execution, apt lock retry,
  dry-run and dispatcher integration with stubbed externals; the SSH remote
  layer (connection options, YAML loading/validation, parallel batch) is
  covered through `remote.bats`

### Changed
- Lockfile is kept on disk after exit (only the FD is closed), removing a
  classic flock-unlink race window
- ShellCheck policy tightened: unused/invalid exclusions removed and findings
  fixed or suppressed inline; CI runs smoke tests in addition to ShellCheck
- `execute_mode` refactored into `run_mode_check`, `run_dry_run` and
  `run_update_flow`; unknown modes are now rejected before any system
  operation instead of after the update
- Log directory can be relocated via `THEFOXUP_LOG_DIR` (default unchanged:
  `/var/log/thefoxup`)
- Remote execution helpers (`run_remote`, `run_remote_batch`, YAML loading
  and validation) moved to `remote_functions.sh`, mirroring the update
  library layout

## [1.0.0]

Initial release.
