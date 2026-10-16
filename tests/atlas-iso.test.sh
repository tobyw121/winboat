#!/usr/bin/env bash
# Real wimlib I/O with synthetic Windows metadata; no Windows installation media.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/tree/sources" "$fixture/root/Windows/System32" "$fixture/media"
printf 'fixture' > "$fixture/root/Windows/System32/original.txt"
printf '{"release":"0.5.0-hotfix","mode":"iso"}\n' > "$fixture/media/atlas.json"
printf 'synthetic binary fixture' > "$fixture/media/CLI-Standalone.zip"
printf 'synthetic playbook fixture' > "$fixture/media/AtlasPlaybook.apbx"
wim="$fixture/tree/sources/install.wim"
wimlib-imagex capture "$fixture/root" "$wim" 'Windows 11 Home' --compress=LZX >/dev/null
wimlib-imagex append "$fixture/root" "$wim" 'Windows 11 Pro' >/dev/null
wimlib-imagex info "$wim" 1 --image-property=WINDOWS/EDITIONID=Core --image-property=WINDOWS/ARCH=9 --image-property=WINDOWS/VERSION/BUILD=26200 >/dev/null
wimlib-imagex info "$wim" 2 --image-property=WINDOWS/EDITIONID=Professional --image-property=WINDOWS/ARCH=9 --image-property=WINDOWS/VERSION/BUILD=26200 >/dev/null
bash "$repo/resources/atlas-tools/inject.sh" "$fixture/tree" "$fixture/media"
mkdir "$fixture/extracted"
wimlib-imagex extract "$wim" 2 /ProgramData/WinBoat/AtlasMedia --dest-dir="$fixture/extracted" >/dev/null
cmp "$fixture/media/atlas.json" "$fixture/extracted/AtlasMedia/atlas.json"
cmp "$fixture/media/CLI-Standalone.zip" "$fixture/extracted/AtlasMedia/CLI-Standalone.zip"
if wimlib-imagex extract "$wim" 1 /ProgramData/WinBoat/AtlasMedia --to-stdout >/dev/null 2>&1; then
    echo 'Home edition was modified unexpectedly.' >&2; exit 1
fi
wimlib-imagex extract "$wim" 2 /Windows/System32/original.txt --to-stdout | cmp - "$fixture/root/Windows/System32/original.txt"
bash "$repo/resources/atlas-tools/inject.sh" "$fixture/tree" "$fixture/media"
wimlib-imagex export "$wim" all "$fixture/tree/sources/install.esd" --compress=LZMS --solid >/dev/null
rm "$wim"
bash "$repo/resources/atlas-tools/inject.sh" "$fixture/tree" "$fixture/media"
test -s "$wim"
test ! -e "$fixture/tree/sources/install.esd"
wimlib-imagex info "$wim" 2 --image-property=WINDOWS/VERSION/BUILD=22000 >/dev/null
if bash "$repo/resources/atlas-tools/inject.sh" "$fixture/tree" "$fixture/media"; then
    echo 'Unsupported Windows build was accepted.' >&2; exit 1
fi
echo 'Atlas WIM injection, edition isolation, persistence, ESD conversion and build rejection passed.'
