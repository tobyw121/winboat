#!/usr/bin/env bash
# Sourced by dockur. Unmanaged legacy configurations keep their original handler.
set -Eeuo pipefail
if [[ -z "${WINBOAT_SHARED_FOLDERS+x}" ]]; then
    source /run/samba-upstream.sh
    return 0
fi
[[ "${SAMBA:-Y}" == [Nn]* || "${NETWORK:-}" == [Nn]* ]] && return 0
if [[ "${DHCP:-N}" == [Yy1]* ]]; then
    share_address="$IP"
    share_interfaces="$VM_NET_DEV"
else
    share_network="${NETWORK:-bridge}"
    case "${share_network,,}" in
        passt|slirp) share_address=127.0.0.1; share_interfaces=lo ;;
        *) share_address=$(python3 /opt/winboat-shares/manage.py address "$VM_NET_BRIDGE"); share_interfaces="$VM_NET_BRIDGE" ;;
    esac
    if [[ -n "${SAMBA_INTERFACE:-}" ]]; then share_interfaces+=",$SAMBA_INTERFACE"; fi
fi
python3 /opt/winboat-shares/manage.py configure "$share_address" "$share_interfaces"
smbd -l /var/log/samba
# Discovery is optional; direct \\host.lan\Share paths do not depend on it.
if command -v wsddn >/dev/null; then
    wsddn -i "${share_interfaces%%,*}" -H host.lan --unixd --log-file=/var/log/wsddn.log --pid-file=/var/run/wsdd.pid || true
fi
return 0
