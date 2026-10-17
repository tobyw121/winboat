#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
cc -std=c11 -O2 -Wall -Wextra -Werror "$root/tests/helios-viewer-render.c" \
  $(pkg-config --cflags --libs gtk4 gio-unix-2.0 epoxy) -lm -o "$temporary/render-test"
env -u GDK_DEBUG GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 GTK_A11Y=none \
  xvfb-run -a "$temporary/render-test"
viewer=${1:-$temporary/viewer}
if [[ $# == 0 ]]; then bash "$root/native/helios-viewer/build.sh" "$viewer"; fi
env -u GDK_DEBUG GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 GTK_A11Y=none \
  xvfb-run -a python3 "$root/tests/helios-viewer-consoles.py" "$viewer"
