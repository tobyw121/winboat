// SPDX-License-Identifier: MIT
#pragma once
#include <cstdio>
#include <cstring>
#include <d3dcompiler.h>
#include <wrl/client.h>
using Microsoft::WRL::ComPtr;
#define GPU_CHECK(call) do { HRESULT result = (call); if (FAILED(result)) { \
    std::fprintf(stderr, "GPU probe line %d: %s -> 0x%08lx\n", __LINE__, #call, static_cast<unsigned long>(result)); return false; } } while (0)

static bool compile_shader(const char *source, const char *entry, const char *profile, ComPtr<ID3DBlob> &code) {
    ComPtr<ID3DBlob> errors;
    HRESULT hr = D3DCompile(source, std::strlen(source), "Helios probe", nullptr, nullptr,
        entry, profile, D3DCOMPILE_ENABLE_STRICTNESS, 0, code.GetAddressOf(), errors.GetAddressOf());
    if (FAILED(hr)) {
        if (errors) std::fprintf(stderr, "%s\n", static_cast<const char *>(errors->GetBufferPointer()));
        return false;
    }
    return true;
}
static bool check_compute(ID3D11Device *device, ID3D11DeviceContext *context) {
    context->ClearState();
    const char *source = "RWStructuredBuffer<uint> output : register(u0); [numthreads(64,1,1)] void main(uint3 id : SV_DispatchThreadID) { output[id.x] = id.x ^ 0x5a1234u; }";
    ComPtr<ID3DBlob> code; if (!compile_shader(source, "main", "cs_5_0", code)) return false;
    ComPtr<ID3D11ComputeShader> shader;
    GPU_CHECK(device->CreateComputeShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, shader.GetAddressOf()));
    D3D11_BUFFER_DESC desc = {}; desc.ByteWidth = 64 * sizeof(UINT);
    desc.BindFlags = D3D11_BIND_UNORDERED_ACCESS; desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
    desc.StructureByteStride = sizeof(UINT);
    ComPtr<ID3D11Buffer> output, staging;
    GPU_CHECK(device->CreateBuffer(&desc, nullptr, output.GetAddressOf()));
    D3D11_UNORDERED_ACCESS_VIEW_DESC uavDesc = {}; uavDesc.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;
    uavDesc.Buffer.NumElements = 64;
    ComPtr<ID3D11UnorderedAccessView> uav;
    GPU_CHECK(device->CreateUnorderedAccessView(output.Get(), &uavDesc, uav.GetAddressOf()));
    desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.BindFlags = desc.MiscFlags = desc.StructureByteStride = 0;
    GPU_CHECK(device->CreateBuffer(&desc, nullptr, staging.GetAddressOf()));
    context->CSSetShader(shader.Get(), nullptr, 0);
    ID3D11UnorderedAccessView *view = uav.Get();
    context->CSSetUnorderedAccessViews(0, 1, &view, nullptr);
    context->Dispatch(1, 1, 1);
    view = nullptr; context->CSSetUnorderedAccessViews(0, 1, &view, nullptr);
    context->CopyResource(staging.Get(), output.Get());
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    GPU_CHECK(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped));
    bool valid = mapped.pData != nullptr;
    const UINT *values = static_cast<const UINT *>(mapped.pData);
    for (UINT i = 0; valid && i < 64; ++i) valid = values[i] == (i ^ 0x5a1234u);
    context->Unmap(staging.Get(), 0);
    std::printf("Compute dispatch/UAV/readback: %s\n", valid ? "64 exact values match" : "FAILED");
    return valid;
}
static bool check_depth_draw(ID3D11Device *device, ID3D11DeviceContext *context) {
    context->ClearState();
    const char *source = R"(
cbuffer Constants : register(b0) { float4 color; float4 parameters; };
float4 vs(uint id : SV_VertexID) : SV_Position {
    float2 positions[3] = { float2(-1,-1), float2(-1,3), float2(3,-1) };
    return float4(positions[id], parameters.x, 1);
}
float4 ps() : SV_Target { return color; }
)";
    ComPtr<ID3DBlob> vsCode, psCode;
    if (!compile_shader(source, "vs", "vs_5_0", vsCode) || !compile_shader(source, "ps", "ps_5_0", psCode)) return false;
    ComPtr<ID3D11VertexShader> vs; ComPtr<ID3D11PixelShader> ps;
    GPU_CHECK(device->CreateVertexShader(vsCode->GetBufferPointer(), vsCode->GetBufferSize(), nullptr, vs.GetAddressOf()));
    GPU_CHECK(device->CreatePixelShader(psCode->GetBufferPointer(), psCode->GetBufferSize(), nullptr, ps.GetAddressOf()));
    D3D11_TEXTURE2D_DESC desc = {}; desc.Width = 31; desc.Height = 17;
    desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> target, depth, staging;
    GPU_CHECK(device->CreateTexture2D(&desc, nullptr, target.GetAddressOf()));
    ComPtr<ID3D11RenderTargetView> rtv;
    GPU_CHECK(device->CreateRenderTargetView(target.Get(), nullptr, rtv.GetAddressOf()));
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    GPU_CHECK(device->CreateTexture2D(&desc, nullptr, staging.GetAddressOf()));
    desc.Usage = D3D11_USAGE_DEFAULT; desc.CPUAccessFlags = 0;
    desc.Format = DXGI_FORMAT_D32_FLOAT; desc.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    GPU_CHECK(device->CreateTexture2D(&desc, nullptr, depth.GetAddressOf()));
    ComPtr<ID3D11DepthStencilView> dsv;
    GPU_CHECK(device->CreateDepthStencilView(depth.Get(), nullptr, dsv.GetAddressOf()));
    D3D11_BUFFER_DESC buffer = {}; buffer.ByteWidth = 8 * sizeof(float); buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    ComPtr<ID3D11Buffer> constants;
    GPU_CHECK(device->CreateBuffer(&buffer, nullptr, constants.GetAddressOf()));
    D3D11_RASTERIZER_DESC raster = {}; raster.FillMode = D3D11_FILL_SOLID; raster.CullMode = D3D11_CULL_NONE; raster.DepthClipEnable = TRUE;
    ComPtr<ID3D11RasterizerState> rasterState;
    GPU_CHECK(device->CreateRasterizerState(&raster, rasterState.GetAddressOf()));
    context->RSSetState(rasterState.Get());
    D3D11_VIEWPORT viewport = {}; viewport.Width = 31; viewport.Height = 17; viewport.MaxDepth = 1;
    context->RSSetViewports(1, &viewport);
    ID3D11RenderTargetView *view = rtv.Get(); context->OMSetRenderTargets(1, &view, dsv.Get());
    context->ClearDepthStencilView(dsv.Get(), D3D11_CLEAR_DEPTH, 1, 0);
    const FLOAT black[4] = {0,0,0,1}; context->ClearRenderTargetView(rtv.Get(), black);
    context->VSSetShader(vs.Get(), nullptr, 0); context->PSSetShader(ps.Get(), nullptr, 0);
    ID3D11Buffer *cb = constants.Get(); context->VSSetConstantBuffers(0, 1, &cb); context->PSSetConstantBuffers(0, 1, &cb);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    const float nearRed[8] = {1,0,0,1, .25f,0,0,0};
    const float farBlue[8] = {0,0,1,1, .75f,0,0,0};
    context->UpdateSubresource(cb, 0, nullptr, nearRed, 0, 0); context->Draw(3,0);
    context->UpdateSubresource(cb, 0, nullptr, farBlue, 0, 0); context->Draw(3,0);
    context->OMSetRenderTargets(0, nullptr, nullptr);
    context->CopyResource(staging.Get(), target.Get());
    D3D11_MAPPED_SUBRESOURCE mapped = {}; GPU_CHECK(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped));
    bool valid = mapped.pData && mapped.RowPitch >= 31 * 4;
    for (UINT y = 0; valid && y < 17; ++y) for (UINT x = 0; valid && x < 31; ++x) {
        const auto *p = static_cast<const unsigned char *>(mapped.pData) + y * mapped.RowPitch + x * 4;
        valid = p[0] == 255 && p[1] == 0 && p[2] == 0 && p[3] == 255;
    }
    context->Unmap(staging.Get(), 0);
    std::printf("Vertex/pixel shaders and depth rejection: %s\n", valid ? "527 exact pixels match" : "FAILED");
    return valid;
}
static bool check_msaa_resolve(ID3D11Device *device, ID3D11DeviceContext *context,
                               ID3D11Texture2D *source, D3D11_TEXTURE2D_DESC desc) {
    context->ClearState();
    const UINT samples = desc.SampleDesc.Count;
    ComPtr<ID3D11RenderTargetView> view;
    GPU_CHECK(device->CreateRenderTargetView(source, nullptr, view.GetAddressOf()));
    const FLOAT red[4] = {1,0,0,1}; context->ClearRenderTargetView(view.Get(), red);
    desc.SampleDesc.Count = 1; desc.SampleDesc.Quality = 0; desc.BindFlags = 0;
    ComPtr<ID3D11Texture2D> resolved, staging;
    GPU_CHECK(device->CreateTexture2D(&desc, nullptr, resolved.GetAddressOf()));
    desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    GPU_CHECK(device->CreateTexture2D(&desc, nullptr, staging.GetAddressOf()));
    context->ResolveSubresource(resolved.Get(), 0, source, 0, desc.Format);
    context->CopyResource(staging.Get(), resolved.Get());
    D3D11_MAPPED_SUBRESOURCE mapped = {}; GPU_CHECK(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped));
    bool valid = mapped.pData && mapped.RowPitch >= desc.Width * 4;
    for (UINT y = 0; valid && y < desc.Height; ++y) for (UINT x = 0; valid && x < desc.Width; ++x) {
        const auto *p = static_cast<const unsigned char *>(mapped.pData) + y * mapped.RowPitch + x * 4;
        valid = p[0] == 0 && p[1] == 0 && p[2] == 255 && p[3] == 255;
    }
    context->Unmap(staging.Get(), 0);
    std::printf("MSAA %ux clear/resolve/readback: %s\n", samples, valid ? "all exact pixels match" : "FAILED");
    return valid;
}
#undef GPU_CHECK
