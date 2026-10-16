#!/usr/bin/env bash
# Internal Docker build step; use scripts/build-helios.sh on your Linux host.
set -Eeuo pipefail
trap 'echo "Helios app build failed at line $LINENO: $BASH_COMMAND" >&2' ERR
case "${1:-AppImage}" in
    AppImage) targets=(AppImage) ;;
    all) targets=(AppImage deb rpm tar.gz) ;;
    *) echo 'Expected package target AppImage or all.' >&2; exit 2 ;;
esac
python3 scripts/helios/verify-source.py
npm run helios:stage -- resources/helios
npm run test:helios
npm run test:virgl
go test guest_server/helios_status.go guest_server/helios_status_test.go
npx vue-tsc --noEmit -p src/renderer --skipLibCheck
npm run build-guest-server
npm run build
mkdir -p build/native
cp /native-viewer/winboat-helios-viewer build/native/
ELECTRON_GET_USE_PROXY=1 npx electron-builder --linux "${targets[@]}" --x64 --publish never \
    --config.electronDist=node_modules/electron/dist
mkdir -p /out
find dist -maxdepth 1 -type f \( -name '*.AppImage' -o -name '*.deb' -o -name '*.rpm' -o -name '*.tar.gz' \) \
    -exec cp '{}' /out/ \;
cp resources/helios/HeliosSetup.exe resources/helios/helios-build.json /out/
cp docs/build-helios-local.md /out/BUILD-INSTRUCTIONS.md
cp docs/helios-local-display.md /out/LOCAL-DISPLAY.md
node --input-type=module - <<'JS' > /out/BUILD-INFO.json
import fs from 'node:fs';
import crypto from 'node:crypto';
import { HELIOS_DISPLAY_VERSION } from './src/shared/helios-display.ts';
const stack = JSON.parse(fs.readFileSync('helios/stack.lock.json', 'utf8'));
console.log(JSON.stringify({ winboatCommit: process.env.WINBOAT_BUILD_COMMIT,
    hostRevision: stack.hostRevision, guestRevision: stack.guestRevision,
    displayCapability: HELIOS_DISPLAY_VERSION,
    viewerSha256: crypto.createHash('sha256').update(fs.readFileSync('build/native/winboat-helios-viewer')).digest('hex'),
    hostPatchset: fs.readFileSync('helios/host/patches/SHA256SUMS', 'utf8').trim(),
    node: process.version, builtAt: new Date().toISOString() }, null, 2));
JS
(cd /out && sha256sum -- *.AppImage *.exe *.json *.md > SHA256SUMS)
# Include optional package formats without unmatched shell globs.
find /out -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' -o -name '*.tar.gz' \) -printf '%f\0' \
    | (cd /out && xargs -0 -r sha256sum --) >> /out/SHA256SUMS
