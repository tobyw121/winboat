// Probe the outer Windows D3D11 contract. No silent software fallback.
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <initializer_list>
using Microsoft::WRL::ComPtr;
int main(int argc, char** argv) {
    const bool warp=argc==2 && !std::strcmp(argv[1],"--warp");
    if(argc>1 && !warp) return 64;
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr=CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if(FAILED(hr)) return 2;
    ComPtr<IDXGIAdapter1> selected;
    if(!warp) {
        for(UINT i=0;i<32;++i) {
            ComPtr<IDXGIAdapter1> adapter;
            hr=factory->EnumAdapters1(i,&adapter);
            if(hr==DXGI_ERROR_NOT_FOUND) break;
            if(FAILED(hr)) return 2;
            DXGI_ADAPTER_DESC1 info{};
            if(FAILED(adapter->GetDesc1(&info))) return 2;
            if(!(info.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) &&
               ((info.VendorId==0x1af4 && info.DeviceId==0x1050) || std::wcsstr(info.Description,L"Helios"))) {
                if(selected) return 3;
                selected=adapter;
            }
        }
        if(!selected) return 4;
    }
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    const D3D_FEATURE_LEVEL level=D3D_FEATURE_LEVEL_11_0;
    hr=D3D11CreateDevice(selected.Get(),warp?D3D_DRIVER_TYPE_WARP:D3D_DRIVER_TYPE_UNKNOWN,nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,&level,1,D3D11_SDK_VERSION,&device,nullptr,&context);
    if(FAILED(hr)) {std::printf("device HRESULT=0x%08x\n",static_cast<unsigned>(hr));return 5;}
    ComPtr<IDXGIAdapter3> budgetAdapter;
    if(selected && SUCCEEDED(selected.As(&budgetAdapter))) {
        for(auto group:{DXGI_MEMORY_SEGMENT_GROUP_LOCAL,DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL}) {
            DXGI_QUERY_VIDEO_MEMORY_INFO info{};
            if(SUCCEEDED(budgetAdapter->QueryVideoMemoryInfo(0,group,&info))) {
                std::printf("budget local=%u budget=%llu usage=%llu reservation=%llu available=%llu\n",
                    group==DXGI_MEMORY_SEGMENT_GROUP_LOCAL?1u:0u,
                    static_cast<unsigned long long>(info.Budget),static_cast<unsigned long long>(info.CurrentUsage),
                    static_cast<unsigned long long>(info.CurrentReservation),static_cast<unsigned long long>(info.AvailableForReservation));
            }
        }
    }
    unsigned failures=0;
    const DXGI_FORMAT formats[]={DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_FORMAT_R16G16B16A16_FLOAT,DXGI_FORMAT_R32G32B32A32_FLOAT,
        DXGI_FORMAT_D32_FLOAT,DXGI_FORMAT_D24_UNORM_S8_UINT};
    for(auto format:formats) {
        UINT support=0;hr=device->CheckFormatSupport(format,&support);
        if(FAILED(hr)) {++failures;continue;}
        const bool depth=(support & D3D11_FORMAT_SUPPORT_DEPTH_STENCIL)!=0;
        const UINT bind=depth?D3D11_BIND_DEPTH_STENCIL:D3D11_BIND_RENDER_TARGET;
        const bool target=depth || (support & D3D11_FORMAT_SUPPORT_RENDER_TARGET)!=0;
        for(UINT samples: {1u,2u,4u,8u}) {
            UINT quality=0;
            HRESULT query=device->CheckMultisampleQualityLevels(format,samples,&quality);
            const bool advertised=target && SUCCEEDED(query) && quality>0;
            if(!advertised) continue; // Unsupported is valid, not invented success.
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width=67;desc.Height=39;desc.MipLevels=1;desc.ArraySize=1;
            desc.Format=format;desc.SampleDesc.Count=samples;desc.BindFlags=bind;
            ComPtr<ID3D11Texture2D> texture;
            HRESULT create=device->CreateTexture2D(&desc,nullptr,&texture);
            bool ok=SUCCEEDED(create) && texture;
            if(ok && depth) {ComPtr<ID3D11DepthStencilView> view;create=device->CreateDepthStencilView(texture.Get(),nullptr,&view);ok=SUCCEEDED(create) && view;}
            if(ok && !depth) {ComPtr<ID3D11RenderTargetView> view;create=device->CreateRenderTargetView(texture.Get(),nullptr,&view);ok=SUCCEEDED(create) && view;}
            std::printf("contract format=%u samples=%u quality=%u support=0x%08x HRESULT=0x%08x passed=%u\n",
                static_cast<unsigned>(format),samples,quality,support,static_cast<unsigned>(create),ok?1u:0u);
            if(!ok) ++failures;
        }
    }
    // Real shared resource round-trip on this adapter; verify a clear via staging.
    D3D11_TEXTURE2D_DESC desc{};desc.Width=19;desc.Height=7;desc.MipLevels=1;desc.ArraySize=1;
    desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;desc.SampleDesc.Count=1;
    desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;desc.MiscFlags=D3D11_RESOURCE_MISC_SHARED;
    ComPtr<ID3D11Texture2D> source,opened,staging;ComPtr<IDXGIResource> resource;HANDLE handle=nullptr;
    hr=device->CreateTexture2D(&desc,nullptr,&source);
    if(SUCCEEDED(hr)) hr=source.As(&resource);
    if(SUCCEEDED(hr)) hr=resource->GetSharedHandle(&handle);
    if(SUCCEEDED(hr)) hr=device->OpenSharedResource(handle,IID_PPV_ARGS(&opened));
    ComPtr<ID3D11RenderTargetView> rtv;
    if(SUCCEEDED(hr)) hr=device->CreateRenderTargetView(opened.Get(),nullptr,&rtv);
    if(SUCCEEDED(hr)) {
        const float color[]={1,0,0,1};context->ClearRenderTargetView(rtv.Get(),color);
        desc.BindFlags=0;desc.MiscFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        hr=device->CreateTexture2D(&desc,nullptr,&staging);
        if(SUCCEEDED(hr)) {
            context->CopyResource(staging.Get(),source.Get());D3D11_MAPPED_SUBRESOURCE mapped{};
            hr=context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped);
            if(SUCCEEDED(hr)) {
                for(UINT y=0;y<7;++y) for(UINT x=0;x<19;++x) {
                    const auto* p=static_cast<const unsigned char*>(mapped.pData)+y*mapped.RowPitch+x*4;
                    if(p[0]!=255 || p[1]!=0 || p[2]!=0 || p[3]!=255) ++failures;
                }
                context->Unmap(staging.Get(),0);
            }
        }
    }
    std::printf("shared-resource HRESULT=0x%08x\n",static_cast<unsigned>(hr));
    if(FAILED(hr)) ++failures;
    context->ClearState();context->Flush();return failures?1:0;
}
