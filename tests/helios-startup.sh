#!/usr/bin/env bash
# Run inside the built image with a null character-device render-node fixture.
# Exercises the real dockur consumers without downloading Windows or using a GPU.
set -Eeuo pipefail
unset DISPLAY
APP=Windows
RENDERNODE=/dev/dri/renderD128
RAM_SIZE=128M
VNC_PORT=5900
WSS_PORT=5700
MON_PORT=7100
WEB_PORT=8006
temporary=$(mktemp -d)
trap 'if [[ -f "$temporary/nginx.pid" ]]; then kill "$(cat "$temporary/nginx.pid")"; fi; rm -rf "$temporary"' EXIT
STORAGE="$temporary/storage"
mkdir -p "$STORAGE"
source /run/utils.sh
source /run/display.sh
[[ "$DISPLAY_OPTS" == *'-device VGA,id=helios-bootstrap -device virtio-gpu-gl-pci'* ]]
# A ready marker only belongs to a confirmed, matching Helios installation.
printf '%s\n' "$HELIOS_REVISION" > "$STORAGE/.winboat-helios-ready"
source /run/display.sh
[[ "$DISPLAY_OPTS" != *'VGA,id=helios-bootstrap'* ]]
printf 'stale-revision\n' > "$STORAGE/.winboat-helios-ready"
source /run/display.sh
[[ "$DISPLAY_OPTS" == *'VGA,id=helios-bootstrap'* ]]
rm "$STORAGE/.winboat-helios-ready"
printf '%s\n' "$HELIOS_REVISION" > "$temporary/external-marker"
ln -s "$temporary/external-marker" "$STORAGE/.winboat-helios-ready"
source /run/display.sh
[[ "$DISPLAY_OPTS" == *'VGA,id=helios-bootstrap'* ]]
HELIOS_BOOTSTRAP_DISPLAY=0
source /run/display.sh
[[ "$DISPLAY_OPTS" != *'VGA,id=helios-bootstrap'* ]]
if (HELIOS_BOOTSTRAP_DISPLAY=invalid; source /run/display.sh) 2>/dev/null; then exit 1; fi
rm "$STORAGE/.winboat-helios-ready"
HELIOS_BOOTSTRAP_DISPLAY=auto
source /run/display.sh

# NAT must reserve the console's ports instead of forwarding them to Windows.
NETWORK=N
source /run/network.sh
[[ "$(getHostPorts 7149)" == '7149,5700,5900,7100,8006' ]]

INFO="$temporary/msg.html"
PAGE="$temporary/index.html"
TEMPLATE=/var/www/index.html
FOOTER1='Helios startup test'
FOOTER2=''
html 'Preparing Windows...'
cat > "$temporary/nginx.conf" <<NGINX
pid $temporary/nginx.pid;
error_log stderr;
events {}
http {
    access_log off;
    server { listen 127.0.0.1:8006; root $temporary; log_not_found off; }
}
NGINX
chmod 755 "$temporary"
nginx -c "$temporary/nginx.conf"
[[ "$(curl --noproxy 127.0.0.1 --silent --show-error --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8006/msg.html)" == 200 ]]

# Supply the CPU/boot outputs of earlier startup stages, then run config.sh.
DEBUG=N
CPU_CORES=2
CPU_FLAGS=qemu64
MACHINE=q35
SECURE=off
KVM_OPTS=''
SM_BIOS=''
BOOT_MODE=windows
PROCESS=windows
RAM_CHECK=N
DISK_OPTS=''
BOOT_OPTS=''
ARGUMENTS='-qmp tcp:0.0.0.0:7149,server,wait=off'
source /run/config.sh
[[ "$ARGS" == *'venus=on,blob=on'* ]]
[[ "$ARGS" == *'memory-backend-memfd,id=helios-ram,size=128M,share=on'* ]]
[[ "$ARGS" == *"$ARGUMENTS"* ]]
# WinBoat detects completion when the web console removes msg.html (HTTP 404).
[[ ! -e "$INFO" && ! -e "$PAGE" ]]
[[ "$(curl --noproxy 127.0.0.1 --silent --show-error --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8006/msg.html)" == 404 ]]
printf '%s\n' "$DISPLAY_OPTS"
