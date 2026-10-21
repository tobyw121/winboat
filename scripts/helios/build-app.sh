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
python3 tests/helios-build-update.test.py
npm run helios:stage -- resources/helios
npm run test:helios
npm run test:shared-folders
npm run test:virgl
npm run test:packaging
npm run test:atlas
npm run test:atlas:iso
(cd guest_server && go test ./...)
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
cp docs/helios-performance.md /out/helios-performance.md
cp docs/helios-control-and-validation.md /out/helios-control-and-validation.md
cp docs/helios-investigation.md /out/helios-investigation.md
cp docs/helios-deep-diagnostics.md /out/helios-deep-diagnostics.md
cp docs/helios-298-validation.md /out/helios-298-validation.md
cp docs/helios-299-cross-layer.md /out/helios-299-cross-layer.md
cp docs/helios-vram-budget.md /out/helios-vram-budget.md
cp docs/helios-301-stability.md /out/helios-301-stability.md
cp docs/helios-302-management.md /out/helios-302-management.md
cp docs/helios-evidence-and-recovery.md /out/helios-evidence-and-recovery.md
cp docs/shared-folders.md /out/SHARED-FOLDERS.md
cp docs/vm-hardware-profile.md /out/vm-hardware-profile.md
cp docs/atlas-installation.md /out/atlas-installation.md
node --input-type=module - <<'JS' > /out/BUILD-INFO.json
import fs from 'node:fs';
import crypto from 'node:crypto';
import { HELIOS_DISPLAY_VERSION } from './src/shared/helios-display.ts';
import { ATLAS_RELEASE, ATLAS_ASSETS, ATLAS_ISO_VERSION } from './src/shared/atlas.ts';
const stack = JSON.parse(fs.readFileSync('helios/stack.lock.json', 'utf8'));
console.log(JSON.stringify({ winboatCommit: process.env.WINBOAT_BUILD_COMMIT,
    hostRevision: stack.hostRevision, guestRevision: stack.guestRevision,
    displayCapability: HELIOS_DISPLAY_VERSION,
    atlasRelease: ATLAS_RELEASE, atlasPlaybookSha256: ATLAS_ASSETS[1].sha256,
    atlasIsoCapability: ATLAS_ISO_VERSION,
    viewerSha256: crypto.createHash('sha256').update(fs.readFileSync('build/native/winboat-helios-viewer')).digest('hex'),
    hostPatchset: fs.readFileSync('helios/host/patches/SHA256SUMS', 'utf8').trim(),
    rendererPatchset: fs.readFileSync('helios/host/renderer-patches/SHA256SUMS', 'utf8').trim(),
    vramReferencesSha256: crypto.createHash('sha256').update(fs.readFileSync('helios/host/vram-refs.h')).digest('hex'),
    vramPolicySha256: crypto.createHash('sha256').update(fs.readFileSync('helios/host/vram-budget.h')).digest('hex'),
    node: process.version, builtAt: new Date().toISOString() }, null, 2));
JS
(cd /out && sha256sum -- *.AppImage *.exe *.json *.md > SHA256SUMS)
# Include optional package formats without unmatched shell globs.
find /out -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' -o -name '*.tar.gz' \) -printf '%f\0' \
    | (cd /out && xargs -0 -r sha256sum --) >> /out/SHA256SUMS
