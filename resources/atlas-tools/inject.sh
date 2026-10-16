#!/usr/bin/env bash
# Linux adaptation of AME's WIM payload staging. Standard Windows OOBE is retained.
# Run after dockur's unattended setup/OEM preparation and before buildImage.
set -Eeuo pipefail
atlas_inject() {
    local tree="$1" media="${2:-/oem/atlas}" sources image xml row index='' build
    sources=$(find "$tree" -maxdepth 1 -type d -iname sources -print -quit)
    [[ -n "$sources" ]] || { echo 'Atlas: ISO sources directory missing.' >&2; return 1; }
    image=$(find "$sources" -maxdepth 1 -type f -iname install.wim -print -quit)
    if [[ -z "$image" ]]; then
        image=$(find "$sources" -maxdepth 1 -type f -iname install.esd -print -quit)
    fi
    [[ -n "$image" ]] || { echo 'Atlas: install.wim/install.esd missing.' >&2; return 1; }
    xml=$(wimlib-imagex info "$image" --xml | iconv -f UTF-16LE -t UTF-8 | tr -d '\r\n')
    xml="${xml//<IMAGE INDEX=/$'\n'<IMAGE INDEX=}"
    while IFS= read -r row; do
        [[ "$row" == *'<EDITIONID>Professional</EDITIONID>'* ]] || continue
        [[ "$row" == *'<ARCH>9</ARCH>'* ]] || continue
        [[ "$row" =~ \<BUILD\>(26100|26200)\</BUILD\> ]] || continue
        build="${BASH_REMATCH[1]}"
        [[ "$row" =~ ^\<IMAGE\ INDEX=\"([0-9]+)\" ]] || continue
        index="${BASH_REMATCH[1]}"
        break
    done <<< "$xml"
    [[ -n "$index" ]] || { echo 'Atlas requires x64 Windows 11 Pro 24H2/25H2 (build 26100/26200).' >&2; return 1; }
    # ESD solid compression is read-only; convert before editing. Never replace on failure.
    if [[ "${image,,}" == *.esd ]]; then
        wimlib-imagex export "$image" all "$sources/install.wim.partial" --compress=LZX --check
        mv "$sources/install.wim.partial" "$sources/install.wim"
        rm -- "$image"
        image="$sources/install.wim"
    fi
    echo "Atlas: embedding pinned AME/Atlas media into Windows Pro WIM index $index (build $build)..."
    wimlib-imagex update "$image" "$index" --check --command "add \"$media\" /ProgramData/WinBoat/AtlasMedia"
    wimlib-imagex extract "$image" "$index" /ProgramData/WinBoat/AtlasMedia/atlas.json --to-stdout |
        cmp - "$media/atlas.json"
    # This marker describes media embedding, never a completed Atlas installation.
    printf '{"mode":"winboat-wim-payload","release":"0.5.0-hotfix","build":"%s","index":%s,"playbookApplied":false}\n' "$build" "$index" > "$tree/winboat-atlas-iso.json"
}
atlas_inject "$@"
