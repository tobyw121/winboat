#!/usr/bin/env bash
set -euo pipefail

# Every path below is already a Windows path. Without this, MSYS2's argument
# converter rewrites the embedded `-includeD:/...` compiler argument into the
# invalid `-includeD:A:/...` form before Meson sees it.
export MSYS2_ARG_CONV_EXCL='*'

repo_root="$(cygpath -m "${1:?usage: build-mesa.sh REPO_ROOT OUTPUT_DIR [BUILD_DIR] [--clean|--reuse]}")"
output_dir="$(cygpath -m "${2:?usage: build-mesa.sh REPO_ROOT OUTPUT_DIR [BUILD_DIR] [--clean|--reuse]}")"
build_dir="$(cygpath -m "${3:-C:/helios-mesa-build}")"
build_mode="${4:---clean}"

mesa_src="${repo_root}/icd/mesa"
native_file="${repo_root}/ci/windows/mingw-native.ini"
compat_header="${repo_root}/icd/win-build/helios_win_compat.h"

python "${repo_root}/tools/sync-metadata.py" --check

# Apply WinBoat's reviewed changes to the immutable dependency pin in the
# separate build tree. A reused tree is accepted only if the patch is present.
for patch in "${repo_root}"/ci/patches/mesa/*.patch; do
  if git -C "${mesa_src}" apply --check "${patch}"; then
    git -C "${mesa_src}" apply "${patch}"
  elif ! git -C "${mesa_src}" apply --reverse --check "${patch}"; then
    printf 'Mesa patch does not match the pinned source: %s\n' "${patch}" >&2
    exit 1
  fi
done
if [[ -n "${WINBOAT_ROOT:-}" ]]; then
  python "${WINBOAT_ROOT}/tests/helios-device-features.py" "${mesa_src}" "${mesa_src}/include"
fi

setup_mode=()
case "${build_mode}" in
  --clean)
    rm -rf "${build_dir}"
    ;;
  --reuse)
    if [[ -f "${build_dir}/build.ninja" ]]; then
      setup_mode+=(--reconfigure)
    fi
    ;;
  *)
    printf 'Unknown build mode: %s (expected --clean or --reuse)\n' "${build_mode}" >&2
    exit 2
    ;;
esac
mkdir -p "${output_dir}"

meson setup "${setup_mode[@]}" "${build_dir}" "${mesa_src}" \
  --native-file "${native_file}" \
  "-Dc_args=-include${compat_header}" \
  -Dvulkan-drivers=virtio \
  -Dgallium-drivers=zink \
  "-Dhelios-wdk-include=${repo_root}/icd/win-build/wdk-include" \
  -Dplatforms=windows \
  -Dvideo-codecs= \
  -Dvulkan-layers= \
  -Degl=disabled \
  -Dgbm=disabled \
  -Dglx=disabled \
  -Dopengl=true \
  -Dgles1=disabled \
  -Dgles2=disabled \
  -Dllvm=disabled \
  -Dshader-cache=disabled \
  -Dzlib=disabled \
  -Dzstd=disabled \
  -Dbuild-tests=false \
  -Dperfetto=false \
  -Dxmlconfig=disabled \
  -Ddebug=true \
  --buildtype=release

meson compile -C "${build_dir}"

cp "${build_dir}/src/virtio/vulkan/vulkan_virtio.dll" "${output_dir}/"
cp "${build_dir}/src/gallium/targets/wgl/libgallium_wgl.dll" "${output_dir}/"
cp "${build_dir}/src/gallium/targets/libgl-gdi/opengl32.dll" "${output_dir}/opengl32-app-local.dll"

# Keep matching DWARF separately; release DLLs retain no bulky debug sections.
mkdir -p "${output_dir}/symbols"
for dll in "${output_dir}/vulkan_virtio.dll" "${output_dir}/libgallium_wgl.dll"; do
  debug="${output_dir}/symbols/$(basename "${dll}").debug"
  objcopy --only-keep-debug "${dll}" "${debug}"
  objcopy --strip-debug --add-gnu-debuglink="${debug}" "${dll}"
done
python - "${output_dir}" <<'PYMETA'
import hashlib,json,pathlib,struct,sys
root=pathlib.Path(sys.argv[1]);rows=[]
for name in ('vulkan_virtio.dll','libgallium_wgl.dll'):
    dll=(root/name).read_bytes();debug=(root/'symbols'/(name+'.debug')).read_bytes()
    pe=struct.unpack_from('<I',dll,0x3c)[0];optional=pe+24
    magic=struct.unpack_from('<H',dll,optional)[0]
    if dll[:2]!=b'MZ' or dll[pe:pe+4]!=b'PE\0\0' or magic not in (0x10b,0x20b):raise ValueError('Expected a Windows PE image')
    base=struct.unpack_from('<Q' if magic==0x20b else '<I',dll,optional+(24 if magic==0x20b else 28))[0]
    rows.append(dict(module=name,sha256=hashlib.sha256(dll).hexdigest(),debug=name+'.debug',debugSha256=hashlib.sha256(debug).hexdigest(),imageBase=base))
(root/'symbols/symbols.json').write_text(json.dumps(dict(schema=1,modules=rows),indent=2),encoding='utf-8')
PYMETA

# WGL ICD dependencies are resolved by opengl32.dll and do not reliably search
# the private driver directory. Keep the Mesa ICDs self-contained instead of
# silently shipping a MinGW DLL that the Windows loader will not find.
for dll in "${output_dir}/vulkan_virtio.dll" "${output_dir}/libgallium_wgl.dll"; do
  while read -r dependency; do
    case "${dependency,,}" in
      lib*.dll|zlib1.dll)
        printf 'Unexpected non-system dependency in %s: %s\n' "${dll}" "${dependency}" >&2
        exit 1
        ;;
    esac
  done < <(objdump -p "${dll}" | sed -n 's/^[[:space:]]*DLL Name: //p')
done

mkdir -p "${output_dir}/licenses/mesa"
cp -R "${mesa_src}/licenses/." "${output_dir}/licenses/mesa/"

{
  for dll in "${output_dir}"/*.dll; do
    echo "=== $(basename "${dll}") ==="
    objdump -p "${dll}" | sed -n 's/^[[:space:]]*DLL Name: /DLL Name: /p'
  done
} > "${output_dir}/imports.txt"

printf 'Mesa artifact staged at %s\n' "${output_dir}"
