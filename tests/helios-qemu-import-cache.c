#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include "ui/helios-retry.h"
#include "ui/helios-cache-policy.h"
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define HELIOS_VK_READBACK_CACHE_SIZE 8
typedef struct HeliosVulkanReadback { int unused; } HeliosVulkanReadback;
typedef struct HeliosVulkanReadbackCache HeliosVulkanReadbackCache;
typedef struct QemuDmaBuf { int fd; uint32_t fields[12]; uint64_t modifier, size; } QemuDmaBuf;
static const int *qemu_dmabuf_get_fds(QemuDmaBuf *d, int *n) { *n=1; return &d->fd; }
static const uint32_t *qemu_dmabuf_get_offsets(QemuDmaBuf *d, int *n) { *n=1; return &d->fields[10]; }
static const uint32_t *qemu_dmabuf_get_strides(QemuDmaBuf *d, int *n) { *n=1; return &d->fields[11]; }
#define GETTER(name,index) static uint32_t qemu_dmabuf_get_##name(QemuDmaBuf *d) { return d->fields[index]; }
GETTER(width,0) GETTER(height,1) GETTER(backing_width,2) GETTER(backing_height,3)
GETTER(x,4) GETTER(y,5) GETTER(fourcc,6) GETTER(source_id,7) GETTER(num_planes,8)
static uint64_t qemu_dmabuf_get_modifier(QemuDmaBuf *d) { return d->modifier; }
static uint64_t qemu_dmabuf_get_allocation_size(QemuDmaBuf *d) { return d->size; }
#include "import-cache.inc"
int main(void) {
    assert(helios_cache_entries(NULL)==8 && helios_cache_entries("2")==2);
    assert(helios_cache_entries("0")==0 && helios_cache_entries("16")==0);
    assert(helios_cache_entries("-1")==0 && helios_cache_entries("1;bad")==0);
    HeliosVulkanReadbackCache cache={0};
    for (unsigned i=0;i<ARRAY_SIZE(cache.failures);i++) cache.failures[i].fd=-1;
    char path[]="/tmp/helios-cache-XXXXXX";
    QemuDmaBuf d={.fd=mkstemp(path),.size=4096000}; unlink(path); assert(d.fd>=0);
    HeliosImportFailure *first=helios_import_failure(&cache,&d,true);
    assert(first && first->fd!=d.fd && (fcntl(first->fd,F_GETFD)&FD_CLOEXEC));
    helios_retry_failed(&first->retry,0);
    assert(helios_import_failure(&cache,&d,true)==first);
    assert(!helios_retry_ready(&first->retry,1));
    /* Every geometry, stride and plane change gets a fresh attempt. */
    for (unsigned i=0;i<12;i++) {
        if (i==9) continue; /* No exposed field in this fixture. */
        d.fields[i]++;
        HeliosImportFailure *next=helios_import_failure(&cache,&d,true);
        assert(next && helios_retry_ready(&next->retry,0));
        helios_retry_failed(&next->retry,0);
    }
    d.size++;
    assert(helios_retry_ready(&helios_import_failure(&cache,&d,true)->retry,0));
    d.modifier++;
    assert(helios_retry_ready(&helios_import_failure(&cache,&d,true)->retry,0));
    assert(helios_retry_ready(&helios_import_failure(&cache,&d,false)->retry,0));
    close(d.fd); d.fd=-1;
    assert(helios_import_failure(&cache,&d,true)==NULL);
    for (unsigned i=0;i<ARRAY_SIZE(cache.failures);i++) if(cache.failures[i].fd>=0) close(cache.failures[i].fd);
}
