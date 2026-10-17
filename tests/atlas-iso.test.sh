#!/usr/bin/env bash
# Requires wimtools and python3-hivex, supplied by the build/Atlas images.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$repo/tests/atlas-oobe-handoff.test.py"
python3 "$repo/tests/atlas-iso.test.py"
