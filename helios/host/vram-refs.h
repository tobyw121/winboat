/* SPDX-License-Identifier: MIT
 * Known DMA-BUF backing references only. Opaque handles are not guessed from
 * their fd numbers/inodes. A lost worker keeps its charge conservatively.
 */
#ifndef HELIOS_VRAM_REFS_H
#define HELIOS_VRAM_REFS_H
#ifndef HELIOS_VRAM_BUDGET_H
#include "helios-vram-budget.h"
#endif
#include <stdio.h>
#include <limits.h>
#include <errno.h>
#define HELIOS_REF_SLOTS 256
struct helios_vram_reference { uint64_t dev, ino; uint8_t uuid[16]; bool valid; };
struct helios_ref_row { struct helios_vram_reference key; uint64_t bytes; int64_t owner; uint32_t refs; };
struct helios_ref_book { uint64_t magic; struct helios_ref_row row[HELIOS_REF_SLOTS]; };
/* mode: 0=publish new (allocation + exported fd), 1=retain imported/fd ref,
 * 2=drop ref. A NULL uuid allows unambiguous lookup/retain/drop of an existing fd ref.
 * Return 1=known/success, 0=unknown/unmanaged, -1=refused; never count unknown as known. */
static inline int helios_vram_reference_change(const uint8_t *uuid, int source_fd,
    struct helios_vram_reference *reference, uint64_t bytes, int mode)
{
    const char *base=getenv("HELIOS_VRAM_BUDGET_FILE");
    if(!base || !*base) return 0;
    struct helios_vram_reference key={0};
    if(reference && reference->valid) {
        key=*reference;
        if(mode==1 && source_fd>=0) {
            struct stat identity;
            if(fstat(source_fd,&identity) || key.dev!=(uint64_t)identity.st_dev || key.ino!=(uint64_t)identity.st_ino) return -1;
        }
    }
    else {
        struct stat identity;
        if(source_fd<0 || fstat(source_fd,&identity) || !identity.st_ino) return -1;
        key.dev=identity.st_dev;key.ino=identity.st_ino;
        if(uuid) memcpy(key.uuid,uuid,16);
    }
    char path[PATH_MAX];
    if(snprintf(path,sizeof(path),"%s.refs",base)>=(int)sizeof(path)) return -1;
    int fd=open(path,O_RDWR|O_CLOEXEC|O_NOFOLLOW|(mode==2?0:O_CREAT),0600);
    if(fd<0) return mode==2 && errno==ENOENT?0:-1;
    uint64_t release_bytes=0;int64_t release_owner=0;
    int result=-1, found=-1, empty=-1;struct stat file;struct helios_ref_book book;
    if(flock(fd,LOCK_EX) || fstat(fd,&file) || !S_ISREG(file.st_mode) || file.st_nlink!=1 || file.st_uid!=geteuid() || (file.st_mode&077)) goto done;
    memset(&book,0,sizeof(book));
    if(file.st_size && (file.st_size!=(off_t)sizeof(book) || pread(fd,&book,sizeof(book),0)!=(ssize_t)sizeof(book))) goto done;
    if(file.st_size && book.magic!=UINT64_C(0x48454c494f535246)) goto done;
    book.magic=UINT64_C(0x48454c494f535246);
    for(int i=0;i<HELIOS_REF_SLOTS;i++) {
        struct helios_ref_row *r=&book.row[i];
        if(!r->refs && empty<0) empty=i;
        if(r->refs && r->key.dev==key.dev && r->key.ino==key.ino &&
           ((!uuid && !(reference && reference->valid)) || !memcmp(r->key.uuid,key.uuid,16))) {
            if(found>=0) goto done; /* ambiguous identity; retain charges */
            found=i;
        }
    }
    if(mode==0) {
        if(found>=0 || empty<0 || !uuid || !bytes) goto done;
        struct helios_ref_row *r=&book.row[empty];r->key=key;r->key.valid=true;
        r->bytes=bytes;r->owner=getpid();r->refs=2;found=empty;
    } else {
        if(found<0) {result=0;goto done;}
        struct helios_ref_row *r=&book.row[found];
        if(mode==1) {if(r->refs==UINT32_MAX) goto done;r->refs++;}
        else if(mode==2) {
            if(r->refs==1) {release_bytes=r->bytes;release_owner=r->owner;}
            r->refs--;
        } else goto done;
    }
    if(pwrite(fd,&book,sizeof(book),0)!=(ssize_t)sizeof(book)) goto done;
    /* Tombstone before releasing the charge. A failed ledger write must
     * retain memory, never enable a retry to release an unrelated allocation. */
    if(release_bytes && !helios_vram_change_for_pid(book.row[found].key.uuid,0,0,release_bytes,true,NULL,NULL,release_owner)) goto done;
    if(reference && mode!=2) *reference=book.row[found].key;
    if(reference && mode==2) reference->valid=false;
    result=1;
done:
    flock(fd,LOCK_UN);close(fd);return result;
}
#endif
