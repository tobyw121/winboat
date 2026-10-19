#!/usr/bin/env python3
"""Execute the production C++ shader-create template and exception guard.

Only the COM device, bytecode wrapping and log I/O are fixtures. This does not
load DXVK, Helios or a GPU; Windows builds check the native COM/CXX interfaces.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'helios/upstream/umd/bridge/dxvk_bridge.cpp').read_text()
# Check all CXX declarations too: the native helper test alone cannot detect a
# missing/duplicated Rust-side HRESULT output parameter at the FFI boundary.
rust = (root / 'helios/upstream/umd/src/bridge.rs').read_text()
header = (root / 'helios/upstream/umd/bridge/dxvk_bridge.h').read_text()
for kind in ('vertex', 'pixel', 'geometry', 'hull', 'domain', 'compute', 'sig', 'tess_sig'):
    name = ('create_shader_sig' if kind == 'sig' else
            'create_tess_shader_sig' if kind == 'tess_sig' else f'create_{kind}_shader')
    declaration = re.search(r'unsafe fn ' + name + r'\((.*?)\) -> usize;', rust, re.S)
    assert declaration, name
    params = [p.strip() for p in declaration[1].split(',') if p.strip()]
    assert len(params) == len(set(p.split(':')[0] for p in params)), name
    assert params[-1] == 'out_hr: *mut i32', name
    native = re.search(r'std::size_t ' + name + r'\((.*?)\) const;', header, re.S)
    assert native and native[1].count(',') + 1 == len(params) - 1, name
    assert native[1].strip().endswith('std::int32_t* out_hr'), name

start = source.index('  template <typename Iface, typename Create>')
end = source.index('{', start) + 1
depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
template = source[start:end]
guard = (root / 'helios/upstream/umd_common/bridge/bridge_guard.h').read_text()
guard = guard.replace('#include "bridge_common.h"', '// fixture log sink')
prefix = r'''
#include <cassert>
#include <cstdint>
#include <initializer_list>
#include <new>
using HRESULT = std::int32_t;
constexpr HRESULT E_FAIL = std::int32_t(0x80004005u);
constexpr HRESULT E_INVALIDARG = std::int32_t(0x80070057u);
constexpr HRESULT E_OUTOFMEMORY = std::int32_t(0x8007000eu);
#define FAILED(hr) ((hr) < 0)
namespace helios_bridge { static void umd_log(const char*) {} }
#include "guard.h"
namespace helios_bridge {
struct FakeDevice {};
struct FakeShader {};
struct HeliosDxvkDeviceImpl { FakeDevice* d3d11; };
static bool wrap_valid = true;
struct Bytecode {
    const void* data() const { return this; }
    std::size_t len() const { return 4; }
    explicit operator bool() const { return wrap_valid; }
};
static Bytecode prepare_shader_bytecode(const std::uint8_t*, std::size_t) { return {}; }
static void dump_shader_bytecode(const char*, const char*, const void*, std::size_t) {}
'''
tests = r'''
static int run_tests() {
    FakeDevice device; FakeShader shader;
    HeliosDxvkDeviceImpl impl{&device};
    std::uint8_t code[4]{}; std::int32_t hr = 0;
    auto create = [&](HRESULT result) {
        return create_shader_impl<FakeShader>(&impl, "vs", "test", code, sizeof(code),
            [&](FakeDevice*, const void*, std::size_t, FakeShader** out) -> HRESULT {
                *out = FAILED(result) ? nullptr : &shader; return result;
            }, &hr);
    };
    for (HRESULT failure : {E_INVALIDARG, E_OUTOFMEMORY, std::int32_t(0x887a0005u)}) {
        assert(create(failure) == 0); assert(hr == failure);
    }
    assert(create(0) == reinterpret_cast<std::size_t>(&shader)); assert(hr == 0);
    wrap_valid = false;
    assert(create(0) == 0); assert(hr == E_INVALIDARG);
    wrap_valid = true;
    auto throwing = [](FakeDevice*, const void*, std::size_t, FakeShader**) -> HRESULT { throw std::bad_alloc(); };
    assert(create_shader_impl<FakeShader>(&impl, "vs", "exception", code, sizeof(code), throwing, &hr) == 0);
    assert(hr == E_FAIL); // exception has no backend HRESULT; never invent OOM
    assert(create_shader_impl<FakeShader>(nullptr, "vs", "null", code, sizeof(code), throwing, &hr) == 0);
    assert(hr == E_INVALIDARG);
    return 0;
}
}
int main() { return helios_bridge::run_tests(); }
'''
with tempfile.TemporaryDirectory(prefix='helios-shader-result-') as directory:
    folder = Path(directory)
    (folder / 'guard.h').write_text(guard)
    (folder / 'test.cpp').write_text(prefix + template + tests)
    binary = folder / 'test'
    subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-Wno-comment', str(folder / 'test.cpp'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('Production C++ shader create/guard: backend HRESULTs, pointer width, invalid input and exception fallback passed.')
