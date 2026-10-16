#!/usr/bin/env bash
set -Eeuo pipefail
python3 "$(dirname -- "${BASH_SOURCE[0]}")/inject.py" "$1" "${2:-/oem/atlas}"
