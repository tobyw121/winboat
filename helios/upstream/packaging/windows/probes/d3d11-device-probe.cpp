// Outer Windows runtime acceptance, distinct from the UMD's internal S_OK.
// No fallback to WARP unless --warp is explicitly selected for CI controls.
#include <windows.h>
#include <dxgi1_2.h>
#include <d3d11.h>
#include <cstdio>
#include <cstring>

int main(int argc, char** argv) {
    const bool warp = argc == 2 && !std::strcmp(argv[1], "--warp");
    if (argc != 1 && !warp) return 64;
    IDXGIFactory1* factory = nullptr;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory));
    if (FAILED(hr)) return 2;
    IDXGIAdapter1* selected = nullptr;
    if (!warp) {
        for (UINT i = 0; i < 32; ++i) {
            IDXGIAdapter1* adapter = nullptr;
            hr = factory->EnumAdapters1(i, &adapter);
            if (hr == DXGI_ERROR_NOT_FOUND) break;
            if (FAILED(hr)) { factory->Release(); return 2; }
            DXGI_ADAPTER_DESC1 desc{};
            hr = adapter->GetDesc1(&desc);
            if (SUCCEEDED(hr) && desc.VendorId == 0x1af4 && desc.DeviceId == 0x1050) {
                if (selected) { adapter->Release(); selected->Release(); factory->Release(); return 3; }
                selected = adapter;
            } else { adapter->Release(); }
        }
        if (!selected) { factory->Release(); return 4; }
    }
    int failures = 0;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0};
    const UINT flagsets[] = {0, D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_SINGLETHREADED};
    for (UINT flags : flagsets) {
        for (D3D_FEATURE_LEVEL level : levels) {
            ID3D11Device* device = nullptr;
            ID3D11DeviceContext* context = nullptr;
            D3D_FEATURE_LEVEL achieved{};
            hr = D3D11CreateDevice(selected, warp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_UNKNOWN,
                nullptr, flags, &level, 1, D3D11_SDK_VERSION, &device, &achieved, &context);
            // Decimal HRESULT retains all bits in JSON without signed ambiguity.
            std::printf("{\"schema\":1,\"warp\":%s,\"requested\":%u,\"achieved\":%u,\"flags\":%u,\"hr\":%u}\n",
                warp ? "true" : "false", static_cast<unsigned>(level), static_cast<unsigned>(achieved),
                flags, static_cast<unsigned>(hr));
            std::fflush(stdout);
            if (FAILED(hr) || !device || !context || achieved != level) ++failures;
            if (context) context->Release();
            if (device) device->Release();
        }
    }
    if (selected) selected->Release();
    factory->Release();
    return failures ? 1 : 0;
}
