#!/usr/bin/env python3
"""Run the production Mesa chain helper; arguments: patched Mesa root, Vulkan include."""
import os
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
mesa, headers = map(pathlib.Path, sys.argv[1:])
with tempfile.TemporaryDirectory(prefix='helios-feature-test-') as directory:
    temp = pathlib.Path(directory)
    # Only the allocator and generated size lookup are replaced by C fixtures.
    for name in ('vk_alloc.h', 'vk_enum_to_str.h'):
        (temp / name).write_text('/* Implemented by the test fixture. */\n')
    exe = temp / ('test.exe' if os.name == 'nt' else 'test')
    subprocess.run(['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(headers), '-I' + str(temp),
                    '-I' + str(mesa / 'src/virtio/vulkan'),
                    str(root / 'tests/helios-device-features.c'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)

# Compile and execute the generated rejection path, including the Windows-only
# GUI log sink. The platform/process shim exercises file IO, not Windows APIs.
import ast
from mako.template import Template
module = ast.parse((mesa / 'src/vulkan/util/vk_physical_device_features_gen.py').read_text())
assignment = next(n for n in module.body if isinstance(n, ast.Assign) and
                  any(isinstance(t, ast.Name) and t.id == 'TEMPLATE_C' for t in n.targets))
template = assignment.value.args[0].right.value
rendered = Template(template).render(filename='test', pdev_features=['robustBufferAccess'],
                                    feature_structs=[], all_flags=['robustBufferAccess'])
start = rendered.index('/* Keep the rejected field')
end = rendered.index('VkResult\nvk_physical_device_check_device_features')
with tempfile.TemporaryDirectory(prefix='helios-feature-log-') as directory:
    temp = pathlib.Path(directory)
    (temp / 'process.h').write_text('static int _getpid(void) { return 17; }\n')
    prefix = '''#include <vulkan/vulkan.h>
#include <assert.h>
#include <stdarg.h>
#include <string.h>
#ifndef _WIN32
#define _WIN32
#endif
#define HELIOS_PRODUCT_NAME "Helios vGPU"
struct vk_physical_device { int unused; };
#define VK_LOG_OBJS(x) x
static void vk_loge(void *obj, const char *fmt, ...) { (void)obj; (void)fmt; }
#define vk_errorf(obj,result,...) (result)
'''
    main = '''
int main(void) {
    struct vk_physical_device device = {0};
    VkPhysicalDeviceFeatures supported = {0}, enabled = {0};
    assert(check_physical_device_features(&device, &supported, &enabled, "VkPhysicalDeviceFeatures") == VK_SUCCESS);
    enabled.robustBufferAccess = VK_TRUE;
    assert(check_physical_device_features(&device, &supported, &enabled, "VkPhysicalDeviceFeatures") == VK_ERROR_FEATURE_NOT_PRESENT);
    supported.robustBufferAccess = VK_TRUE;
    assert(check_physical_device_features(&device, &supported, &enabled, "VkPhysicalDeviceFeatures") == VK_SUCCESS);
    return 0;
}
'''
    source = temp / 'generated.c'
    source.write_text(prefix + rendered[start:end] + main)
    exe = temp / ('generated.exe' if os.name == 'nt' else 'generated')
    subprocess.run(['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(headers), '-I' + str(temp), str(source), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], env={**os.environ, 'LOCALAPPDATA': str(temp)}, check=True)
    assert (temp / 'helios-vulkan-features.log').read_text() == \
        'pid=17 VkPhysicalDeviceFeatures.robustBufferAccess not supported\n'
    print('Generated feature validation preserves -8 and records the exact rejected field.')
