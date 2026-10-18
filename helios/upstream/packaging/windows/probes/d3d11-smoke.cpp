#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <cstdio>
#include <cwchar>
#include <cstring>
#include "d3d11-render-checks.h"

// Exercise real resource creation, GPU clear, copy and CPU readback as well as
// loading the architecture-matched UMD. Odd dimensions exercise RowPitch.
static bool check_readback(ID3D11Device *device, ID3D11DeviceContext *context) {
    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = 31;
    desc.Height = 17;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *target = nullptr;
    ID3D11Texture2D *staging = nullptr;
    ID3D11RenderTargetView *view = nullptr;
    HRESULT hr = device->CreateTexture2D(&desc, nullptr, &target);
    if (SUCCEEDED(hr)) hr = device->CreateRenderTargetView(target, nullptr, &view);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (SUCCEEDED(hr)) hr = device->CreateTexture2D(&desc, nullptr, &staging);
    bool valid = false;
    if (SUCCEEDED(hr)) {
        const FLOAT red[4] = {1.0f, 0.0f, 0.0f, 1.0f};
        context->ClearRenderTargetView(view, red);
        context->CopyResource(staging, target);
        D3D11_MAPPED_SUBRESOURCE mapped = {};
        hr = context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(hr)) {
            valid = mapped.pData && mapped.RowPitch >= desc.Width * 4;
            if (!valid) std::fprintf(stderr, "D3D11 Map returned an invalid pointer or row pitch.\n");
            for (UINT y = 0; valid && y < desc.Height; ++y) {
                const auto *row = static_cast<const unsigned char *>(mapped.pData) + y * mapped.RowPitch;
                for (UINT x = 0; x < desc.Width; ++x) {
                    const auto *pixel = row + x * 4;
                    if (pixel[0] != 0 || pixel[1] != 0 || pixel[2] != 255 || pixel[3] != 255) {
                        std::fprintf(stderr, "D3D11 readback mismatch at (%u,%u): %02x %02x %02x %02x.\n",
                                     x, y, pixel[0], pixel[1], pixel[2], pixel[3]);
                        valid = false;
                        break;
                    }
                }
            }
            context->Unmap(staging, 0);
        }
    }
    if (FAILED(hr)) std::fprintf(stderr, "D3D11 clear/readback failed: 0x%08lx.\n", static_cast<unsigned long>(hr));
    if (view) view->Release();
    if (staging) staging->Release();
    if (target) target->Release();
    if (valid) std::printf("Direct3D 11 clear/copy/readback: all 527 pixels match.\n");
    return valid;
}

static bool check_msaa(ID3D11Device *device, ID3D11DeviceContext *context) {
    const DXGI_FORMAT formats[] = { DXGI_FORMAT_B8G8R8A8_UNORM,
        DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT, DXGI_FORMAT_D32_FLOAT };
    const UINT counts[] = { 0, 1, 2, 3, 4, 8, 16, 32, 33 };
    for (auto format : formats) for (auto samples : counts) {
        UINT quality = 0;
        HRESULT hr = device->CheckMultisampleQualityLevels(format, samples, &quality);
        const bool legal = samples > 0 && samples <= 32 && (samples & (samples - 1)) == 0;
        if (!legal) {
            if (SUCCEEDED(hr) && quality != 0) return false;
            continue;
        }
        if (FAILED(hr)) return false;
        std::printf("MSAA format=%u samples=%u quality=%u\n", format, samples, quality);
        if (!quality) continue;
        D3D11_TEXTURE2D_DESC desc = {};
        desc.Width = desc.Height = 16; desc.MipLevels = desc.ArraySize = 1;
        desc.Format = format; desc.SampleDesc.Count = samples;
        desc.SampleDesc.Quality = quality - 1;
        desc.BindFlags = format == DXGI_FORMAT_D32_FLOAT ? D3D11_BIND_DEPTH_STENCIL : D3D11_BIND_RENDER_TARGET;
        ID3D11Texture2D *texture = nullptr;
        hr = device->CreateTexture2D(&desc, nullptr, &texture);
        const bool resolveOk = SUCCEEDED(hr) && texture && format == DXGI_FORMAT_B8G8R8A8_UNORM && samples > 1
            ? check_msaa_resolve(device, context, texture, desc) : true;
        if (texture) texture->Release();
        if (!resolveOk) return false;
        if (FAILED(hr)) {
            std::fprintf(stderr, "Advertised MSAA texture rejected: fmt=%u count=%u quality=%u hr=0x%08lx\n",
                format, samples, quality - 1, static_cast<unsigned long>(hr));
            return false;
        }
    }
    return true;
}

int wmain(int argc, wchar_t **argv) {
    const bool warp = argc == 2 && std::wcscmp(argv[1], L"--warp") == 0;
    std::printf("Adapter mode: %s\n", warp ? "WARP software control" : "Helios hardware required");
    std::printf("Direct3D 11 smoke: %zu-bit process.\n", sizeof(void *) * 8);
    IDXGIFactory1 *factory = nullptr;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void **>(&factory));
    if (FAILED(hr)) {
        std::fprintf(stderr, "CreateDXGIFactory1 failed: 0x%08lx\n", static_cast<unsigned long>(hr));
        return 1;
    }
    IDXGIAdapter1 *helios = nullptr;
    for (UINT index = 0; !warp; ++index) {
        IDXGIAdapter1 *adapter = nullptr;
        hr = factory->EnumAdapters1(index, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr) || !adapter) {
            std::fprintf(stderr, "EnumAdapters1 failed: 0x%08lx\n", static_cast<unsigned long>(hr));
            factory->Release();
            return 2;
        }
        DXGI_ADAPTER_DESC1 description = {};
        hr = adapter->GetDesc1(&description);
        if (FAILED(hr)) {
            std::fprintf(stderr, "GetDesc1 failed: 0x%08lx\n", static_cast<unsigned long>(hr));
            adapter->Release();
            factory->Release();
            return 2;
        }
        std::wprintf(L"DXGI adapter %u: %ls\n", index, description.Description);
        if (std::wcsstr(description.Description, L"Helios")) {
            helios = adapter;
            break;
        }
        adapter->Release();
    }
    if (!helios && !warp) {
        factory->Release();
        std::fprintf(stderr, "Helios DXGI adapter was not found.\n");
        return 2;
    }
    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_9_1;
    const D3D_FEATURE_LEVEL requested[] = {D3D_FEATURE_LEVEL_11_0};
    hr = D3D11CreateDevice(helios, warp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, requested, 1,
                           D3D11_SDK_VERSION, &device, &level, &context);
    if (FAILED(hr) || !device || !context || level < D3D_FEATURE_LEVEL_11_0) {
        if (context) context->Release();
        if (device) device->Release();
        std::fprintf(stderr, "D3D11CreateDevice on Helios failed: 0x%08lx\n", static_cast<unsigned long>(hr));
        if (helios) helios->Release();
        factory->Release();
        return 3;
    }
    std::printf("Direct3D 11 device created on selected adapter; feature level 0x%x.\n", level);
    const bool readbackOk = check_readback(device, context);
    const bool msaaOk = check_msaa(device, context);
    const bool computeOk = check_compute(device, context);
    const bool drawOk = check_depth_draw(device, context);
    context->ClearState();
    context->Release();
    device->Release();
    if (helios) helios->Release();
    factory->Release();
    return readbackOk && msaaOk && computeOk && drawOk ? 0 : 4;
}
