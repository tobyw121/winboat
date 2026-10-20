#!/usr/bin/env bash
set -euo pipefail
revision=d82ce565ac792eb48da5e59f2a82a12ff221851d
jobs=${HELIOS_BUILD_JOBS:-4}
cd /build/helios
[[ "$(python3 -c 'import json; print(json.load(open("/build/source/source.lock.json"))["revision"])')" == "$revision" ]]
HELIOS_BUILD_JOBS="$jobs" bash tools/build-native-renderer.sh
mkdir -p /opt/helios/renderer
cp -a target/linux/virglrenderer-install/. /opt/helios/renderer/
export PKG_CONFIG_PATH=/build/helios/target/linux/venus-protocol-install/lib/pkgconfig:/opt/helios/renderer/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
export LD_LIBRARY_PATH=/opt/helios/renderer/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
mkdir -p qemu-helios/build-helios
cd qemu-helios/build-helios
../configure --prefix=/opt/helios/qemu --target-list=x86_64-softmmu \
  --enable-kvm --enable-opengl --enable-virglrenderer --enable-vnc \
  --disable-gtk --disable-sdl --disable-docs --disable-werror
ninja -j "$jobs"
ninja install
/opt/helios/qemu/bin/qemu-system-x86_64 --version
/opt/helios/qemu/bin/qemu-system-x86_64 -device virtio-gpu-gl-pci,help | grep 'venus'
printf '%s\n' "$revision" > /opt/helios/revision
# A runtime-only rebuild must not relabel an older QEMU as a newer capability.
cp /build/patches/SHA256SUMS /opt/helios/host-patches.sha256

cc -std=c11 -O2 -Wall -Wextra -Werror /context/helios/host/gpu-preflight.c -lvulkan -o /opt/helios/gpu-preflight

cp /context/helios/host/renderer-patches/SHA256SUMS /opt/helios/renderer-patches.sha256
sha256sum /context/helios/host/vram-budget.h | cut -d' ' -f1 > /opt/helios/vram-budget.sha256

sha256sum /context/helios/host/vram-refs.h | cut -d' ' -f1 > /opt/helios/vram-refs.sha256
