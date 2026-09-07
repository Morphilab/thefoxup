# Security Policy

## Supported Versions

Only the latest version (`v1.1.0`) is actively supported. This is the current stable release.

## Reporting a Vulnerability

If you discover a security issue in thefoxup, please report it responsibly.

**Please do not** open a public GitHub issue.

Instead, open a **private vulnerability report** on GitHub (recommended).

We will acknowledge your report within 48 hours and aim to resolve critical issues as quickly as possible.

## Scope
- This policy applies to the thefoxup script and its repository.
- The script runs with root privileges and performs system updates/reboots.

## Technical Security Measures
- **SSH authentication**: Only key-based SSH is accepted (no password/sshpass support)
- **Configuration**: `servers.yaml` is gitignored and should be `chmod 600`
- **Locking**: Atomic `flock` (kernel FD-based) prevents concurrent executions, including direct `mode.sh` invocations (child processes inherit the parent's lock)
- **Input validation**: All user input (modes, server host/user/path) is validated against allowlists, and numeric environment variables (`THEFOXUP_*_TIMEOUT`, `THEFOXUP_REBOOT_DELAY`, `THEFOXUP_MAX_PARALLEL`, etc.) must be non-negative integers
- **Path encoding**: Remote paths are base64-encoded to prevent injection via special characters
- **Remote sudo**: Remote hosts require passwordless sudo for `apt`, `reboot`, `poweroff`
- **Timeouts**: Each remote apt command is bounded by `THEFOXUP_APT_TIMEOUT`; the whole remote session is bounded by `THEFOXUP_REMOTE_SESSION_TIMEOUT` (so long upgrades are not killed mid-`dpkg`)
- **Non-interactive safety**: Confirmation prompts before reboot/shutdown are enabled by default on every entrypoint (CLI without `--yes`, interactive menu, and direct `mode.sh` wrappers); use `--yes` to override
- **Logging**: All apt output is logged; log files are created with `chmod 600`

Thank you for helping keep thefoxup secure.