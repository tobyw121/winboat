/* SPDX-License-Identifier: MIT
 * Compile the actual patched QEMU callbacks against a small protocol fixture.
 * EGL contexts, texture creation/upload/readback/destruction use real Mesa.
 */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <gio/gio.h>
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <pixman.h>
#define CONFIG_GBM 1
#define DBUS_DEFAULT_TIMEOUT 1000
/* Protocol fixture does not take asynchronous GObject references. */
#undef g_object_ref
#define g_object_ref(p) (p)
#define trace_dbus_update_gl(...) ((void)0)
#define DMABUF_MAX_PLANES 4
#define container_of(p,t,m) ((t *)((char *)(p)-G_STRUCT_OFFSET(t,m)))
#define trace_dbus_scanout_texture(...) ((void)0)
#define trace_dbus_gl_gfx_switch(...) ((void)0)
#define QEMU_IS_ALIGNED(a,b) ((a) % (b) == 0)
#define SHARE_KIND_NONE 0

typedef struct DisplaySurface { GLuint texture; uint8_t pixels[64]; } DisplaySurface;
typedef int QemuGLShader;
typedef struct DisplayGLCtx { QemuGLShader *gls; } DisplayGLCtx;
typedef struct DisplayChangeListener { void *con; } DisplayChangeListener;
typedef struct QemuDmaBuf { int unused; } QemuDmaBuf;
typedef struct DBusDisplayListener {
    DisplayChangeListener dcl;
    DisplaySurface *ds;
    int ds_share;
    void *proxy;
    bool software_surface;
    void *scanout_dmabuf_v2_proxy;
    QemuDmaBuf *active_dmabuf;
#ifdef CONFIG_PIXMAN
    pixman_region32_t gl_damage;
#else
    int gl_damage;
#endif
} DBusDisplayListener;
static EGLDisplay qemu_egl_display;
static EGLContext qemu_egl_rn_ctx;
static int diagnostics, baselines, updates, dma_scanouts, exports, closed_fds, dma_updates, disables;
static bool bind_failure, export_failure;
static void error_report(const char *format, ...) { diagnostics++; }
static const char *qemu_egl_get_error_string(void) { return "fixture EGL error"; }
static int qemu_egl_make_context_current(void *unused, EGLContext context) {
    if (bind_failure) return -1;
    return eglMakeCurrent(qemu_egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,context)?0:-1;
}
static void qemu_console_hw_gl_block(void *con, bool block) { }
static void dbus_update_gl_cb(void) { }
static void ddl_discard_display_messages(DBusDisplayListener *ddl) { }
static void qemu_dbus_display1_listener_call_disable(void *proxy,...) { disables++; }
static void qemu_dbus_display1_listener_call_update_dmabuf(void *proxy,...) {
    assert(eglGetCurrentContext()!=EGL_NO_CONTEXT);dma_updates++;
}
static int surface_width(DisplaySurface *s) {return 4;}
static int surface_height(DisplaySurface *s) {return 4;}
static int surface_stride(DisplaySurface *s) {return 16;}
static int surface_bytes_per_pixel(DisplaySurface *s) {return 4;}
static int surface_format(DisplaySurface *s) {return 0;}
static void *surface_data(DisplaySurface *s) {return s->pixels;}
static bool map_format(int format, GLenum *glformat, GLenum *gltype) {
    *glformat=GL_RGBA;*gltype=GL_UNSIGNED_BYTE;return true;
}
static void ddl_scanout(DBusDisplayListener *d) { assert(d->ds);baselines++; }
static void dbus_gfx_update(DisplayChangeListener *d,int x,int y,int w,int h) { updates++; }
static void dbus_scanout_dmabuf_v1(DBusDisplayListener *d,QemuDmaBuf *buf) { dma_scanouts++; }
static void dbus_scanout_dmabuf_v2(DBusDisplayListener *d,QemuDmaBuf *buf) { dma_scanouts++; }
static int qemu_dmabuf_get_num_planes(QemuDmaBuf *buf) {return 1;}
static bool egl_dmabuf_export_texture(uint32_t texture,int *fds,EGLint *offset,EGLint *stride,
                                     EGLint *fourcc,int *planes,uint64_t *modifier) {
    assert(eglGetCurrentContext()==qemu_egl_rn_ctx);
    assert(glIsTexture(texture));exports++;
    *planes=1;*modifier=0;*fourcc=0;fds[0]=-1;offset[0]=0;stride[0]=16;
    return !export_failure;
}
static QemuDmaBuf *qemu_dmabuf_new(unsigned width,...) {return g_new0(QemuDmaBuf,1);}
static void qemu_dmabuf_close(QemuDmaBuf *buf) {closed_fds++;}
G_DEFINE_AUTOPTR_CLEANUP_FUNC(QemuDmaBuf,g_free)
#include "callbacks.inc"

