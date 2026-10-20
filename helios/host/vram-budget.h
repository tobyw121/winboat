/* SPDX-License-Identifier: MIT
 * One inherited ledger per VM launch, shared by renderer workers and QEMU.
 * Allocation accounting is not a measurement of physical residency/driver overhead.
 */
#ifndef HELIOS_VRAM_BUDGET_H
#define HELIOS_VRAM_BUDGET_H
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#define HELIOS_VRAM_PERCENT 85
#define HELIOS_VRAM_SLOTS 128
struct helios_vram_row { int64_t pid; uint8_t uuid[16]; uint64_t bytes; };
struct helios_vram_ledger { uint64_t magic; struct helios_vram_row row[HELIOS_VRAM_SLOTS]; };
static inline uint64_t helios_vram_cap(uint64_t total, uint64_t driver_budget)
{
    uint64_t ceiling = total / 100 * HELIOS_VRAM_PERCENT + total % 100 * HELIOS_VRAM_PERCENT / 100;
    uint64_t reserve = total - ceiling;
    uint64_t available = driver_budget > reserve ? driver_budget - reserve : 0;
    return available < ceiling ? available : ceiling;
}
static inline bool helios_vram_change_for_pid(const uint8_t uuid[16], uint64_t total,
    uint64_t driver_budget, uint64_t bytes, bool release, uint64_t *used_out, uint64_t *cap_out, int64_t owner_pid)
{
    const char *path = getenv("HELIOS_VRAM_BUDGET_FILE");
    if (!path || !*path) return true;
    if (owner_pid<=0 || (!release && owner_pid!=(int64_t)getpid())) return false;
    int fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;
    bool ok = false; struct stat info;
    struct helios_vram_ledger book;
    if (flock(fd, LOCK_EX) || fstat(fd, &info) || !S_ISREG(info.st_mode) ||
        info.st_nlink != 1 || info.st_uid != geteuid() || (info.st_mode & 077)) goto done;
    memset(&book, 0, sizeof(book));
    if (info.st_size && (info.st_size != (off_t)sizeof(book) || pread(fd, &book, sizeof(book), 0) != (ssize_t)sizeof(book))) goto done;
    if (info.st_size && book.magic != UINT64_C(0x48454c494f533835)) goto done;
    book.magic = UINT64_C(0x48454c494f533835);
    int slot = -1; uint64_t used = 0;
    for (int i = 0; i < HELIOS_VRAM_SLOTS; i++) {
        struct helios_vram_row *r = &book.row[i];
        if (!r->bytes && slot < 0) slot = i;
        if (!memcmp(r->uuid, uuid, 16) && r->bytes) {
            if (UINT64_MAX - used < r->bytes) goto done;
            used += r->bytes;
            if (r->pid == owner_pid) slot = i;
        }
    }
    uint64_t cap = helios_vram_cap(total, driver_budget);
    const char *manual = getenv("HELIOS_VRAM_CAP_BYTES");
    if (manual && *manual && !release) {
        uint64_t limit = 0;
        for (const char *c=manual; *c; c++) {
            if (*c<'0' || *c>'9' || limit>(UINT64_MAX-(unsigned)(*c-'0'))/10) goto done;
            limit=limit*10+(unsigned)(*c-'0');
        }
        if (limit<cap) cap=limit;
    }
    if (used_out) *used_out = used;
    if (cap_out) *cap_out = cap;
    if (!bytes) { ok = true; goto done; }
    if (slot < 0) goto done;
    struct helios_vram_row *r = &book.row[slot];
    if (release) {
        if (r->pid != owner_pid || memcmp(r->uuid, uuid, 16) || bytes > r->bytes) goto done;
        r->bytes -= bytes;
    } else {
        if (!total || used > cap || bytes > cap - used) goto done;
        if (!r->bytes) { r->pid = owner_pid; memcpy(r->uuid, uuid, 16); }
        r->bytes += bytes;
    }
    /* Dead workers are deliberately not reaped: exported buffers can outlive
     * their producer. Keep uncertain charges until the whole VM is restarted. */
    ok = pwrite(fd, &book, sizeof(book), 0) == (ssize_t)sizeof(book);
done:
    flock(fd, LOCK_UN); close(fd); return ok;
}
/* Normal frees stay process-owned. Only the validated shared-reference ledger
 * may release the original owner's charge after its last imported reference. */
static inline bool helios_vram_change(const uint8_t uuid[16], uint64_t total,
    uint64_t driver_budget, uint64_t bytes, bool release, uint64_t *used_out, uint64_t *cap_out)
{
    return helios_vram_change_for_pid(uuid,total,driver_budget,bytes,release,used_out,cap_out,getpid());
}
#endif
