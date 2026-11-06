# TheFoxUp

[English](README.md) · **Español**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-1.1.1-blue.svg)](https://github.com/Morphilab/thefoxup/releases/tag/v1.1.1)
[![ShellCheck](https://github.com/Morphilab/thefoxup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/Morphilab/thefoxup/actions/workflows/shellcheck.yml)
[![Bash](https://img.shields.io/badge/bash-5%2B-green.svg)](https://www.gnu.org/software/bash/)

**Actualizador seguro y sencillo para servidores Debian/Ubuntu**

Herramienta Bash ligera y segura, con colores, configuración YAML y soporte remoto por SSH.


## Características
- Tres modos: `lite` (solo actualización), `full` (actualización + reinicio), `off` (actualización + apagado)
- Salida con colores mediante `tput`
- Configuración YAML moderna (`servers.yaml`)
- Ejecución local y remota (varios servidores por SSH)
- Seguridad ante todo: lockfile, comprobación de root y SSH seguro
- Limpieza automática de paquetes
- Validado con ShellCheck

## ⚠️ Divulgación de IA

Este proyecto fue desarrollado con asistencia de herramientas de inteligencia artificial. Dada la naturaleza automatizada de algunos componentes, se recomienda que los usuarios revisen y prueben el código de forma independiente antes de integrarlo en sus propios sistemas.

## Requisitos
- Debian 11/12 o Ubuntu 20.04/22.04/24.04 (la CI se ejecuta en `ubuntu-latest`)
- Privilegios de root (`sudo`)
- `yq` (v3+) — `sudo apt install yq` (tanto el paquete apt como el [binario Go](https://github.com/mikefarah/yq/releases) funcionan con la sintaxis utilizada)
- `flock` (util-linux) — `sudo apt install util-linux`
- `timeout`, `base64` (coreutils) — `sudo apt install coreutils`
- `fuser` (psmisc) — `sudo apt install psmisc` (recomendado: sin él se omiten la comprobación previa de locks de apt/dpkg y la limpieza de locks tras un stall)
- Claves SSH para los servidores remotos (recomendado)

## Variables de entorno

| Variable | Valor por defecto | Descripción |
|----------|-------------------|-------------|
| `THEFOXUP_DRY_RUN` | `0` | Muestra qué se actualizaría (refresca la caché de paquetes) y sale |
| `THEFOXUP_PROMPT_CONFIRM` | `1` | Activa la confirmación antes de reiniciar/apagar (modo no interactivo) |
| `THEFOXUP_LOCK` | `/var/run/thefoxup.lock` | Ruta alternativa del archivo de lock |
| `THEFOXUP_SSH_CONNECT_TIMEOUT` | `10` | Timeout de conexión SSH en segundos |
| `THEFOXUP_SSH_ALIVE_INTERVAL` | `30` | Intervalo de keepalive SSH en segundos |
| `THEFOXUP_SSH_STRICT_HOST_KEY_CHECKING` | `accept-new` | Política de host keys SSH (`accept-new` confía en la primera conexión) |
| `THEFOXUP_APT_TIMEOUT` | `600` | Tiempo máximo en segundos por cada comando apt (local y remoto; debe ser >= 1) |
| `THEFOXUP_APT_KILL_AFTER` | `30` | Segundos de gracia entre SIGTERM y SIGKILL para un comando apt colgado y para los lock holders residuales de apt/dpkg tras un stall (debe ser >= 1) |
| `THEFOXUP_HEARTBEAT_INTERVAL` | `30` | Intervalo del heartbeat durante comandos apt largos (`0` lo desactiva) |
| `THEFOXUP_REMOTE_SESSION_TIMEOUT` | `1800` | Tiempo máximo total en segundos para una sesión remota completa (debe ser >= 1) |
| `THEFOXUP_REBOOT_DELAY` | `10` | Retardo en segundos antes de reiniciar/apagar |
| `THEFOXUP_MAX_PARALLEL` | `10` | Máximo de sesiones SSH remotas concurrentes (debe ser >= 1) |
| `THEFOXUP_LOG_DIR` | `/var/log/thefoxup` | Directorio donde se escriben los logs |
| `THEFOXUP_LOG_CLEAN_DAYS` | `30` | Días de retención de los logs |

## Inicio rápido

```bash
git clone https://github.com/Morphilab/thefoxup.git
cd thefoxup
chmod +x foxup.sh mode.sh mode-*.sh update_functions.sh remote_functions.sh
cp servers.example.yaml servers.yaml
# Edita servers.yaml con tus servidores
sudo ./foxup.sh
```

## Uso

**Modo interactivo (recomendado):**
```bash
sudo ./foxup.sh
```

**No interactivo (local o remoto):**
```bash
sudo ./foxup.sh full              # Actualiza + reinicia (pregunta antes de reiniciar)
sudo ./foxup.sh full --yes        # Actualiza + reinicia (sin confirmaciones)
sudo ./foxup.sh lite --dry-run    # Muestra qué se actualizaría y sale
sudo ./foxup.sh --check           # Estado del sistema en solo lectura (sin cambios)
```

**Remoto por SSH:**
```bash
# Confirmación interactiva del reinicio (necesita TTY para sudo)
ssh -t user@server "sudo /opt/thefoxup/foxup.sh full"

# No interactivo: omite la confirmación de reinicio/apagado
ssh user@server "sudo /opt/thefoxup/foxup.sh full --yes"
```

## Configuración (servers.yaml)

```yaml
# thefoxup - Configuración de servidores remotos
servers:
  - user: admin
    host: 192.168.1.50
    path: /opt/thefoxup

  - user: deploy
    host: 10.0.0.25
    path: /home/deploy/thefoxup
```

## Modos disponibles

| Modo   | Descripción                        | Después de actualizar     |
|--------|------------------------------------|---------------------------|
| `lite` | Solo actualiza paquetes            | Ninguna acción            |
| `full` | Actualiza paquetes                 | Reinicio (10 s)           |
| `off`  | Actualiza paquetes                 | Apagado (10 s)            |

## Manejo de stalls

Cada comando apt (y la llamada `apt-mark` del kernel) está acotado por
`THEFOXUP_APT_TIMEOUT` y se escala a SIGKILL cuando ignora SIGTERM
(`THEFOXUP_APT_KILL_AFTER`); su salida se lee mediante un lector acotado, de
modo que un proceso hijo superviviente no puede bloquear la ejecución. Un
comando detenido así aborta la actualización (sin reinicio) y deja una captura
forense en el log.

Lo que todavía tenga los locks de apt/dpkg en ese momento recibe primero
SIGTERM y solo se fuerza si lo ignora. Ten en cuenta que esto también puede
alcanzar a una ejecución concurrente de apt/dpkg iniciada por otra herramienta
(por ejemplo, `unattended-upgrades`): se le pide que se detenga, aborta de forma
limpia y libera los locks por sí misma, y los PIDs objetivo quedan registrados
en el log.

## Notas de seguridad
- Usa claves SSH (sin contraseñas)
- El usuario remoto necesita sudo sin contraseña para `apt`, `reboot` y `poweroff`
- `servers.yaml` está ignorado por git
- Consulta [SECURITY.md](SECURITY.md) para más detalles

## Licencia
MIT © morphilab

---
