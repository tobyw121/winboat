/* Exercise the installed QEMU wrapper and real renderer-server fork/exec.
 * No GPU, GL context, KVM or Windows is needed. */
#include <dlfcn.h>
#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *marker = "/tmp/winboat-render-server.pid";
static void cleanup(void) { unlink(marker); }

int main(void)
{
    void *library = dlopen("libvirglrenderer.so.1", RTLD_NOW);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    int (*init)(void *, int, void *) = dlsym(library, "virgl_renderer_init");
    void (*fini)(void *) = dlsym(library, "virgl_renderer_cleanup");
    if (!init || !fini) return 1;
    /* Callback ABI v1: no GL callbacks are needed with NO_VIRGL. */
    struct { int version; void *callbacks[8]; } callbacks = { .version = 1 };
    FILE *file = fopen(marker, "w");
    if (!file) return 1;
    fprintf(file, "%d\n", getpid());
    fclose(file);
    /* Like QEMU's exit notifier: a failed renderer exec must not run this
     * inherited handler in a child and unlink a still-running parent's PID. */
    atexit(cleanup);
    int result = init(NULL, (1 << 7) | (1 << 9), &callbacks);
    int found_server = 0;
    for (int attempt = 0; attempt < 40 && !found_server; attempt++) {
        char path[PATH_MAX], executable[PATH_MAX];
        /* Some container kernels do not implement task/<tid>/children. */
        DIR *processes = opendir("/proc");
        if (processes) {
            struct dirent *entry;
            while ((entry = readdir(processes))) {
                if (!entry->d_name[0] || strspn(entry->d_name, "0123456789") != strlen(entry->d_name)) continue;
                snprintf(path, sizeof(path), "/proc/%s/exe", entry->d_name);
                ssize_t size = readlink(path, executable, sizeof(executable) - 1);
                if (size < 0) continue;
                executable[size] = 0;
                if (!strcmp(executable, "/opt/helios/renderer/libexec/virgl_render_server"))
                    found_server = 1;
            }
            closedir(processes);
        }
        usleep(50000);
    }
    int preserved = access(marker, F_OK) == 0;
    fini(NULL);
    if (result || !found_server || !preserved) {
        fprintf(stderr, "Renderer startup failed: init=%d server=%d pidfile=%d\n",
                result, found_server, preserved);
        return 1;
    }
    puts("Paired renderer server exec succeeded; parent PID file preserved.");
    return 0;
}
