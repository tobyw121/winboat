#!/usr/bin/env python3
"""Execute the production DXVK selector against the Mesa device-name expression."""
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'helios/upstream'
bridge = (UPSTREAM / 'umd/bridge/dxvk_bridge.cpp').read_text()
patch = (UPSTREAM / 'ci/patches/mesa/0001-guest-device-features-and-branding.patch').read_text()
setter, = re.findall(r'^\s*(_putenv_s\("DXVK_FILTER_DEVICE_NAME", [^;]+;)', bridge, re.M)
mesa_name, = re.findall(r'^\+\s*(HELIOS_PRODUCT_NAME " \(%s\)", props->deviceName\);)', patch, re.M)
assert '#include "../../metadata/helios_branding.h"' in bridge

with tempfile.TemporaryDirectory(prefix='helios-selector-') as directory:
    temp = pathlib.Path(directory)
    source = temp / 'selector.cpp'
    source.write_text(r'''
#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include "helios_branding.h"
static std::string filter;
static int _putenv_s(const char* key, const char* value) {
    assert(std::strcmp(key, "DXVK_FILTER_DEVICE_NAME") == 0);
    filter = value;
    return 0;
}
int main() {
''' + setter + r'''
    assert(!filter.empty()); // An empty filter could select an unrelated ICD.
    const char* hosts[] = {"NVIDIA GeForce RTX 2070", "AMD Radeon", "Intel Arc"};
    for (const char* host : hosts) {
        struct Properties { const char* deviceName; } property = {host};
        const auto* props = &property;
        char device_name[256] = {};
        std::snprintf(device_name, sizeof(device_name),
''' + mesa_name + r'''
        assert(std::strstr(device_name, filter.c_str()) != nullptr);
    }
    assert(std::strstr("Unrelated Vulkan ICD", filter.c_str()) == nullptr);
}
''')
    executable = temp / 'selector'
    subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(UPSTREAM / 'metadata'), str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
print('Production DXVK selector matches the branded Mesa adapter; unrelated ICD excluded.')
