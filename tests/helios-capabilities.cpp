// Read actual Windows D3D11 and guest Vulkan capabilities, without changing them.
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <vector>
#include <initializer_list>
using Microsoft::WRL::ComPtr;
static void cap(const char* api,const char* name,unsigned long long value){std::printf("cap %s %s %llu\n",api,name,value);}
template<class T> static T proc(HMODULE module,const char* name){
    FARPROC raw=GetProcAddress(module,name);T fn=nullptr;static_assert(sizeof(fn)==sizeof(raw));std::memcpy(&fn,&raw,sizeof(fn));return fn;
}
static int vulkan(){
    HMODULE dll=LoadLibraryExW(L"vulkan-1.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);if(!dll)return 20;
    auto create=proc<PFN_vkCreateInstance>(dll,"vkCreateInstance");
    auto destroy=proc<PFN_vkDestroyInstance>(dll,"vkDestroyInstance");
    auto enumerate=proc<PFN_vkEnumeratePhysicalDevices>(dll,"vkEnumeratePhysicalDevices");
    auto properties=proc<PFN_vkGetPhysicalDeviceProperties>(dll,"vkGetPhysicalDeviceProperties");
    auto features=proc<PFN_vkGetPhysicalDeviceFeatures>(dll,"vkGetPhysicalDeviceFeatures");
    auto extensions=proc<PFN_vkEnumerateDeviceExtensionProperties>(dll,"vkEnumerateDeviceExtensionProperties");
    if(!create||!destroy||!enumerate||!properties||!features||!extensions)return 21;
    VkApplicationInfo app{};app.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO;app.apiVersion=VK_API_VERSION_1_1;
    VkInstanceCreateInfo info{};info.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;info.pApplicationInfo=&app;
    VkInstance instance=VK_NULL_HANDLE;if(create(&info,nullptr,&instance)!=VK_SUCCESS)return 22;
    uint32_t count=0;if(enumerate(instance,&count,nullptr)!=VK_SUCCESS||count>64||!count){destroy(instance,nullptr);return 23;}
    std::vector<VkPhysicalDevice> devices(count);if(enumerate(instance,&count,devices.data())!=VK_SUCCESS){destroy(instance,nullptr);return 24;}
    VkPhysicalDevice selected=VK_NULL_HANDLE;
    for(auto device:devices){VkPhysicalDeviceProperties p{};properties(device,&p);
        if(std::strstr(p.deviceName,"Helios")||std::strstr(p.deviceName,"Virtio")||std::strstr(p.deviceName,"Venus")){
            if(selected){destroy(instance,nullptr);return 25;}selected=device;
        }
    }
    if(!selected){destroy(instance,nullptr);return 26;}
    VkPhysicalDeviceProperties p{};VkPhysicalDeviceFeatures f{};properties(selected,&p);features(selected,&f);
    cap("vulkan","apiVersion",p.apiVersion);
#define LIMIT(n) cap("vulkan","limit." #n,p.limits.n)
    LIMIT(maxImageDimension2D);LIMIT(maxImageDimension3D);LIMIT(maxImageArrayLayers);LIMIT(maxBoundDescriptorSets);
    LIMIT(maxPerStageDescriptorSamplers);LIMIT(maxPerStageDescriptorStorageBuffers);LIMIT(maxColorAttachments);
    LIMIT(framebufferColorSampleCounts);LIMIT(framebufferDepthSampleCounts);LIMIT(maxComputeWorkGroupInvocations);
#undef LIMIT
#define FEATURE(n) cap("vulkan","feature." #n,f.n)
    FEATURE(robustBufferAccess);FEATURE(fullDrawIndexUint32);FEATURE(independentBlend);FEATURE(geometryShader);
    FEATURE(tessellationShader);FEATURE(sampleRateShading);FEATURE(multiDrawIndirect);FEATURE(drawIndirectFirstInstance);
    FEATURE(depthClamp);FEATURE(fillModeNonSolid);FEATURE(samplerAnisotropy);FEATURE(shaderInt64);FEATURE(shaderFloat64);
    FEATURE(sparseBinding);FEATURE(sparseResidencyImage2D);
#undef FEATURE
    count=0;if(extensions(selected,nullptr,&count,nullptr)!=VK_SUCCESS||count>4096){destroy(instance,nullptr);return 27;}
    std::vector<VkExtensionProperties> ext(count);
    if(count&&extensions(selected,nullptr,&count,ext.data())!=VK_SUCCESS){destroy(instance,nullptr);return 28;}
    for(const auto& e:ext){char name[300];std::snprintf(name,sizeof(name),"extension.%s",e.extensionName);cap("vulkan",name,e.specVersion);}
    destroy(instance,nullptr);FreeLibrary(dll);return 0;
}
int main(int argc,char** argv){
    const bool warp=argc==2&&!std::strcmp(argv[1],"--warp");if(argc>1&&!warp)return 64;
    ComPtr<IDXGIFactory1> factory;if(FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))))return 2;
    ComPtr<IDXGIAdapter1> selected;
    if(!warp)for(UINT i=0;i<32;i++){
        ComPtr<IDXGIAdapter1> adapter;HRESULT hr=factory->EnumAdapters1(i,&adapter);if(hr==DXGI_ERROR_NOT_FOUND)break;if(FAILED(hr))return 3;
        DXGI_ADAPTER_DESC1 d{};if(FAILED(adapter->GetDesc1(&d)))return 3;
        if(!(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)&&((d.VendorId==0x1af4&&d.DeviceId==0x1050)||std::wcsstr(d.Description,L"Helios"))){if(selected)return 4;selected=adapter;}
    }
    if(!warp&&!selected)return 5;
    ComPtr<ID3D11Device> device;D3D_FEATURE_LEVEL level{};const D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_11_0,D3D_FEATURE_LEVEL_10_1,D3D_FEATURE_LEVEL_10_0};
    if(FAILED(D3D11CreateDevice(selected.Get(),warp?D3D_DRIVER_TYPE_WARP:D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,levels,3,D3D11_SDK_VERSION,&device,&level,nullptr)))return 6;
    cap("d3d11","featureLevel",level);cap("identity","warp",warp?1:0);
    D3D11_FEATURE_DATA_THREADING threading{};
    if(SUCCEEDED(device->CheckFeatureSupport(D3D11_FEATURE_THREADING,&threading,sizeof(threading)))){
        cap("d3d11","DriverConcurrentCreates",threading.DriverConcurrentCreates);cap("d3d11","DriverCommandLists",threading.DriverCommandLists);
    }
    D3D11_FEATURE_DATA_D3D11_OPTIONS options{};
    if(SUCCEEDED(device->CheckFeatureSupport(D3D11_FEATURE_D3D11_OPTIONS,&options,sizeof(options)))){
        cap("d3d11","OutputMergerLogicOp",options.OutputMergerLogicOp);cap("d3d11","ClearView",options.ClearView);
        cap("d3d11","ConstantBufferOffsetting",options.ConstantBufferOffsetting);cap("d3d11","DiscardAPIsSeenByDriver",options.DiscardAPIsSeenByDriver);
    }
    for(auto format:{DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_FORMAT_R16G16B16A16_FLOAT,DXGI_FORMAT_D32_FLOAT}){
        UINT support=0;if(FAILED(device->CheckFormatSupport(format,&support)))return 7;
        char key[64];std::snprintf(key,sizeof(key),"format.%u.support",static_cast<unsigned>(format));cap("d3d11",key,support);
        for(UINT samples:{1u,2u,4u,8u}){UINT quality=0;if(FAILED(device->CheckMultisampleQualityLevels(format,samples,&quality)))return 8;
            std::snprintf(key,sizeof(key),"format.%u.msaa.%u",static_cast<unsigned>(format),samples);cap("d3d11",key,quality);}
    }
    const int result=warp?0:vulkan();
    if(!result)cap("identity","complete",1);
    return result;
}
