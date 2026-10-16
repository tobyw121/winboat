#!/usr/bin/env bash
# Build both components on the host Docker daemon. No Docker socket in builders.
set -euo pipefail
original_args=("$@")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
usage() {
    cat <<'HELP'
Usage: ./scripts/build-helios.sh [options]
  --installer-dir PATH  Use HeliosSetup.exe + helios-build.json from PATH.
                        Otherwise use the complete installer bundled in Git.
  --all-packages        Build AppImage, DEB, RPM and tar.gz (default: AppImage).
  --skip-host           Reuse a matching local Helios image; fail if missing.
  --export-host-image   Also save the host image as dist/winboat-helios-host-*.tar.gz.
  -h, --help            Show this help.

Requires Linux x86_64, Bash, Git, Docker Engine, Compose v2 and Buildx.
Every build first runs git pull --ff-only origin work on the work branch.
Set HELIOS_BUILD_JOBS to a positive integer (default 4).
Optional HELIOS_PROXY_CA: trusted CA bundle passed as a BuildKit secret.
HELP
}
die() { echo "Build error: $*" >&2; exit 1; }
targets=AppImage
skip_host=false
export_host=false
installer_dir=
while (($#)); do
    case "$1" in
        --installer-dir)
            (($# >= 2)) || die '--installer-dir requires a directory.'
            installer_dir=$(cd -- "$2" && pwd) || die 'Installer directory does not exist.'
            [[ -f "$installer_dir/HeliosSetup.exe" && -f "$installer_dir/helios-build.json" ]] || die 'Installer directory must contain both bundle files.'
            shift 2 ;;
        --all-packages) targets=all; shift ;;
        --skip-host) skip_host=true; shift ;;
        --export-host-image) export_host=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown argument: $1" ;;
    esac
done
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Only Linux x86_64 is supported.'
command -v git >/dev/null || die 'Install Git first; see docs/build-helios-local.md.'
[[ $(git branch --show-current) == work ]] || die 'Check out the work branch before building; no branch was changed automatically.'
previous_commit=$(git rev-parse HEAD)
echo 'Updating WinBoat: git pull --ff-only origin work'
git pull --ff-only origin work || die 'Update failed. Resolve the Git error before building; local changes were not stashed or reset.'
if [[ $(git rev-parse HEAD) != "$previous_commit" ]]; then
    # Run the updated build instructions as well as building the updated sources.
    exec bash "$root/scripts/build-helios.sh" "${original_args[@]}"
fi
command -v docker >/dev/null || die 'Install Docker first; see docs/build-helios-local.md.'
export BUILDX_CONFIG=${BUILDX_CONFIG:-${XDG_CACHE_HOME:-${TMPDIR:-/tmp}}/winboat-buildx-$(id -u)}
mkdir -p "$BUILDX_CONFIG"
docker info >/dev/null || die 'Docker Engine is not accessible to this user.'
docker compose version >/dev/null || die 'Install the Docker Compose v2 plugin.'
docker buildx version >/dev/null || die 'Install the Docker Buildx plugin.'
jobs=${HELIOS_BUILD_JOBS:-4}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die 'HELIOS_BUILD_JOBS must be a positive integer.'
revision=$(sed -n 's/.*"hostRevision": "\([a-f0-9]*\)".*/\1/p' helios/stack.lock.json)
[[ "$revision" =~ ^[a-f0-9]{40}$ ]] || die 'Invalid host revision in stack.lock.json.'
image="winboat/helios:${revision:0:12}"
build_args=(--platform linux/amd64 --progress plain)
ca=${HELIOS_PROXY_CA:-}
if [[ -z "$ca" && -n "${CODEX_PROXY_CERT:-}" ]]; then ca=/etc/ssl/certs/ca-certificates.crt; fi
if [[ -n "$ca" ]]; then
    [[ -r "$ca" ]] || die 'Cannot read the configured trusted CA bundle.'
    build_args+=(--secret "id=proxy_ca,src=$ca")
fi
mkdir -p dist
temporary=$(mktemp -d "$root/dist/.helios-build.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
if ! "$skip_host"; then
    docker buildx build "${build_args[@]}" --load -f helios/host/Dockerfile \
        --build-arg "HELIOS_BUILD_JOBS=$jobs" -t "$image" .
fi
actual=$(docker image inspect --format '{{ index .Config.Labels "org.winboat.helios.revision" }}' "$image") || die "Missing host image $image."
[[ "$actual" == "$revision" ]] || die 'The local Helios image has the wrong revision.'
display_version=$(sed -n "s/^export const HELIOS_DISPLAY_VERSION = '\([^']*\)';$/\1/p" src/shared/helios-display.ts)
[[ "$display_version" =~ ^dbus-v[0-9]+$ ]] || die 'Invalid local display capability.'
actual_display=$(docker image inspect --format '{{ index .Config.Labels "org.winboat.helios.display" }}' "$image")
[[ "$actual_display" == "$display_version" ]] || die 'The Helios image lacks the required local display protocol. Rebuild without --skip-host.'
docker run --rm --network none --entrypoint /opt/helios/check-runtime.sh "$image" \
    || die 'Helios OpenGL runtime is missing or incomplete. Rebuild the host image without --skip-host.'
# Exercise actual QEMU/memfd/QMP without pretending to test a GPU or Windows.
docker run --rm -i --entrypoint qemu-system-x86_64 "$image" \
    -machine q35,accel=tcg,memory-backend=helios-test \
    -object memory-backend-memfd,id=helios-test,size=128M,share=on \
    -m 128M -nodefaults -display none -S -qmp stdio > "$temporary/qmp.log" <<'QMP'
{"execute":"qmp_capabilities"}
{"execute":"query-memory-size-summary"}
{"execute":"quit"}
QMP
if grep -q '"error"' "$temporary/qmp.log" || ! grep -Eq '"base-memory"[[:space:]]*:[[:space:]]*134217728' "$temporary/qmp.log"; then
    cat "$temporary/qmp.log" >&2
    die 'Helios QMP/shared-memory smoke check failed.'
fi
commit=$(git rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then commit+=-dirty; fi
if [[ -n "$installer_dir" ]]; then build_args+=(--build-context "installer=$installer_dir"); fi
docker buildx build "${build_args[@]}" --target artifacts \
    --build-arg "WINBOAT_BUILD_COMMIT=$commit" --build-arg "PACKAGE_TARGETS=$targets" \
    --output "type=local,dest=$temporary/packages" -f Dockerfile .
if "$export_host"; then
    archive="winboat-helios-host-${revision:0:12}.tar.gz"
    docker save "$image" | gzip -6 > "$temporary/packages/$archive"
    (cd "$temporary/packages" && sha256sum -- "$archive" >> SHA256SUMS)
fi
(cd "$temporary/packages" && sha256sum -c SHA256SUMS)
cp -a --no-preserve=ownership "$temporary/packages/." "$root/dist/"
printf '\nBuild complete: %s/dist\nHelios host image: %s\n' "$root" "$image"
echo 'Start the AppImage on your Linux desktop and select Helios when creating the VM.'
echo 'Hardware/Windows validation is separate; see docs/build-helios-local.md.'
