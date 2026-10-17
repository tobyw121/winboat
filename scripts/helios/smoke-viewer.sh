#!/usr/bin/env bash
# Protocol/software-frame validation. No KVM, render node or physical GPU used.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
[[ $(id -u) != 0 ]] || { echo 'Run the viewer smoke test as a desktop user, not root.' >&2; exit 2; }
export BUILDX_CONFIG=${BUILDX_CONFIG:-${TMPDIR:-/tmp}/winboat-buildx-$(id -u)}
image=winboat/viewer-toolchain:local
auth_debug=()
if [[ ${WINBOAT_VIEWER_DEBUG_AUTH:-0} == 1 ]]; then auth_debug=(-e G_DBUS_DEBUG=authentication); fi
docker image inspect "$image" >/dev/null
host_image=$(node --input-type=module -e 'import {HELIOS_IMAGE} from "./src/shared/helios.ts"; console.log(HELIOS_IMAGE)')
temporary=$(mktemp -d /tmp/winboat-viewer-test.XXXXXX)
client="winboat-viewer-test-${RANDOM}-client"
qemu="winboat-viewer-test-${RANDOM}-qemu"
cleanup() {
    status=$?
    if ((status)); then docker logs "$client" 2>/dev/null || true; docker logs "$qemu" 2>/dev/null || true; fi
    docker rm -f "$qemu" "$client" >/dev/null 2>&1 || true
    rm -rf -- "$temporary"
    exit "$status"
}
trap cleanup EXIT
node --input-type=module - "$temporary/bus.conf" "$(id -u)" <<'JS'
import fs from 'node:fs';
import {heliosDisplayBusConfig} from './src/shared/helios-display.ts';
fs.writeFileSync(process.argv[2],heliosDisplayBusConfig('/test',Number(process.argv[3])));
JS
docker run -d --name "$client" --user "$(id -u):$(id -g)" --pid=host --network none "${auth_debug[@]}" \
    -v "$root:/source:ro" -v "$temporary:/test" "$image" bash -c '
    set -e
    dbus-daemon --config-file=/test/bus.conf --fork
    Xvfb :99 -screen 0 1024x768x24 -nolisten tcp -ac >/test/xvfb.log 2>&1 &
    exec tail -f /dev/null' >/dev/null
for ((i=0;i<100;i++)); do [[ -S "$temporary/bus" ]] && break; sleep 0.1; done
[[ -S "$temporary/bus" ]]
docker exec "$client" bash /source/native/helios-viewer/build.sh /test/viewer
docker exec "$client" bash /source/tests/helios-viewer-render.sh /test/viewer
docker exec -e DISPLAY=:99 -e GDK_BACKEND=x11 -e LIBGL_ALWAYS_SOFTWARE=1 -e GTK_A11Y=none \
    "$client" /test/viewer --check-gl
if docker exec -e DISPLAY=:65534 -e GDK_BACKEND=x11 -e GTK_A11Y=none "$client" /test/viewer --check-gl; then
    echo 'The GL preflight unexpectedly accepted an unavailable desktop.' >&2; exit 1
fi
docker exec "$client" python3 /source/native/helios-viewer/test-auth.py
docker run -d --name "$qemu" --network none "${auth_debug[@]}" -v "$temporary:/test:ro" \
    --entrypoint qemu-system-x86_64 "$host_image" -machine q35,accel=tcg -m 128M \
    -nodefaults -device virtio-vga -display dbus,addr=unix:path=/test/bus >/dev/null
for ((i=0;i<100;i++)); do
    if docker exec "$client" dbus-send --bus=unix:path=/test/bus --print-reply \
        --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames | grep -q '"org.qemu"'; then break; fi
    sleep 0.1
done
# The desktop client must not be able to impersonate root QEMU on this bus.
if claim=$(docker exec "$client" dbus-send --bus=unix:path=/test/bus --print-reply \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.RequestName \
    string:org.qemu uint32:0 2>&1); then
    echo 'The private bus unexpectedly allowed the desktop client to own org.qemu.' >&2; exit 1
fi
[[ "$claim" == *AccessDenied* ]]
# EXTERNAL auth must work from a desktop UID to root QEMU's delegated listener.
docker exec -e DISPLAY=:99 -e GDK_BACKEND=x11 -e LIBGL_ALWAYS_SOFTWARE=1 \
    -e GTK_A11Y=none -e XDG_CACHE_HOME=/test/cache -e TMPDIR=/test "$client" \
    /test/viewer --smoke-test unix:path=/test/bus
docker exec -i "$client" python3 - <<'PY'
from pathlib import Path
magic, dimensions, maximum, pixels = Path('/test/helios-viewer-smoke.ppm').read_bytes().split(b'\n', 3)
width, height = map(int, dimensions.split())
assert magic == b'P6' and maximum == b'255'
assert len(pixels) == width * height * 3
assert pixels != pixels[:3] * (width * height), 'The rendered BIOS frame is uniform.'
print(f'Captured a non-uniform {width}x{height} software frame.')
PY
mkdir -p "$root/dist"
cp "$temporary/helios-viewer-smoke.ppm" "$temporary/helios-viewer-smoke.png" "$root/dist/"
printf '%s\n' 'Private bus, cross-UID listener FD handoff and rendered software frames passed. Physical DMA-BUF/GPU tests remain separate.'
