#include <assert.h>
#include <stdio.h>
#include "ui/vulkan-device-select.h"
#include "ui/helios-retry.h"
int main(void)
{
    HeliosRetry retry = {0};
    unsigned attempts = 0;
    /* 600 failed frame notifications must not create 600 Vulkan devices. */
    for (int64_t now = 0; now < INT64_C(10000000000); now += 16666667) {
        if (helios_retry_ready(&retry, now)) {
            helios_retry_failed(&retry, now);
            attempts++;
        }
    }
    assert(attempts == 6);
    assert(!helios_retry_ready(&retry, retry.next_ns - 1));
    assert(helios_retry_ready(&retry, retry.next_ns));
    retry = (HeliosRetry){0}; /* New identity / successful import. */
    assert(helios_retry_ready(&retry, 0));
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
