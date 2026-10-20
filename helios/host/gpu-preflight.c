#define _XOPEN_SOURCE 700
#include <vulkan/vulkan.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
static int has(const VkExtensionProperties *extensions,uint32_t count,const char *name){
    for(uint32_t i=0;i<count;i++) if(!strcmp(extensions[i].extensionName,name)) return 1;
    return 0;
}
int main(int argc,char **argv){
    int inventory=argc==2 && !strcmp(argv[1],"--inventory");
    struct stat node={0};
    if(!inventory && (argc!=2 || stat(argv[1],&node) || !S_ISCHR(node.st_mode))) return 64;
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_3};
    VkInstanceCreateInfo create={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app};
    VkInstance instance=VK_NULL_HANDLE;VkResult result=vkCreateInstance(&create,NULL,&instance);
    if(result!=VK_SUCCESS){fprintf(stderr,"Helios preflight: Vulkan instance result=%d\n",result);return 2;}
    uint32_t count=0;result=vkEnumeratePhysicalDevices(instance,&count,NULL);
    if(result!=VK_SUCCESS || !count || count>64){vkDestroyInstance(instance,NULL);return 3;}
    VkPhysicalDevice devices[64];result=vkEnumeratePhysicalDevices(instance,&count,devices);
    if(result!=VK_SUCCESS){vkDestroyInstance(instance,NULL);return 3;}
    unsigned matched=0;int valid=0;
    printf("{\"schema\":1,\"devices\":[");
    for(uint32_t i=0;i<count;i++){
        uint32_t n=0;VkExtensionProperties extensions[1024];
        if(vkEnumerateDeviceExtensionProperties(devices[i],NULL,&n,NULL)!=VK_SUCCESS || n>1024) n=0;
        if(n && vkEnumerateDeviceExtensionProperties(devices[i],NULL,&n,extensions)!=VK_SUCCESS) n=0;
        int drm=has(extensions,n,VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME);
        int pci=has(extensions,n,VK_EXT_PCI_BUS_INFO_EXTENSION_NAME);
        int external=has(extensions,n,VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME);
        int budget=has(extensions,n,VK_EXT_MEMORY_BUDGET_EXTENSION_NAME);
        VkPhysicalDeviceDrmPropertiesEXT drmInfo={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT};
        VkPhysicalDevicePCIBusInfoPropertiesEXT pciInfo={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PCI_BUS_INFO_PROPERTIES_EXT};
        VkPhysicalDeviceIDProperties identity={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
        identity.pNext=drm?(void*)&drmInfo:pci?(void*)&pciInfo:NULL;
        if(drm) drmInfo.pNext=pci?&pciInfo:NULL;
        VkPhysicalDeviceProperties2 properties={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,.pNext=&identity};
        vkGetPhysicalDeviceProperties2(devices[i],&properties);
        int selected=!inventory && drm && drmInfo.hasRender &&
            drmInfo.renderMajor==(int64_t)major(node.st_rdev) && drmInfo.renderMinor==(int64_t)minor(node.st_rdev);
        int pciMatch=-1;
        if(selected && pci){
            char path[128],resolved[PATH_MAX];
            snprintf(path,sizeof(path),"/sys/dev/char/%u:%u/device",major(node.st_rdev),minor(node.st_rdev));
            if(realpath(path,resolved)){
                const char *base=strrchr(resolved,'/');unsigned domain,bus,device,function;char extra;
                if(base && sscanf(base+1,"%x:%x:%x.%x%c",&domain,&bus,&device,&function,&extra)==4)
                    pciMatch=domain==pciInfo.pciDomain && bus==pciInfo.pciBus && device==pciInfo.pciDevice && function==pciInfo.pciFunction;
            }
        }
        VkPhysicalDeviceVulkan12Features f12={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
        VkPhysicalDeviceVulkan13Features f13={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
        f12.pNext=&f13;
        VkPhysicalDeviceFeatures2 features={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,.pNext=&f12};
        vkGetPhysicalDeviceFeatures2(devices[i],&features);
        VkPhysicalDeviceExternalImageFormatInfo externalInfo={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT};
        VkPhysicalDeviceImageFormatInfo2 imageInfo={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,.pNext=&externalInfo,
            .format=VK_FORMAT_B8G8R8A8_UNORM,.type=VK_IMAGE_TYPE_2D,.tiling=VK_IMAGE_TILING_OPTIMAL,.usage=VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_SAMPLED_BIT};
        VkExternalImageFormatProperties externalProperties={.sType=VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES};
        VkImageFormatProperties2 imageProperties={.sType=VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,.pNext=&externalProperties};
        VkResult imageResult=VK_ERROR_FORMAT_NOT_SUPPORTED;
        if(has(extensions,n,VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME)) imageResult=vkGetPhysicalDeviceImageFormatProperties2(devices[i],&imageInfo,&imageProperties);
        if(selected){matched++;valid=properties.properties.apiVersion>=VK_API_VERSION_1_3 && external && pciMatch!=0;}
        if(i) putchar(',');
        printf("{\"vendorId\":%u,\"deviceId\":%u,\"apiVersion\":%u,\"selected\":%s,\"externalMemoryFd\":%s,\"memoryBudgetAvailable\":%s,\"pciMatchesDrm\":",
            properties.properties.vendorID,properties.properties.deviceID,properties.properties.apiVersion,selected?"true":"false",external?"true":"false",budget?"true":"false");
        if(pciMatch<0) printf("null");else printf("%s",pciMatch?"true":"false");
        printf(",\"timelineSemaphore\":%s,\"synchronization2\":%s,\"dynamicRendering\":%s,\"bgraOptimalImportable\":%s,\"imageQueryResult\":%d",
            f12.timelineSemaphore?"true":"false",f13.synchronization2?"true":"false",f13.dynamicRendering?"true":"false",
            imageResult==VK_SUCCESS && (externalProperties.externalMemoryProperties.externalMemoryFeatures&VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT)?"true":"false",imageResult);
        printf(",\"deviceUuid\":\"");for(unsigned j=0;j<VK_UUID_SIZE;j++) printf("%02x",identity.deviceUUID[j]);
        printf("\",\"driverUuid\":\"");for(unsigned j=0;j<VK_UUID_SIZE;j++) printf("%02x",identity.driverUUID[j]);
        printf("\",\"heaps\":[");
        VkPhysicalDeviceMemoryBudgetPropertiesEXT budgets={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT};
        VkPhysicalDeviceMemoryProperties2 memory={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,.pNext=budget?&budgets:NULL};
        vkGetPhysicalDeviceMemoryProperties2(devices[i],&memory);
        for(uint32_t j=0;j<memory.memoryProperties.memoryHeapCount;j++){
            if(j) putchar(',');
            printf("{\"sizeBytes\":%llu,\"deviceLocal\":%s,\"budgetBytes\":",
                (unsigned long long)memory.memoryProperties.memoryHeaps[j].size,
                memory.memoryProperties.memoryHeaps[j].flags&VK_MEMORY_HEAP_DEVICE_LOCAL_BIT?"true":"false");
            if(budget) printf("%llu,\"usageBytes\":%llu",(unsigned long long)budgets.heapBudget[j],(unsigned long long)budgets.heapUsage[j]);
            else printf("null,\"usageBytes\":null");
            putchar('}');
        }
        printf("]}");
    }
    printf("],\"matchingDevices\":%u,\"ready\":%s,\"scope\":\"Vulkan/DRM identity and driver budget estimates; heapUsage is probe-process usage, not renderer VRAM; no rendering proof\"}\n",matched,!inventory && matched==1 && valid?"true":"false");
    vkDestroyInstance(instance,NULL);
    return inventory?0:(matched==1 && valid?0:4);
}
