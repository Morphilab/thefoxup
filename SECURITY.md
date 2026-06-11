# Security Policy

## Supported Versions

Only the latest version (`v1.0.0`) is actively supported. This is the current stable release.

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
- **Locking**: Atomic `flock` (kernel FD-based) prevents concurrent executions
- **Input validation**: All user input (modes, server host/user/path) is validated against allowlists
- **Path encoding**: Remote paths are base64-encoded to prevent injection via special characters
- **Remote sudo**: Remote hosts require passwordless sudo for `apt`, `reboot`, `poweroff`
- **Non-interactive safety**: Confirmation prompts are enabled by default; use `--yes` to override
- **Logging**: All apt output is logged; log files are created with `chmod 600`

Thank you for helping keep thefoxup secure.