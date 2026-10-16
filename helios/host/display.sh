#!/usr/bin/env bash
# Sourced by dockur's start sequence; do not activate its Intel-only GPU path.
set -Eeuo pipefail
: "${HELIOS:?Helios image requires HELIOS=1}"
: "${HELIOS_REVISION:?Missing paired Helios source revision}"
: "${RENDERNODE:=/dev/dri/renderD128}"
[[ "$HELIOS" == 1 ]] || { echo 'Use the standard Windows image when Helios is disabled.' >&2; exit 1; }
[[ "$RENDERNODE" =~ ^/dev/dri/renderD[0-9]+$ ]] || { echo 'Invalid DRM render node.' >&2; exit 1; }
[[ -c "$RENDERNODE" && -r "$RENDERNODE" && -w "$RENDERNODE" ]] || { echo "Helios cannot access $RENDERNODE" >&2; exit 1; }
# Headless EGL creates the host rendering context; VNC/WebSocket carries the
# Helios scanout. No extra standard VGA adapter or full GPU passthrough.
DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE -vga none"
DISPLAY_OPTS+=" -device virtio-gpu-gl-pci,id=heliosgpu,venus=on,blob=on,hostmem=8G,max_hostmem=8G"
DISPLAY_OPTS+=" -vnc :$((VNC_PORT - 5900)),websocket=$WSS_PORT"

# Match Helios's shared guest-memory contract. The ordinary dockur -m value is
# preserved; a second -machine option merges in the memfd backend property.
helios_ram="${RAM_SIZE:-4G}"
helios_ram="${helios_ram^^}"
helios_ram="${helios_ram//GB/G}"
helios_ram="${helios_ram//MB/M}"
helios_ram="${helios_ram//TB/T}"
[[ "$helios_ram" =~ ^[0-9]+([.][0-9]+)?[MGT]$ ]] || { echo 'Invalid Helios RAM_SIZE.' >&2; exit 1; }
DISPLAY_OPTS+=" -object memory-backend-memfd,id=helios-ram,size=$helios_ram,share=on -machine memory-backend=helios-ram"
