#include <assert.h>
#include <stdio.h>
#include "ui/vulkan-device-select.h"
int main(void)
{
    HeliosDrmDeviceId ids[] = {{true, 226, 129}, {true, 226, 128}, {false, 0, 0}};
    /* Enumeration/vendor priority cannot override the actual DRM render node. */
    assert(helios_vulkan_device_index(ids, 3, 226, 128) == 1);
    assert(helios_vulkan_device_index(ids, 3, 226, 129) == 0);
    assert(helios_vulkan_device_index(ids, 3, 226, 130) == -1);
    ids[2] = ids[1];
    assert(helios_vulkan_device_index(ids, 3, 226, 128) == -1);
    ids[1].has_render = ids[2].has_render = false;
    assert(helios_vulkan_device_index(ids, 3, 226, 128) == -1);
    ids[0].render_minor = -1;
    assert(helios_vulkan_device_index(ids, 3, 226, UINT32_MAX) == -1);
    assert(helios_vulkan_device_index(NULL, 0, 226, 128) == -1);
    puts("DRM device selection: reordered GPUs, ambiguity, missing identity and invalid nodes passed.");
}
