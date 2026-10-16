#!/usr/bin/env bash
# Sourced after dockur's boot.sh, which overwrites its internal SM_BIOS value.
set -Eeuo pipefail
[[ "${WINBOAT_HARDWARE_PROFILE:-}" == 1 ]] || { echo 'Missing WinBoat hardware profile marker.' >&2; exit 1; }
SM_BIOS=''
for file in system.bin baseboard.bin chassis.bin; do
    path="/storage/.winboat-hardware/$file"
    [[ -f "$path" && -r "$path" ]] || { echo "Missing saved VM SMBIOS file: $file" >&2; exit 1; }
    SM_BIOS+=" -smbios file=$path"
done
source /run/winboat-config-original.sh
