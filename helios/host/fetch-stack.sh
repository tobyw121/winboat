#!/usr/bin/env bash
set -euo pipefail
# Helios itself is copied from this repository, not cloned from a moving branch.
python3 /build/verify-source.py /build/source
mkdir -p /build/helios
cp -a /build/source/upstream/. /build/helios/
python3 - <<'PY' > /build/host-dependencies.tsv
import json
source = json.load(open('/build/source/source.lock.json'))
for dep in source['submodules']:
    if dep['path'] in ('venus-protocol', 'virglrenderer', 'icd/mesa', 'qemu-helios'):
        print(dep['path'], dep['url'], dep['revision'], sep='\t')
PY
while IFS=$'\t' read -r directory url revision; do
    destination="/build/helios/$directory"
    mkdir -p "$destination"
    if [[ ! -d "$destination/.git" ]]; then
        git -C "$destination" init
        git -C "$destination" remote add origin "$url"
    fi
    git -C "$destination" fetch --depth 1 origin "$revision"
    git -C "$destination" checkout --force --detach FETCH_HEAD
    [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]]
done < /build/host-dependencies.tsv
# QEMU's pinned build-time subprojects; firmware is provided by the dockur base.
git -C /build/helios/qemu-helios submodule update --init --depth 1
(cd /build/patches && sha256sum -c SHA256SUMS)
git -C /build/helios/qemu-helios apply --check /build/patches/0001-dbus-listener-authenticated-owner.patch
git -C /build/helios/qemu-helios apply /build/patches/0001-dbus-listener-authenticated-owner.patch
