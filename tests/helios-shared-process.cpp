// Bounded two-device / two-process NT shared-resource + keyed-mutex test.
#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <cstdio>
#include <cwchar>
#include <cstdlib>
#include <cstdint>
#include <functional>
using Microsoft::WRL::ComPtr;
static HRESULT create(bool warp,ComPtr<ID3D11Device>& device,ComPtr<ID3D11DeviceContext>& context){
    ComPtr<IDXGIFactory1> factory;HRESULT hr=CreateDXGIFactory1(IID_PPV_ARGS(&factory));if(FAILED(hr))return hr;
    ComPtr<IDXGIAdapter1> selected;
    if(!warp) for(UINT i=0;i<32;++i){
        ComPtr<IDXGIAdapter1> adapter;hr=factory->EnumAdapters1(i,&adapter);
        if(hr==DXGI_ERROR_NOT_FOUND)break;if(FAILED(hr))return hr;
        DXGI_ADAPTER_DESC1 desc{};hr=adapter->GetDesc1(&desc);if(FAILED(hr))return hr;
        if(!(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) && ((desc.VendorId==0x1af4 && desc.DeviceId==0x1050)||std::wcsstr(desc.Description,L"Helios"))){
            if(selected)return E_UNEXPECTED;selected=adapter;
        }
    }
    if(!warp && !selected)return DXGI_ERROR_NOT_FOUND;
    D3D_FEATURE_LEVEL level=D3D_FEATURE_LEVEL_11_0;
    return D3D11CreateDevice(selected.Get(),warp?D3D_DRIVER_TYPE_WARP:D3D_DRIVER_TYPE_UNKNOWN,nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,&level,1,D3D11_SDK_VERSION,&device,nullptr,&context);
}
static LUID adapter_id(ID3D11Device* device){
    LUID result{};ComPtr<IDXGIDevice> dxgi;ComPtr<IDXGIAdapter> adapter;DXGI_ADAPTER_DESC desc{};
    if(SUCCEEDED(device->QueryInterface(IID_PPV_ARGS(&dxgi))) && SUCCEEDED(dxgi->GetAdapter(&adapter)) && SUCCEEDED(adapter->GetDesc(&desc)))result=desc.AdapterLuid;
    return result;
}
static HRESULT pixels(ID3D11Device* device,ID3D11DeviceContext* context,ID3D11Texture2D* texture,bool green){
    D3D11_TEXTURE2D_DESC desc{};texture->GetDesc(&desc);desc.BindFlags=0;desc.MiscFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;HRESULT hr=device->CreateTexture2D(&desc,nullptr,&staging);if(FAILED(hr))return hr;
    context->CopyResource(staging.Get(),texture);D3D11_MAPPED_SUBRESOURCE mapped{};hr=context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped);if(FAILED(hr))return hr;
    bool ok=true;
    for(UINT y=0;y<desc.Height;y++)for(UINT x=0;x<desc.Width;x++){
        const auto* p=static_cast<const unsigned char*>(mapped.pData)+y*mapped.RowPitch+x*4;
        if(p[0]!=(green?0:255)||p[1]!=(green?255:0)||p[2]!=0||p[3]!=255)ok=false;
    }
    context->Unmap(staging.Get(),0);return ok?S_OK:E_FAIL;
}
static HRESULT exchange(ID3D11Device* device,ID3D11DeviceContext* context,HANDLE handle,const std::function<void()>& dropProducer={}){
    ComPtr<ID3D11Device1> device1;ComPtr<ID3D11Texture2D> texture;ComPtr<IDXGIKeyedMutex> mutex;
    HRESULT hr=device->QueryInterface(IID_PPV_ARGS(&device1));
    if(SUCCEEDED(hr))hr=device1->OpenSharedResource1(handle,IID_PPV_ARGS(&texture));
    if(SUCCEEDED(hr))hr=texture.As(&mutex);if(FAILED(hr))return hr;
    if(dropProducer)dropProducer();
    hr=mutex->AcquireSync(1,3000);if(hr!=S_OK)return FAILED(hr)?hr:E_FAIL;
    hr=pixels(device,context,texture.Get(),false);
    ComPtr<ID3D11RenderTargetView> view;
    if(SUCCEEDED(hr))hr=device->CreateRenderTargetView(texture.Get(),nullptr,&view);
    if(SUCCEEDED(hr)){const float green[]={0,1,0,1};context->ClearRenderTargetView(view.Get(),green);context->Flush();hr=pixels(device,context,texture.Get(),true);}
    HRESULT release=mutex->ReleaseSync(2);return FAILED(hr)?hr:release;
}
int wmain(int argc,wchar_t** argv){
    const bool child=argc>=2 && !std::wcscmp(argv[1],L"--child");
    bool warp=argc>=2 && !std::wcscmp(argv[argc-1],L"--warp");
    if((child && argc!=(warp?6:5)) || (!child && argc!=(warp?2:1)))return 64;
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;HRESULT hr=create(warp,device,context);
    if(FAILED(hr)){std::printf("device HRESULT=0x%08x\n",static_cast<unsigned>(hr));return 2;}
    if(child){
        wchar_t* end=nullptr;auto raw=std::wcstoull(argv[2],&end,10);if(!end||*end||!raw)return 64;
        auto low=std::wcstoul(argv[3],&end,10);if(!end||*end)return 64;
        auto high=std::wcstoul(argv[4],&end,10);if(!end||*end)return 64;
        const LUID actual=adapter_id(device.Get());
        if(actual.LowPart!=low || static_cast<ULONG>(actual.HighPart)!=high)return 3;
        hr=exchange(device.Get(),context.Get(),reinterpret_cast<HANDLE>(static_cast<uintptr_t>(raw)));
        return SUCCEEDED(hr)?0:4;
    }
    // Test both a second device in this process and a separate child process.
    for(int mode=0;mode<3;mode++){
        D3D11_TEXTURE2D_DESC desc{};desc.Width=31;desc.Height=17;desc.MipLevels=1;desc.ArraySize=1;
        desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
        desc.MiscFlags=D3D11_RESOURCE_MISC_SHARED_NTHANDLE|D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
        ComPtr<ID3D11Texture2D> texture;ComPtr<ID3D11RenderTargetView> view;ComPtr<IDXGIResource1> resource;ComPtr<IDXGIKeyedMutex> mutex;
        hr=device->CreateTexture2D(&desc,nullptr,&texture);
        if(SUCCEEDED(hr))hr=device->CreateRenderTargetView(texture.Get(),nullptr,&view);
        if(SUCCEEDED(hr))hr=texture.As(&resource);if(SUCCEEDED(hr))hr=texture.As(&mutex);
        HANDLE handle=nullptr;SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES),nullptr,TRUE};
        if(SUCCEEDED(hr))hr=resource->CreateSharedHandle(&security,DXGI_SHARED_RESOURCE_READ|DXGI_SHARED_RESOURCE_WRITE,nullptr,&handle);
        if(FAILED(hr))return 5;
        hr=mutex->AcquireSync(0,3000);
        if(hr==S_OK){const float red[]={1,0,0,1};context->ClearRenderTargetView(view.Get(),red);context->Flush();hr=mutex->ReleaseSync(1);}
        else hr=E_FAIL;
        if(SUCCEEDED(hr) && mode!=1){
            ComPtr<ID3D11Device> other;ComPtr<ID3D11DeviceContext> otherContext;
            hr=create(warp,other,otherContext);
            if(SUCCEEDED(hr)){LUID a=adapter_id(device.Get()),b=adapter_id(other.Get());if(a.LowPart!=b.LowPart||a.HighPart!=b.HighPart)hr=E_FAIL;}
            if(SUCCEEDED(hr)) {
                if(mode==2)hr=exchange(other.Get(),otherContext.Get(),handle,[&]{
                    context->ClearState();context->Flush();view.Reset();resource.Reset();mutex.Reset();texture.Reset();
                    CloseHandle(handle);handle=nullptr;
                });
                else hr=exchange(other.Get(),otherContext.Get(),handle);
            }
        }else if(SUCCEEDED(hr)){
            wchar_t executable[32768],command[33000];DWORD length=GetModuleFileNameW(nullptr,executable,32768);
            if(!length||length>=32768){CloseHandle(handle);return 6;}
            LUID id=adapter_id(device.Get());
            swprintf_s(command,L"\"%ls\" --child %llu %lu %lu%ls",executable,
                static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(handle)),id.LowPart,static_cast<ULONG>(id.HighPart),warp?L" --warp":L"");
            SIZE_T size=0;InitializeProcThreadAttributeList(nullptr,1,0,&size);
            auto* attributes=static_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(HeapAlloc(GetProcessHeap(),0,size));
            if(!attributes){CloseHandle(handle);return 6;}
            bool initialized=InitializeProcThreadAttributeList(attributes,1,0,&size)!=FALSE;
            STARTUPINFOEXW startup{};startup.StartupInfo.cb=sizeof(startup);startup.lpAttributeList=attributes;PROCESS_INFORMATION process{};
            bool launched=initialized && UpdateProcThreadAttribute(attributes,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,&handle,sizeof(handle),nullptr,nullptr) &&
                CreateProcessW(executable,command,nullptr,nullptr,TRUE,EXTENDED_STARTUPINFO_PRESENT|CREATE_NO_WINDOW,nullptr,nullptr,&startup.StartupInfo,&process);
            if(initialized)DeleteProcThreadAttributeList(attributes);HeapFree(GetProcessHeap(),0,attributes);
            if(!launched)hr=E_FAIL;
            else {
                DWORD waited=WaitForSingleObject(process.hProcess,15000),code=1;
                if(waited!=WAIT_OBJECT_0){TerminateProcess(process.hProcess,124);WaitForSingleObject(process.hProcess,5000);hr=E_FAIL;}
                else if(!GetExitCodeProcess(process.hProcess,&code)||code!=0)hr=E_FAIL;
                CloseHandle(process.hThread);CloseHandle(process.hProcess);
            }
        }
        if(SUCCEEDED(hr) && mode!=2){
            HRESULT acquired=mutex->AcquireSync(2,3000);
            if(acquired==S_OK){hr=pixels(device.Get(),context.Get(),texture.Get(),true);HRESULT released=mutex->ReleaseSync(0);if(SUCCEEDED(hr))hr=released;}
            else hr=E_FAIL;
        }
        if(handle)CloseHandle(handle);
        std::printf("shared mode=%s HRESULT=0x%08x\n",mode==2?"producer-release":mode?"process":"device",static_cast<unsigned>(hr));
        if(FAILED(hr))return 7;
    }
    return 0;
}
