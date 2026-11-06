# Security Policy

## Supported Versions

Only the latest version (`v1.1.1`) is actively supported. This is the current stable release.

## Reporting a Vulnerability

If you discover a security issue in thefoxup, please report it responsibly.

**Please do not** open a public GitHub issue.

Instead, open a **private vulnerability report** on GitHub (recommended).

We will acknowledge and triage your report as soon as possible, normally within
a few business days.

## Scope
- This policy applies to the thefoxup script and its repository.
- The script runs with root privileges and performs system updates/reboots.

## Technical Security Measures
- **SSH authentication**: Only key-based SSH is accepted (no password/sshpass support)
- **Configuration**: `servers.yaml` is gitignored and should be `chmod 600`
- **Locking**: Atomic `flock` (kernel FD-based) prevents concurrent executions, including direct `mode.sh` invocations (child processes inherit the parent's lock)
- **Input validation**: Modes, server host/user/path and numeric environment
  overrides (`THEFOXUP_*_TIMEOUT`, `THEFOXUP_REBOOT_DELAY`,
  `THEFOXUP_MAX_PARALLEL`, etc.) are validated against allowlists. The SSH
  host-key policy (`THEFOXUP_SSH_STRICT_HOST_KEY_CHECKING`) is forwarded
  verbatim to `ssh -o`; set it only to a valid OpenSSH value.
- **Path encoding**: Remote paths are base64-encoded to prevent injection via special characters
- **Remote sudo**: Remote hosts require passwordless sudo for `apt`, `reboot`, `poweroff`
- **Timeouts**: Each remote apt command is bounded by `THEFOXUP_APT_TIMEOUT`; the whole remote session is bounded by `THEFOXUP_REMOTE_SESSION_TIMEOUT` (both must be >= 1, so a long upgrade is not killed mid-`dpkg` and the session bound cannot be disabled by `0`)
- **Non-interactive safety**: Confirmation prompts before reboot/shutdown are enabled by default on every entrypoint (CLI without `--yes`, interactive menu, and direct `mode.sh` wrappers); use `--yes` to override
- **Logging**: apt output from update and dry-run executions is logged; log files are created with `chmod 600`. `--check` is read-only and does not create a log file.

Thank you for helping keep thefoxup secure.
