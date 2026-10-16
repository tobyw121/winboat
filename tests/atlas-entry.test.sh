#!/usr/bin/env bash
# Run only in a disposable dockur/Helios container; replaces /run/entry.sh there.
set -Eeuo pipefail
[[ -f /run/install.sh && -f /run/entry.sh ]] || exit 1
cat > /run/entry.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
test "$(grep -c '^# WinBoat Atlas ISO injection$' /run/install.sh)" = 1
injection=$(grep -n '^# WinBoat Atlas ISO injection$' /run/install.sh | cut -d: -f1)
removal=$(grep -n '^if ! removeImage' /run/install.sh | cut -d: -f1)
test "$injection" -lt "$removal"
if [[ "${WINBOAT_HARDWARE_PROFILE:-}" == 1 ]]; then
    test -f /run/winboat-config-original.sh
    cmp /run/config.sh /oem/.winboat-hardware/config.sh
fi
SH
chmod +x /run/entry.sh
export WINBOAT_ATLAS_ISO=1
for pass in 1 2; do bash /oem/.winboat-atlas/entry.sh; done
export WINBOAT_HARDWARE_PROFILE=1
for pass in 1 2; do bash /oem/.winboat-atlas/entry.sh; done
echo 'Actual dockur entry hook, injection ordering, hardware hook chaining and repeated starts passed.'
