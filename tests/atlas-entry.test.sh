#!/usr/bin/env bash
# Run only in a disposable dockur/Helios container; replaces /run/entry.sh there.
set -Eeuo pipefail
[[ -f /run/install.sh && -f /run/entry.sh ]] || exit 1
PYTHONPATH="/oem/.winboat-atlas:${PYTHONPATH:-}" python3 - <<'PY'
import shutil
import tempfile
from pathlib import Path
import xml.etree.ElementTree as ET
from inject import amend_answer, NS
with tempfile.TemporaryDirectory() as temporary:
    for mode in [False, True]:
        target = Path(temporary) / 'unattend.xml'
        shutil.copyfile('/run/assets/win11x64.xml', target)
        amend_answer(target, '6', mode)
        root = ET.parse(target).getroot()
        assert root.findtext(f'.//{{{NS}}}InstallFrom/{{{NS}}}MetaData/{{{NS}}}Value') == '6'
        assert (root.find(f'.//{{{NS}}}UserAccounts') is None) == mode
print('Actual dockur Windows 11 answer file accepts both Atlas modes.')
PY
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
