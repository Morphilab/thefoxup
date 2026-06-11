# thefoxup

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/Morphilab/thefoxup/releases/tag/v1.0.0)
[![ShellCheck](https://github.com/Morphilab/thefoxup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/Morphilab/thefoxup/actions/workflows/shellcheck.yml)
[![Bash](https://img.shields.io/badge/bash-5%2B-green.svg)](https://www.gnu.org/software/bash/)

**Secure and simple updater for Debian/Ubuntu servers**

A lightweight, secure Bash tool with colors, YAML configuration and remote SSH support.


## Features
- Three modes: `lite` (updates only), `full` (updates + reboot), `off` (updates + shutdown)
- Beautiful colored output with `tput`
- Modern YAML configuration (`servers.yaml`)
- Local and remote execution (multiple servers via SSH)
- Security-first: lockfile, root check, secure SSH
- Automatic package cleanup
- ShellCheck validated

## ⚠️ AI Disclosure / Divulgación de IA

**English:**  
This project was developed with assistance from artificial intelligence tools. Given the automated nature of some components, users are advised to review and test the code independently before integrating it into their own systems.

**Español:**  
Este proyecto fue desarrollado con asistencia de herramientas de inteligencia artificial. Dada la naturaleza automatizada de algunos componentes, se recomienda que los usuarios revisen y prueben el código independientemente antes de integrarlo en sus propios sistemas.

## Requirements
- Debian 11/12 or Ubuntu 20.04/22.04/24.04
- Root privileges (`sudo`)
- `yq` — `sudo apt install yq`
- `flock` (util-linux) — `sudo apt install util-linux`
- `timeout`, `base64` (coreutils) — `sudo apt install coreutils`
- SSH keys for remote servers (recommended)

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `THEFOXUP_DRY_RUN` | `0` | Show what would be updated, then exit |
| `THEFOXUP_PROMPT_CONFIRM` | `1` | Enable confirmation prompts before reboot/shutdown (non-interactive) |
| `THEFOXUP_LOCK` | `/var/run/thefoxup.lock` | Override lock file path |
| `THEFOXUP_SSH_CONNECT_TIMEOUT` | `10` | SSH connect timeout in seconds |
| `THEFOXUP_SSH_ALIVE_INTERVAL` | `30` | SSH keepalive interval in seconds |
| `THEFOXUP_SSH_STRICT_HOST_KEY_CHECKING` | `accept-new` | SSH host key policy (`accept-new` trusts on first connection) |
| `THEFOXUP_APT_TIMEOUT` | `600` | Max time in seconds for remote apt operations |
| `THEFOXUP_REBOOT_DELAY` | `10` | Delay in seconds before reboot/shutdown |
| `THEFOXUP_MAX_PARALLEL` | `10` | Max concurrent remote SSH sessions |
| `THEFOXUP_LOG_CLEAN_DAYS` | `30` | Keep log files for N days |

## Quick Start

```bash
git clone https://github.com/Morphilab/thefoxup.git
cd thefoxup
chmod +x foxup.sh mode-*.sh update_functions.sh
cp servers.example.yaml servers.yaml
# Edit servers.yaml with your servers
sudo ./foxup.sh
```

## Usage

**Interactive mode (recommended):**
```bash
sudo ./foxup.sh
```

**Non-interactive (local or remote):**
```bash
sudo ./foxup.sh full              # Update + reboot (asks before rebooting)
sudo ./foxup.sh full --yes        # Update + reboot (no prompts)
sudo ./foxup.sh lite --dry-run    # Show what would be updated, then exit
sudo ./foxup.sh --check           # Read-only system status (no changes)
```

**Remote via SSH:**
```bash
ssh user@server "sudo /opt/thefoxup/foxup.sh full"
```

## Configuration (servers.yaml)

```yaml
# thefoxup - Remote servers configuration
servers:
  - user: admin
    host: 192.168.1.50
    path: /opt/thefoxup

  - user: deploy
    host: 10.0.0.25
    path: /home/deploy/thefoxup
```

## Available Modes

| Mode   | Description                        | After update             |
|--------|------------------------------------|--------------------------|
| `lite` | Update packages only               | No action                |
| `full` | Update packages                    | Reboot (10s)             |
| `off`  | Update packages                    | Shutdown (10s)           |

## Security Notes
- Use SSH keys (no passwords)
- Remote user needs passwordless sudo for `apt`, `reboot` and `poweroff`
- `servers.yaml` is ignored by git
- See [SECURITY.md](SECURITY.md) for details

## License
MIT © morphilab

---