static int damage(DBusDisplayListener *d) {
#ifdef CONFIG_PIXMAN
    return pixman_region32_n_rects(&d->gl_damage);
#else
    return d->gl_damage;
#endif
}
int main(void) {
    EGLint major,minor,count;
    qemu_egl_display=eglGetDisplay(EGL_DEFAULT_DISPLAY);
    assert(eglInitialize(qemu_egl_display,&major,&minor));
    assert(eglBindAPI(EGL_OPENGL_API));
    const EGLint attributes[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_BIT,EGL_NONE};
    EGLConfig config;assert(eglChooseConfig(qemu_egl_display,attributes,&config,1,&count) && count);
    qemu_egl_rn_ctx=eglCreateContext(qemu_egl_display,config,EGL_NO_CONTEXT,NULL);
    EGLContext renderer=eglCreateContext(qemu_egl_display,config,qemu_egl_rn_ctx,NULL);
    assert(qemu_egl_rn_ctx!=EGL_NO_CONTEXT && renderer!=EGL_NO_CONTEXT);
    const EGLint size[]={EGL_WIDTH,2,EGL_HEIGHT,2,EGL_NONE};
    EGLSurface draw=eglCreatePbufferSurface(qemu_egl_display,config,size);
    EGLSurface read=eglCreatePbufferSurface(qemu_egl_display,config,size);
    assert(draw!=EGL_NO_SURFACE && read!=EGL_NO_SURFACE);
    QemuGLShader shader=1;DisplayGLCtx context={.gls=&shader};
    DisplaySurface surface={0};memset(surface.pixels,127,sizeof(surface.pixels));
    /* Vulkan/Venus may leave no EGL context current before a VGA mode switch. */
    assert(eglGetCurrentContext()==EGL_NO_CONTEXT);
    dbus_create_texture(&context,&surface);
    assert(surface.texture && eglGetCurrentContext()==EGL_NO_CONTEXT);
    assert(eglGetCurrentDisplay()==EGL_NO_DISPLAY);
    assert(eglMakeCurrent(qemu_egl_display,draw,read,renderer));
    memset(surface.pixels,63,sizeof(surface.pixels));
    dbus_update_texture(&context,&surface,0,0,4,4);
    assert(eglGetCurrentContext()==renderer && eglGetCurrentSurface(EGL_DRAW)==draw && eglGetCurrentSurface(EGL_READ)==read);
    glBindTexture(GL_TEXTURE_2D,surface.texture);
    uint8_t pixels[48];glGetTexImage(GL_TEXTURE_2D,0,GL_RGB,GL_UNSIGNED_BYTE,pixels);
    for (unsigned i=0;i<sizeof(pixels);i++) assert(pixels[i]==63);
    assert(glGetError()==GL_NO_ERROR);
    DBusDisplayListener listener={0};
    dbus_call_update_gl(&listener.dcl,0,0,4,4);
    assert(dma_updates==1 && eglGetCurrentContext()==renderer);
    assert(eglMakeCurrent(qemu_egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT));
    dbus_call_update_gl(&listener.dcl,0,0,4,4);
    assert(dma_updates==2 && eglGetCurrentContext()==EGL_NO_CONTEXT);
    bind_failure=true;dbus_call_update_gl(&listener.dcl,0,0,4,4);bind_failure=false;
    assert(dma_updates==2 && eglGetCurrentContext()==EGL_NO_CONTEXT);
    assert(eglMakeCurrent(qemu_egl_display,draw,read,renderer));
#ifdef CONFIG_PIXMAN
    pixman_region32_init(&listener.gl_damage);
#endif
    dbus_gl_gfx_switch(&listener.dcl,&surface);
    assert(exports==1 && dma_scanouts==1 && !listener.software_surface);
    assert(eglGetCurrentContext()==renderer && eglGetCurrentSurface(EGL_DRAW)==draw && eglGetCurrentSurface(EGL_READ)==read);
    dbus_gl_gfx_update(&listener.dcl,0,0,2,2);assert(damage(&listener)>0);
    /* Failed export returns through cleanup and preserves the producer. */
    export_failure=true;dbus_gl_gfx_switch(&listener.dcl,&surface);export_failure=false;
    assert(dma_scanouts==1 && diagnostics==1 && eglGetCurrentContext()==renderer);
    DisplaySurface software={0};
    bind_failure=true;dbus_create_texture(&context,&software);bind_failure=false;
    assert(!software.texture && eglGetCurrentContext()==renderer);
    dbus_gl_gfx_update(&listener.dcl,0,0,2,2);assert(damage(&listener)>0);
    dbus_gl_gfx_switch(&listener.dcl,&software);
    assert(baselines==1 && listener.software_surface && damage(&listener)==0);
    dbus_gl_gfx_update(&listener.dcl,0,0,2,2);
    assert(updates==1 && damage(&listener)==0);
    /* A sibling listener may create a texture: keep our software baseline
     * and update transport consistent until this listener switches scanout. */
    dbus_create_texture(&context,&software);
    dbus_gl_gfx_update(&listener.dcl,0,0,2,2);assert(updates==2 && damage(&listener)==0);
    dbus_gl_gfx_switch(&listener.dcl,&software);
    assert(!listener.software_surface && dma_scanouts==2);
    dbus_gl_gfx_update(&listener.dcl,0,0,2,2);assert(damage(&listener)>0);
    dbus_gl_gfx_switch(&listener.dcl,NULL);assert(damage(&listener)==0 && !listener.software_surface);
    dbus_scanout_texture(&listener.dcl,0,false,4,4,0,0,4,4,NULL);
    assert(diagnostics==2 && dma_scanouts==2);
    assert(closed_fds==2);
    /* Real virtio-gpu bind/release ordering: B is current before A retires.
     * Releasing A must not erase B, including repeated rotation to C. */
    QemuDmaBuf first={0},second={0},third={0};
    dbus_scanout_dmabuf(&listener.dcl,&first);
    dbus_scanout_dmabuf(&listener.dcl,&second);
    dbus_release_dmabuf(&listener.dcl,&first);
    assert(disables==0 && listener.active_dmabuf==&second);
    dbus_scanout_dmabuf(&listener.dcl,&third);
    dbus_release_dmabuf(&listener.dcl,&second);
    assert(disables==0 && listener.active_dmabuf==&third);
    dbus_release_dmabuf(&listener.dcl,&third);
    assert(disables==1 && !listener.active_dmabuf);
    dbus_release_dmabuf(&listener.dcl,&third);
    assert(disables==1);
    /* Switching to an exported texture must not retain its temporary wrapper
     * or let the retired native buffer disable the new texture scanout. */
    dbus_scanout_dmabuf(&listener.dcl,&first);
    dbus_scanout_texture(&listener.dcl,surface.texture,false,4,4,0,0,4,4,NULL);
    assert(!listener.active_dmabuf);
    dbus_release_dmabuf(&listener.dcl,&first);assert(disables==1);
    dbus_scanout_dmabuf(&listener.dcl,&first);
    dbus_gl_gfx_switch(&listener.dcl,NULL);
    dbus_release_dmabuf(&listener.dcl,&first);assert(disables==1);
    dbus_destroy_texture(&context,&surface);dbus_destroy_texture(&context,&software);
    assert(!surface.texture && !software.texture && eglGetCurrentContext()==renderer);
    assert(eglMakeCurrent(qemu_egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT));
#ifdef CONFIG_PIXMAN
    pixman_region32_fini(&listener.gl_damage);
#endif
    eglDestroySurface(qemu_egl_display,draw);eglDestroySurface(qemu_egl_display,read);
    eglDestroyContext(qemu_egl_display,renderer);eglDestroyContext(qemu_egl_display,qemu_egl_rn_ctx);
    eglTerminate(qemu_egl_display);
    g_print("QEMU callbacks: real texture upload/readback, EGL context restoration, textureless setup baseline/updates, stale damage clearing and DMA handoff passed.\n");
    return 0;
}
