/* SPDX-License-Identifier: MIT
 * Roundtrip advertised features through real device creation. Unlike enumeration
 * this exercises the guest validation AND the renderer's feature chain.
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int check(VkPhysicalDevice gpu, uint32_t family, void *chain, const char *name, const char *extension)
{
    VkPhysicalDeviceFeatures2 features = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = chain };
    vkGetPhysicalDeviceFeatures2(gpu, &features);
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo info = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &features, .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue };
    if (extension) { info.enabledExtensionCount = 1; info.ppEnabledExtensionNames = &extension; }
    VkDevice device = VK_NULL_HANDLE;
    VkResult result = vkCreateDevice(gpu, &info, NULL, &device);
    printf("advertised feature roundtrip %s: VkResult=%d\n", name, result);
    if (result != VK_SUCCESS) return 1;
    vkDestroyDevice(device, NULL);
    return 0;
}

int main(int argc, char **argv)
{
    /* Match FurMark's 1.1 application instance, even with a 1.4 physical device. */
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Helios feature roundtrip", .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = vkCreateInstance(&info, NULL, &instance);
    if (result != VK_SUCCESS) { printf("vkCreateInstance: %d\n", result); return 1; }
    uint32_t count = 0;
    result = vkEnumeratePhysicalDevices(instance, &count, NULL);
    VkPhysicalDevice *gpus = count ? calloc(count, sizeof(*gpus)) : NULL;
    int failed = 1;
    if (result != VK_SUCCESS || !gpus) goto done;
    result = vkEnumeratePhysicalDevices(instance, &count, gpus);
    if (result != VK_SUCCESS) goto done;
    for (uint32_t i = 0; i < count; ++i) {
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(gpus[i], &props);
        if (!(argc == 2 && strcmp(argv[1], "--allow-other-driver") == 0) &&
            !strstr(props.deviceName, "Helios") && !strstr(props.deviceName, "Virtio-GPU Venus")) continue;
        printf("device: %s; physical API %u.%u.%u\n", props.deviceName,
            VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion), VK_VERSION_PATCH(props.apiVersion));
        uint32_t families = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(gpus[i], &families, NULL);
        VkQueueFamilyProperties *queues = families ? calloc(families, sizeof(*queues)) : NULL;
        if (!queues) goto done;
        vkGetPhysicalDeviceQueueFamilyProperties(gpus[i], &families, queues);
        uint32_t family = 0;
        while (family < families && !(queues[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) ++family;
        free(queues);
        if (family == families) goto done;
        failed = check(gpus[i], family, NULL, "1.0", NULL);
        if (props.apiVersion >= VK_API_VERSION_1_2) {
            VkPhysicalDeviceVulkan11Features f11 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES };
            VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
            failed |= check(gpus[i], family, &f11, "1.1", NULL);
            failed |= check(gpus[i], family, &f12, "1.2", NULL);
        }
        if (props.apiVersion >= VK_API_VERSION_1_3) {
            VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
            failed |= check(gpus[i], family, &f13, "1.3", NULL);
        }
        if (props.apiVersion >= VK_API_VERSION_1_4) {
            VkPhysicalDeviceVulkan14Features f14 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES };
            failed |= check(gpus[i], family, &f14, "1.4", NULL);
        }
        uint32_t extension_count = 0;
        if (vkEnumerateDeviceExtensionProperties(gpus[i], NULL, &extension_count, NULL) != VK_SUCCESS) { failed = 1; goto done; }
        VkExtensionProperties *extensions = extension_count ? calloc(extension_count, sizeof(*extensions)) : NULL;
        if (extension_count && !extensions) { failed = 1; goto done; }
        result = vkEnumerateDeviceExtensionProperties(gpus[i], NULL, &extension_count, extensions);
        if (result == VK_SUCCESS) {
            for (uint32_t e = 0; e < extension_count; ++e) {
                if (!strcmp(extensions[e].extensionName, VK_EXT_EXTENDED_DYNAMIC_STATE_3_EXTENSION_NAME)) {
                    VkPhysicalDeviceExtendedDynamicState3FeaturesEXT f = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT };
                    failed |= check(gpus[i], family, &f, "EXT_extended_dynamic_state3", VK_EXT_EXTENDED_DYNAMIC_STATE_3_EXTENSION_NAME);
                }
            }
        } else { failed = 1; }
        free(extensions);
        goto done;
    }
    fprintf(stderr, "No Helios Vulkan device found.\n");
done:
    free(gpus);
    vkDestroyInstance(instance, NULL);
    return failed;
}
