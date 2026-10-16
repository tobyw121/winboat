#!/usr/bin/env bash
# Preserve dockur's init/shutdown handling and install a post-boot config hook.
set -Eeuo pipefail
[[ "${WINBOAT_HARDWARE_PROFILE:-}" == 1 ]] || { echo 'Missing WinBoat hardware profile marker.' >&2; exit 1; }
original=/run/winboat-config-original.sh
if [[ ! -e "$original" ]]; then cp -p /run/config.sh "$original"; fi
[[ -f "$original" && ! -L "$original" ]] || { echo 'Invalid original QEMU configuration script.' >&2; exit 1; }
install -m 755 /oem/.winboat-hardware/config.sh /run/config.sh
exec /run/entry.sh "$@"
