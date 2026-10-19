#!/bin/sh
# Use the paired renderer even when the container has a distro renderer too.
export LD_LIBRARY_PATH=/opt/helios/renderer/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# virglrenderer reads this exact name; its compiled-in prefix is a build path.
export RENDER_SERVER_EXEC_PATH=/opt/helios/renderer/libexec/virgl_render_server
if [ "${HELIOS_GPU_VENDOR:-}" = nvidia ] && [ "${HELIOS_RESCUE:-0}" != 1 ]; then
    if [ -z "${VK_DRIVER_FILES:-}" ]; then
        for driver in /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json; do
            if [ -r "$driver" ]; then export VK_DRIVER_FILES="$driver"; break; fi
        done
    fi
    if [ -z "${VK_DRIVER_FILES:-}" ]; then
        echo 'NVIDIA Vulkan ICD missing: check NVIDIA Container Toolkit graphics injection.' >&2
        exit 1
    fi
    if [ -r /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]; then
        export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
    fi
fi
exec python3 /opt/helios/performance.py /opt/helios/qemu/bin/qemu-system-x86_64 "$@"
