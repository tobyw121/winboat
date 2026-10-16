#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
output=${1:-$root/build/native/winboat-helios-viewer}
mkdir -p "$(dirname -- "$output")"
cc -std=c11 -O2 -Wall -Wextra -Werror "$root/native/helios-viewer/viewer.c" \
  $(pkg-config --cflags --libs gtk4 gio-unix-2.0 epoxy) -lm -o "$output"
"$output" --self-test
