#include <glib.h>
#include <vulkan/vulkan.h>
#include <inttypes.h>
#include <assert.h>
#include <stdio.h>
#include "ui/helios-memory-budget.h"
#define error_report(...) ((void)fprintf(stderr,__VA_ARGS__))
#include "memory-helper.inc"
int main(void){
    (void)helios_memory_serial;
    g_setenv("HELIOS_READBACK_BUDGET_MIB","1",TRUE);
    VkInstance instance;
    VkInstanceCreateInfo ci={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    assert(vkCreateInstance(&ci,NULL,&instance)==VK_SUCCESS);
    VkPhysicalDevice physical[16];uint32_t count=16;
    assert(vkEnumeratePhysicalDevices(instance,&count,physical)==VK_SUCCESS && count);
    float priority=1;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=0,.queueCount=1,.pQueuePriorities=&priority};
    VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi};
    VkDevice device;assert(vkCreateDevice(physical[0],&di,NULL,&device)==VK_SUCCESS);
    VkMemoryAllocateInfo allocation={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=4096,.memoryTypeIndex=0};
    VkDeviceMemory memory=VK_NULL_HANDLE;uint64_t accounted=0;
    assert(helios_allocate_owned(device,&allocation,&memory,&accounted)==VK_SUCCESS);
    assert(accounted==4096 && helios_owned_memory.used==4096);
    allocation.allocationSize=1048576;
    VkDeviceMemory denied=VK_NULL_HANDLE;uint64_t unchanged=0;
    assert(helios_allocate_owned(device,&allocation,&denied,&unchanged)==VK_ERROR_OUT_OF_DEVICE_MEMORY);
    assert(unchanged==0 && denied==VK_NULL_HANDLE && helios_owned_memory.used==4096 && helios_memory_rejected==1);
    vkFreeMemory(device,memory,NULL);
    assert(helios_budget_release(&helios_owned_memory,accounted));
    vkDestroyDevice(device,NULL);vkDestroyInstance(instance,NULL);
}
