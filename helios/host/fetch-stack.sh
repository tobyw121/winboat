#!/usr/bin/env bash
set -euo pipefail
revision=d82ce565ac792eb48da5e59f2a82a12ff221851d
mkdir -p /build/helios
cd /build/helios
git init .
git remote add origin https://github.com/winboat-org/helios.git
git fetch --depth 1 origin "$revision"
git checkout --detach FETCH_HEAD
[[ "$(git rev-parse HEAD)" == "$revision" ]]
git submodule update --init --depth 1 venus-protocol virglrenderer icd/mesa qemu-helios
# QEMU's pinned build-time subprojects; firmware is provided by the dockur base.
git -C qemu-helios submodule update --init --depth 1
