#define _GNU_SOURCE
#include "../helios/host/vram-budget.h"
#include "../helios/host/vram-refs.h"
#include <assert.h>
#include <sys/wait.h>
int main(void) {
    const uint8_t gpu[16]={7};char ledger[]="/tmp/helios-ref-ledger-XXXXXX",buffer[]="/tmp/helios-ref-buffer-XXXXXX";
    int fd=mkstemp(ledger),image=mkstemp(buffer);assert(fd>=0 && image>=0);close(fd);
    assert(!setenv("HELIOS_VRAM_BUDGET_FILE",ledger,1));unsetenv("HELIOS_VRAM_CAP_BYTES");
    assert(helios_vram_change(gpu,1000,1000,600,false,NULL,NULL));
    struct helios_vram_reference owner={0};
    assert(helios_vram_reference_change(gpu,image,&owner,600,0)==1);
    struct helios_vram_reference duplicate={0};
    assert(helios_vram_reference_change(gpu,image,&duplicate,600,0)==-1);
    int ready[2],finish[2];assert(!pipe(ready) && !pipe(finish));
    pid_t child=fork();assert(child>=0);
    if(!child) {
        struct helios_vram_reference imported={0};char token='x';uint64_t used;
        assert(helios_vram_reference_change(gpu,image,&imported,0,1)==1);
        assert(write(ready[1],&token,1)==1);assert(read(finish[0],&token,1)==1);
        assert(helios_vram_change(gpu,1000,1000,0,false,&used,NULL) && used==600);
        assert(helios_vram_reference_change(gpu,-1,&imported,0,2)==1);
        assert(!imported.valid);
        _exit(0);
    }
    char token;assert(read(ready[0],&token,1)==1);
    assert(helios_vram_reference_change(gpu,-1,&owner,0,2)==1); /* Vulkan producer freed */
    assert(helios_vram_reference_change(NULL,image,NULL,0,2)==1); /* exported FD destroyed */
    uint64_t used;assert(helios_vram_change(gpu,1000,1000,0,false,&used,NULL) && used==600);
    assert(!helios_vram_change(gpu,1000,1000,251,false,NULL,NULL));
    assert(write(finish[1],"x",1)==1);int status;
    assert(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
    assert(helios_vram_change(gpu,1000,1000,0,false,&used,NULL) && used==0);
    struct helios_vram_reference unknown={0};assert(helios_vram_reference_change(gpu,image,&unknown,0,1)==0);
    assert(helios_vram_reference_change(NULL,image,NULL,0,2)==0);
    char refs[PATH_MAX];snprintf(refs,sizeof(refs),"%s.refs",ledger);
    fd=open(refs,O_WRONLY|O_TRUNC);assert(fd>=0);assert(write(fd,"bad",3)==3);close(fd);
    assert(helios_vram_reference_change(gpu,image,&unknown,0,1)==-1);
    close(image);unlink(buffer);unlink(refs);unlink(ledger);
    for(int i=0;i<2;i++){close(ready[i]);close(finish[i]);}
    puts("Producer/FD release retains DMA-BUF charge until the last cross-process import; unknown/corrupt identities refused.");
}
