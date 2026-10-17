#!/usr/bin/env bash
# Sourced by dockur's start sequence; do not activate its Intel-only GPU path.
set -Eeuo pipefail
: "${HELIOS:?Helios image requires HELIOS=1}"
: "${HELIOS_REVISION:?Missing paired Helios source revision}"
: "${RENDERNODE:=/dev/dri/renderD128}"
[[ "$HELIOS" == 1 ]] || { echo 'Use the standard Windows image when Helios is disabled.' >&2; exit 1; }
[[ "$RENDERNODE" =~ ^/dev/dri/renderD[0-9]+$ ]] || { echo 'Invalid DRM render node.' >&2; exit 1; }
[[ -c "$RENDERNODE" && -r "$RENDERNODE" && -w "$RENDERNODE" ]] || { echo "Helios cannot access $RENDERNODE" >&2; exit 1; }
# dockur's network/config stages use DISPLAY independently of QEMU's backend:
# reserve the console ports and remove msg.html when preinstallation finishes.
# Keep dockur's HTTP status/installation endpoint active in both modes.
DISPLAY=web
# Headless EGL creates the host rendering context; VNC/WebSocket carries the
# Helios scanout. A bootstrap VGA supplies Windows Setup/AME's initial display.
case "${HELIOS_DISPLAY:-novnc}" in
    novnc) DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE -vga none" ;;
    dbus)
        [[ -S /run/helios-display/bus ]] || { echo 'Start the private Helios display bus before this VM.' >&2; exit 1; }
        DISPLAY_OPTS="-display dbus,addr=unix:path=/run/helios-display/bus,gl=on,rendernode=$RENDERNODE -vga none"
        ;;
    *) echo 'Invalid HELIOS_DISPLAY mode.' >&2; exit 1 ;;
esac
# The upstream launcher also supplies VGA for installation, before Windows has
# the Helios driver. Create it first so VNC and the GTK viewer's Console_0 show it.
: "${HELIOS_BOOTSTRAP_DISPLAY:=auto}"
bootstrap="$HELIOS_BOOTSTRAP_DISPLAY"
if [[ "$bootstrap" == auto ]]; then
    bootstrap=1
    ready="${STORAGE:-/storage}/.winboat-helios-ready"
    # Local Desktop keeps a VGA recovery console after driver installation.
    if [[ "${HELIOS_DISPLAY:-novnc}" != dbus && -f "$ready" && ! -L "$ready" && "$(stat -c%s "$ready")" == 41 && "$(cat "$ready")" == "$HELIOS_REVISION" ]]; then
        bootstrap=0
    fi
fi
case "$bootstrap" in
    1|yes)
        DISPLAY_OPTS+=' -device VGA,id=helios-bootstrap'
        echo 'Helios: bootstrap VGA enabled for Windows Setup/AME; Helios GPU remains attached.' ;;
    0|no) ;;
    *) echo 'Invalid HELIOS_BOOTSTRAP_DISPLAY (use auto, 1/yes or 0/no).' >&2; exit 1 ;;
esac
DISPLAY_OPTS+=" -device virtio-gpu-gl-pci,id=heliosgpu,venus=on,blob=on,hostmem=8G,max_hostmem=8G"
# The D-Bus GL context only accepts D-Bus listeners. Registering VNC against
# it aborts QEMU at startup. EGL-headless supplies the 2D readback VNC needs.
if [[ "${HELIOS_DISPLAY:-novnc}" == novnc ]]; then
    DISPLAY_OPTS+=" -vnc :$((VNC_PORT - 5900)),websocket=$WSS_PORT"
fi

# Match Helios's shared guest-memory contract. The ordinary dockur -m value is
# preserved; a second -machine option merges in the memfd backend property.
helios_ram="${RAM_SIZE:-4G}"
helios_ram="${helios_ram^^}"
helios_ram="${helios_ram//GB/G}"
helios_ram="${helios_ram//MB/M}"
helios_ram="${helios_ram//TB/T}"
[[ "$helios_ram" =~ ^[0-9]+([.][0-9]+)?[MGT]$ ]] || { echo 'Invalid Helios RAM_SIZE.' >&2; exit 1; }
DISPLAY_OPTS+=" -object memory-backend-memfd,id=helios-ram,size=$helios_ram,share=on -machine memory-backend=helios-ram"
