#!/usr/bin/env bash
# Hook only the preparation of a new ISO, before dockur builds and boots it.
set -Eeuo pipefail
[[ "${WINBOAT_ATLAS_ISO:-}" == 1 ]] || { echo 'Missing Atlas ISO marker.' >&2; exit 1; }
command -v wimlib-imagex >/dev/null
if ! grep -q '^# WinBoat Atlas ISO injection$' /run/install.sh; then
    content=$(</run/install.sh)
    anchor='if ! removeImage "$ISO"; then'
    [[ "$content" == *"$anchor"* ]] || { echo 'Unsupported dockur ISO preparation script.' >&2; exit 1; }
    replacement=$'# WinBoat Atlas ISO injection\n. /oem/.winboat-atlas/inject.sh "$DIR"\n\n'
    replacement+="$anchor"
    printf '%s\n' "${content/"$anchor"/"$replacement"}" > /run/install.sh
fi
if [[ "${WINBOAT_HARDWARE_PROFILE:-}" == 1 ]]; then
    exec /bin/bash /oem/.winboat-hardware/entry.sh "$@"
fi
exec /run/entry.sh "$@"
