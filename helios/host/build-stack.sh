#!/usr/bin/env bash
set -euo pipefail
revision=d82ce565ac792eb48da5e59f2a82a12ff221851d
jobs=${HELIOS_BUILD_JOBS:-4}
cd /build/helios
[[ "$(git rev-parse HEAD)" == "$revision" ]]
HELIOS_BUILD_JOBS="$jobs" bash tools/build-native-renderer.sh
mkdir -p /opt/helios/renderer
cp -a target/linux/virglrenderer-install/. /opt/helios/renderer/
export PKG_CONFIG_PATH=/build/helios/target/linux/venus-protocol-install/lib/pkgconfig:/opt/helios/renderer/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
export LD_LIBRARY_PATH=/opt/helios/renderer/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
mkdir qemu-helios/build-helios
cd qemu-helios/build-helios
../configure --prefix=/opt/helios/qemu --target-list=x86_64-softmmu \
  --enable-kvm --enable-opengl --enable-virglrenderer --enable-vnc \
  --disable-gtk --disable-sdl --disable-docs --disable-werror
ninja -j "$jobs"
ninja install
/opt/helios/qemu/bin/qemu-system-x86_64 --version
/opt/helios/qemu/bin/qemu-system-x86_64 -device virtio-gpu-gl-pci,help | grep 'venus'
printf '%s\n' "$revision" > /opt/helios/revision
