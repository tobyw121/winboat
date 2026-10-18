// Real Helios acceptance probe. Unlike the WARP handler regression, this asks
// Windows' D3D11 runtime to load the installed Helios UMD and reads GPU results.
// It validates resource content, not visible scanout or game compatibility.
#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <array>
#include <cstdio>
#include <cwchar>
#include <stdexcept>
#include <vector>
using Microsoft::WRL::ComPtr;
static void check(HRESULT result) {
    if (FAILED(result)) {
        char message[64]; std::snprintf(message,sizeof(message),"D3D call failed: 0x%08lx",static_cast<unsigned long>(result));
        throw std::runtime_error(message);
    }
}
using Pixel=std::array<float,4>;
static std::vector<Pixel> readTexture(ID3D11Device* device,ID3D11DeviceContext1* context,ID3D11Texture2D* texture) {
    D3D11_TEXTURE2D_DESC desc;texture->GetDesc(&desc);
    desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;check(device->CreateTexture2D(&desc,nullptr,&staging));
    context->CopyResource(staging.Get(),texture);
    D3D11_MAPPED_SUBRESOURCE mapped;check(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
    std::vector<Pixel> result;
    for(UINT y=0;y<desc.Height;y++) {
        auto row=reinterpret_cast<const Pixel*>(static_cast<const char*>(mapped.pData)+y*mapped.RowPitch);
        result.insert(result.end(),row,row+desc.Width);
    }
    context->Unmap(staging.Get(),0);return result;
}
int main() {
    try {
        ComPtr<IDXGIFactory1> factory;check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        ComPtr<IDXGIAdapter1> adapter;
        for(UINT i=0;;i++) {
            ComPtr<IDXGIAdapter1> candidate;HRESULT result=factory->EnumAdapters1(i,&candidate);
            if(result==DXGI_ERROR_NOT_FOUND)break;check(result);
            DXGI_ADAPTER_DESC1 desc;check(candidate->GetDesc1(&desc));
            if(std::wcsstr(desc.Description,L"Helios")){adapter=candidate;break;}
        }
        if(!adapter)throw std::runtime_error("No installed Helios DXGI adapter. Probe refuses WARP/Basic fallback.");
        ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> base;
        const D3D_FEATURE_LEVEL level=D3D_FEATURE_LEVEL_11_0;
        check(D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,&level,1,D3D11_SDK_VERSION,&device,nullptr,&base));
        ComPtr<ID3D11DeviceContext1> context;check(base.As(&context));
        D3D11_TEXTURE2D_DESC desc={};desc.Width=4;desc.Height=4;desc.MipLevels=1;desc.ArraySize=1;
        desc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;desc.SampleDesc.Count=1;
        desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_UNORDERED_ACCESS;
        ComPtr<ID3D11Texture2D> texture;check(device->CreateTexture2D(&desc,nullptr,&texture));
        ComPtr<ID3D11RenderTargetView> rtv;check(device->CreateRenderTargetView(texture.Get(),nullptr,&rtv));
        ComPtr<ID3D11UnorderedAccessView> uav;check(device->CreateUnorderedAccessView(texture.Get(),nullptr,&uav));
        const Pixel color={0.25f,0.5f,0.75f,1.0f},zero={0,0,0,0};
        const D3D11_RECT rects[]={{1,1,3,3},{0,0,0,4}};
        ID3D11View* views[]={rtv.Get(),uav.Get()};
        for(unsigned kind=0;kind<2;kind++)for(unsigned partial=0;partial<2;partial++) {
            context->ClearRenderTargetView(rtv.Get(),zero.data());
            context->ClearView(views[kind],color.data(),partial?rects:nullptr,partial?2:0);
            auto pixels=readTexture(device.Get(),context.Get(),texture.Get());
            for(unsigned i=0;i<pixels.size();i++) {
                const bool inner=i%4>=1&&i%4<3&&i/4>=1&&i/4<3;
                if(pixels[i]!=(!partial||inner?color:zero)) {
                    std::fprintf(stderr,"Texture mismatch: view=%s partial=%u pixel=%u\n",kind?"UAV":"RTV",partial,i);
                    return 1;
                }
            }
            std::printf("Helios %s %s clear: all pixels matched\n",kind?"UAV":"RTV",partial?"rectangle":"full");
        }
        D3D11_BUFFER_DESC bufferDesc={};bufferDesc.ByteWidth=16*sizeof(float);
        bufferDesc.Usage=D3D11_USAGE_DEFAULT;bufferDesc.BindFlags=D3D11_BIND_UNORDERED_ACCESS;
        ComPtr<ID3D11Buffer> buffer;check(device->CreateBuffer(&bufferDesc,nullptr,&buffer));
        D3D11_UNORDERED_ACCESS_VIEW_DESC viewDesc={};viewDesc.Format=DXGI_FORMAT_R32_FLOAT;
        viewDesc.ViewDimension=D3D11_UAV_DIMENSION_BUFFER;viewDesc.Buffer.NumElements=16;
        ComPtr<ID3D11UnorderedAccessView> bufferView;check(device->CreateUnorderedAccessView(buffer.Get(),&viewDesc,&bufferView));
        bufferDesc.Usage=D3D11_USAGE_STAGING;bufferDesc.BindFlags=0;bufferDesc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        ComPtr<ID3D11Buffer> staging;check(device->CreateBuffer(&bufferDesc,nullptr,&staging));
        const D3D11_RECT bufferRect={4,0,8,1};
        for(unsigned partial=0;partial<2;partial++) {
            context->ClearUnorderedAccessViewFloat(bufferView.Get(),zero.data());
            context->ClearView(bufferView.Get(),color.data(),partial?&bufferRect:nullptr,partial?1:0);
            context->CopyResource(staging.Get(),buffer.Get());
            D3D11_MAPPED_SUBRESOURCE mapped;check(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
            const float* values=static_cast<const float*>(mapped.pData);bool matched=true;
            for(unsigned i=0;i<16;i++)if(values[i]!=(!partial||(i>=4&&i<8)?color[0]:0.0f))matched=false;
            context->Unmap(staging.Get(),0);
            if(!matched){std::fprintf(stderr,"Typed buffer mismatch: partial=%u\n",partial);return 1;}
            std::printf("Helios typed buffer %s clear: all elements matched\n",partial?"rectangle":"full");
        }
        std::printf("PASS: installed Helios D3D11 ClearView content. Visible presentation and games were not tested.\n");
        return 0;
    }catch(const std::exception& error){std::fprintf(stderr,"FAIL: %s\n",error.what());return 2;}
}
