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
#include "adapter_selection.h"
struct Luid { int value; };
struct Instance {
    int devices[2] = {1, 2}; int count = 1;
    int* findAdapterByLuid(Luid* id) { return id->value == 1 && count ? &devices[0] : nullptr; }
    int* enumAdapters(unsigned index) { return index < unsigned(count) ? &devices[index] : nullptr; }
};
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
    Instance instance; Luid expected{1}, missing{9};
    assert(select_helios_adapter(instance, &expected) == &instance.devices[0]);
    assert(select_helios_adapter(instance, &missing) == nullptr);
    assert(select_helios_adapter(instance, static_cast<Luid*>(nullptr)) == &instance.devices[0]);
    instance.count = 2;
    assert(select_helios_adapter(instance, &expected) == &instance.devices[0]);
    assert(select_helios_adapter(instance, static_cast<Luid*>(nullptr)) == nullptr);
    instance.count = 0;
    assert(select_helios_adapter(instance, static_cast<Luid*>(nullptr)) == nullptr);
}
''')
    executable = temp / 'selector'
    subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(UPSTREAM / 'metadata'), '-I' + str(UPSTREAM / 'umd/bridge'),
                    str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
assert 'select_helios_adapter(*d.instance, has_luid ? &luid : nullptr)' in bridge
print('Production DXVK selector: branded filter, exact LUID, unique legacy fallback, ambiguity/missing rejection passed.')
