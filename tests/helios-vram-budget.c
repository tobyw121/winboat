#define _GNU_SOURCE
#include "../helios/host/vram-budget.h"
#include <assert.h>
#include <sys/wait.h>
#include <stdio.h>
#include <pthread.h>
static const uint8_t gpu[16] = {1}, other_gpu[16] = {2};
static void *thread_reserve(void *arg) {
    (void)arg;
    for (int i=0;i<100;i++) {
        assert(helios_vram_change(gpu,10000,10000,1,false,NULL,NULL));
        assert(helios_vram_change(gpu,0,0,1,true,NULL,NULL));
    }
    return NULL;
}
int main(void) {
    unsetenv("HELIOS_VRAM_CAP_BYTES");
    assert(helios_vram_cap(8192,8192)==6963);
    assert(helios_vram_cap(1000,800)==650);
    assert(helios_vram_cap(1000,100)==0);
    assert(helios_vram_cap(UINT64_MAX,UINT64_MAX)<UINT64_MAX);
    char path[]="/tmp/helios-vram-test-XXXXXX";
    int fd=mkstemp(path);assert(fd>=0);close(fd);
    assert(setenv("HELIOS_VRAM_BUDGET_FILE",path,1)==0);
    uint64_t used=0,cap=0;
    assert(helios_vram_change(gpu,1000,1000,600,false,&used,&cap));assert(cap==850);
    pid_t child=fork();assert(child>=0);
    if (!child) {
        assert(!helios_vram_change(gpu,1000,1000,251,false,&used,&cap));assert(used==600);
        assert(helios_vram_change(gpu,1000,1000,250,false,NULL,NULL));
        assert(helios_vram_change(gpu,0,0,250,true,NULL,NULL));
        assert(!helios_vram_change(gpu,0,0,1,true,NULL,NULL)); /* cannot release parent's reservation */
        _exit(0);
    }
    int status;assert(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
    assert(!helios_vram_change(gpu,1000,700,1,false,&used,&cap));assert(used==600 && cap==550);
    assert(helios_vram_change(other_gpu,1000,1000,800,false,NULL,NULL));
    assert(helios_vram_change(other_gpu,0,0,800,true,NULL,NULL));
    assert(helios_vram_change(gpu,0,0,600,true,NULL,NULL));
    assert(!helios_vram_change(gpu,0,0,1,true,NULL,NULL));
    pthread_t threads[4];
    for(int i=0;i<4;i++) assert(!pthread_create(&threads[i],NULL,thread_reserve,NULL));
    for(int i=0;i<4;i++) assert(!pthread_join(threads[i],NULL));
    assert(helios_vram_change(gpu,1000,1000,0,false,&used,&cap) && used==0);
    setenv("HELIOS_VRAM_CAP_BYTES","50",1);
    assert(!helios_vram_change(gpu,1000,1000,51,false,NULL,NULL));
    assert(helios_vram_change(gpu,1000,1000,50,false,NULL,NULL));
    assert(helios_vram_change(gpu,0,0,50,true,NULL,NULL));
    setenv("HELIOS_VRAM_CAP_BYTES","bad",1);
    assert(!helios_vram_change(gpu,1000,1000,1,false,NULL,NULL));
    unsetenv("HELIOS_VRAM_CAP_BYTES");
    /* Refuse corrupt, insecure and symlink ledgers; never silently disable the cap. */
    fd=open(path,O_WRONLY|O_TRUNC);assert(fd>=0);assert(write(fd,"bad",3)==3);close(fd);
    assert(!helios_vram_change(gpu,1000,1000,1,false,NULL,NULL));
    assert(chmod(path,0666)==0);assert(!helios_vram_change(gpu,1000,1000,1,false,NULL,NULL));
    char link[128];snprintf(link,sizeof(link),"%s-link",path);assert(!symlink(path,link));
    setenv("HELIOS_VRAM_BUDGET_FILE",link,1);assert(!helios_vram_change(gpu,1000,1000,1,false,NULL,NULL));
    unlink(link);unlink(path);
    puts("85% cap, live pressure, worker sharing, thread serialization, release ownership and corrupt-ledger refusal passed.");
}
