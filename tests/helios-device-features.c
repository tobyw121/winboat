/* SPDX-License-Identifier: MIT
 * Execute the production chain copier with real Vulkan structure layouts.
 * The allocator and structure-size lookup are fixtures; no GPU is simulated.
 */
#include <vulkan/vulkan.h>
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
static int remaining = -1, live;
static void *vk_alloc(const VkAllocationCallbacks *a, size_t n, size_t alignment, VkSystemAllocationScope scope) {
    (void)a; (void)alignment; (void)scope;
    if (remaining == 0) return NULL;
    if (remaining > 0) --remaining;
    void *p = malloc(n); if (p) ++live; return p;
}
static void *vk_zalloc(const VkAllocationCallbacks *a, size_t n, size_t alignment, VkSystemAllocationScope scope) {
    void *p = vk_alloc(a, n, alignment, scope); if (p) memset(p, 0, n); return p;
}
static void vk_free(const VkAllocationCallbacks *a, void *p) { (void)a; if (p) { --live; free(p); } }
static size_t vk_structure_type_size(const VkBaseInStructure *p) {
    switch (p->sType) {
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2: return sizeof(VkPhysicalDeviceFeatures2);
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES: return sizeof(VkPhysicalDeviceVulkan12Features);
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES: return sizeof(VkPhysicalDeviceTimelineSemaphoreFeatures);
    case VK_STRUCTURE_TYPE_DEVICE_GROUP_DEVICE_CREATE_INFO: return sizeof(VkDeviceGroupDeviceCreateInfo);
    default: return 0;
    }
}
#include "vn_device_features.h"
int main(void) {
    VkPhysicalDeviceFeatures2 features = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
    features.features.robustBufferAccess = VK_TRUE;
    VkPhysicalDevicePresentIdFeaturesKHR present = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR, .presentId = VK_TRUE };
    VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .descriptorIndexing = VK_TRUE };
    VkPhysicalDevice gpu = (VkPhysicalDevice)(uintptr_t)7;
    VkDeviceGroupDeviceCreateInfo group = { .sType = VK_STRUCTURE_TYPE_DEVICE_GROUP_DEVICE_CREATE_INFO, .physicalDeviceCount = 1, .pPhysicalDevices = &gpu };
    VkBaseInStructure unknown = { .sType = (VkStructureType)0x7fffffff };
    features.pNext = &present; present.pNext = &f12; f12.pNext = &group; group.pNext = &unknown;
    VkBaseOutStructure *out = NULL;
    assert(vn_device_features_prepare(NULL, &features, true, &out) == VK_SUCCESS);
    assert(out != (void *)&features);
    assert(((VkPhysicalDeviceFeatures2 *)out)->features.robustBufferAccess == VK_TRUE);
    assert(out->pNext->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES);
    VkPhysicalDeviceVulkan12Features *copy = (void *)out->pNext;
    assert(copy->timelineSemaphore && copy->descriptorIndexing);
    assert(copy->pNext && ((VkBaseOutStructure *)copy->pNext)->pNext == NULL);
    assert(((VkDeviceGroupDeviceCreateInfo *)copy->pNext)->pPhysicalDevices == &gpu);
    assert(!f12.timelineSemaphore && present.pNext == &f12 && features.pNext == &present);
    vn_device_features_free(NULL, out); assert(!live);
    assert(vn_device_features_prepare(NULL, &features, false, &out) == VK_SUCCESS);
    assert(!((VkPhysicalDeviceVulkan12Features *)out->pNext)->timelineSemaphore);
    vn_device_features_free(NULL, out); assert(!live);
    // Every allocation failure must release the partial chain and clear output.
    for (int i = 0; i < 3; ++i) {
        remaining = i; out = (void *)(uintptr_t)1;
        assert(vn_device_features_prepare(NULL, &features, true, &out) == VK_ERROR_OUT_OF_HOST_MEMORY);
        assert(!out && !live);
    }
    remaining = -1;
    VkPhysicalDeviceTimelineSemaphoreFeatures timeline = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES };
    assert(vn_device_features_prepare(NULL, &timeline, true, &out) == VK_SUCCESS);
    assert(((VkPhysicalDeviceTimelineSemaphoreFeatures *)out)->timelineSemaphore && !out->pNext);
    assert(!timeline.timelineSemaphore);
    vn_device_features_free(NULL, out); assert(!live);
    // Empty chain: only an internal timeline when explicitly requested.
    assert(vn_device_features_prepare(NULL, NULL, false, &out) == VK_SUCCESS && !out);
    assert(vn_device_features_prepare(NULL, NULL, true, &out) == VK_SUCCESS);
    assert(out->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES && !out->pNext);
    vn_device_features_free(NULL, out); assert(!live);
    remaining = 0;
    assert(vn_device_features_prepare(NULL, NULL, true, &out) == VK_ERROR_OUT_OF_HOST_MEMORY && !out && !live);
    puts("Guest feature filtering, immutable input, promoted timeline, nested pointers and OOM cleanup passed.");
    return 0;
}
