/* SPDX-License-Identifier: MIT
 * Compile the actual patched QEMU callbacks against a small protocol fixture.
 * EGL contexts, texture creation/upload/readback/destruction use real Mesa.
 */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <string.h>
#include <gio/gio.h>
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <pixman.h>
#define CONFIG_GBM 1
#define CONFIG_LINUX 1
#define DRM_FORMAT_MOD_INVALID UINT64_C(0x00ffffffffffffff)
#define DBUS_DEFAULT_TIMEOUT 1000
/* Protocol fixture does not take asynchronous GObject references. */
#undef g_object_ref
#define g_object_ref(p) (p)
#undef g_object_unref
#define g_object_unref(p) ((void)(p))
#define trace_dbus_update_gl(...) ((void)0)
#define DMABUF_MAX_PLANES 4
#define container_of(p,t,m) ((t *)((char *)(p)-G_STRUCT_OFFSET(t,m)))
#define trace_dbus_scanout_texture(...) ((void)0)
#define trace_dbus_gl_gfx_switch(...) ((void)0)
#define QEMU_IS_ALIGNED(a,b) ((a) % (b) == 0)
#define SHARE_KIND_NONE 0

typedef struct DisplaySurface { GLuint texture; uint8_t pixels[64]; int width,height; } DisplaySurface;
typedef int QemuGLShader;
typedef struct DisplayGLCtx { QemuGLShader *gls; } DisplayGLCtx;
typedef struct DisplayChangeListener { void *con; } DisplayChangeListener;
typedef struct QemuDmaBuf { uint64_t modifier,allocation; bool optimal,top; unsigned width,height; GLuint texture; int fd; } QemuDmaBuf;
typedef struct egl_fb { int width,height,x,y;GLuint texture,framebuffer;bool delete_texture;QemuDmaBuf *dmabuf; } egl_fb;
#define EGL_FB_INIT {0}
typedef struct HeliosVulkanReadback {int unused;} HeliosVulkanReadback;
typedef struct HeliosVulkanReadbackCache {HeliosVulkanReadback image;QemuDmaBuf *active;} HeliosVulkanReadbackCache;
typedef struct DBusDisplayListener {
    DisplayChangeListener dcl;
    DisplaySurface *ds;
    int ds_share;
    void *proxy;
    bool software_surface;
    void *scanout_dmabuf_v2_proxy;
    QemuDmaBuf *active_dmabuf;
    HeliosVulkanReadbackCache *vk_cache;
    HeliosVulkanReadback *vk_readback;
    DisplaySurface *vk_surface;
    bool vk_announced,vk_failed,copy_requested,copy_active;
    uint64_t frame_sequence;
    uint64_t frame_inode;
    uint32_t frame_source;
    int64_t frame_send_us;
    bool frame_software;
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
static bool readback_failure,reply_failure,last_block;
static int software_baselines,software_updates,vulkan_imports;
static GVariant *last_pixels;
static GAsyncReadyCallback pending_callback;
static gpointer pending_opaque;
static int update_rect[4];
static char diagnostic_line[512];
static void error_report(const char *format, ...) {
    diagnostics++;va_list args;va_start(args,format);
    g_vsnprintf(diagnostic_line,sizeof(diagnostic_line),format,args);va_end(args);
}
static const char *qemu_egl_get_error_string(void) { return "fixture EGL error"; }
static int qemu_egl_make_context_current(void *unused, EGLContext context) {
    if (bind_failure) return -1;
    return eglMakeCurrent(qemu_egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,context)?0:-1;
}
static void qemu_console_hw_gl_block(void *con, bool block) {last_block=block;}
static bool qemu_console_is_gl_blocked(void *con) {return last_block;}
static void qemu_console_hw_update(void *con) { }
static void ddl_discard_display_messages(DBusDisplayListener *ddl) { }
static void qemu_dbus_display1_listener_call_disable(void *proxy,...) { disables++; }
static void qemu_dbus_display1_listener_call_update_dmabuf(void *proxy,int x,int y,int w,int h,
    GDBusCallFlags flags,int timeout,GCancellable *cancel,GAsyncReadyCallback cb,gpointer opaque) {
    assert(eglGetCurrentContext()!=EGL_NO_CONTEXT);dma_updates++;
    update_rect[0]=x;update_rect[1]=y;update_rect[2]=w;update_rect[3]=h;
    pending_callback=cb;pending_opaque=opaque;
}
static bool qemu_dbus_display1_listener_call_update_dmabuf_finish(void *proxy,GAsyncResult *result,GError **error) {
    if(reply_failure) {g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_FAILED,"fixture reply error");return false;}
    return true;
}
static int surface_width(DisplaySurface *s) {return s->width?s->width:4;}
static int surface_height(DisplaySurface *s) {return s->height?s->height:4;}
static int surface_stride(DisplaySurface *s) {return surface_width(s)*4;}
static int surface_bytes_per_pixel(DisplaySurface *s) {return 4;}
static int surface_format(DisplaySurface *s) {return 0;}
static void *surface_data(DisplaySurface *s) {return s->pixels;}
static DisplaySurface *qemu_create_displaysurface(unsigned w,unsigned h) {
    assert(w<=4 && h<=4);DisplaySurface *s=g_new0(DisplaySurface,1);s->width=w;s->height=h;return s;
}
static void qemu_free_displaysurface(DisplaySurface *s) {g_free(s);}
static const int *qemu_dmabuf_get_fds(QemuDmaBuf *d,int *count){*count=1;return &d->fd;}
static uint32_t qemu_dmabuf_get_width(QemuDmaBuf *b) {return b->width?b->width:4;}
static uint32_t qemu_dmabuf_get_height(QemuDmaBuf *b) {return b->height?b->height:4;}
static uint32_t qemu_dmabuf_get_source_id(QemuDmaBuf *b) {(void)b;return 4;}
static uint32_t qemu_dmabuf_get_backing_width(QemuDmaBuf *b) {return qemu_dmabuf_get_width(b);}
static uint32_t qemu_dmabuf_get_backing_height(QemuDmaBuf *b) {return qemu_dmabuf_get_height(b);}
static uint32_t qemu_dmabuf_get_x(QemuDmaBuf *b) {(void)b;return 0;}
static uint32_t qemu_dmabuf_get_y(QemuDmaBuf *b) {(void)b;return 0;}
static bool qemu_dmabuf_get_y0_top(QemuDmaBuf *b) {return b->top;}
static void egl_dmabuf_import_texture(QemuDmaBuf *b) {(void)b;}
static GLuint qemu_dmabuf_get_texture(QemuDmaBuf *b) {return b->texture;}
static uint64_t qemu_dmabuf_get_modifier(QemuDmaBuf *b) {return b->modifier;}
static uint64_t qemu_dmabuf_get_allocation_size(QemuDmaBuf *b) {return b->allocation;}
static HeliosVulkanReadbackCache *helios_vulkan_readback_cache_new(void) {return g_new0(HeliosVulkanReadbackCache,1);}
static void helios_vulkan_readback_cache_deactivate(HeliosVulkanReadbackCache *c,QemuDmaBuf *b) {if(c->active==b)c->active=NULL;}
static HeliosVulkanReadback *helios_vulkan_readback_cache_activate(HeliosVulkanReadbackCache *c,QemuDmaBuf *b,bool optimal) {
    assert(optimal);vulkan_imports++;if(!b->optimal)return NULL;c->active=b;return &c->image;
}
static bool helios_vulkan_readback_flush(HeliosVulkanReadback *r,DisplaySurface *s,unsigned x,unsigned y,unsigned w,unsigned h) {
    assert(r && x+w<=(unsigned)surface_width(s) && y+h<=(unsigned)surface_height(s));
    if(readback_failure)return false;
    memset(s->pixels,97,sizeof(s->pixels));return true;
}
static GVariant *fixture_proxy_finish(GDBusProxy *p,GAsyncResult *r,GError **err) {
    if(reply_failure){g_set_error_literal(err,G_IO_ERROR,G_IO_ERROR_FAILED,"fixture rejection");return NULL;}
    return g_variant_ref_sink(g_variant_new("()"));
}
#define g_dbus_proxy_call_finish fixture_proxy_finish
static void record_pixels(GVariant *pixels,GAsyncReadyCallback cb,gpointer opaque) {
    g_clear_pointer(&last_pixels,g_variant_unref);last_pixels=g_variant_ref_sink(pixels);pending_callback=cb;pending_opaque=opaque;
}
static void qemu_dbus_display1_listener_call_scanout(void *p,unsigned w,unsigned h,unsigned stride,unsigned format,GVariant *pixels,
    GDBusCallFlags flags,int timeout,GCancellable *cancel,GAsyncReadyCallback cb,gpointer opaque) {
    software_baselines++;record_pixels(pixels,cb,opaque);
}
static void qemu_dbus_display1_listener_call_update(void *p,int x,int y,int w,int h,unsigned stride,unsigned format,GVariant *pixels,
    GDBusCallFlags flags,int timeout,GCancellable *cancel,GAsyncReadyCallback cb,gpointer opaque) {
    update_rect[0]=x;update_rect[1]=y;update_rect[2]=w;update_rect[3]=h;
    software_updates++;record_pixels(pixels,cb,opaque);
}
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
#ifndef HELIOS_TEST_OLD_NATIVE_ROUTING
    last_block=false;
    int before_damage=dma_updates;
    uint64_t before_sequence=listener.frame_sequence;
    dbus_gl_gfx_update(&listener.dcl,0,0,1,1);
    dbus_gl_gfx_update(&listener.dcl,3,3,1,1);
    dbus_gl_refresh(&listener.dcl);
    assert(dma_updates==before_damage+1 && listener.frame_sequence==before_sequence+1);
    assert(!listener.frame_software && listener.frame_source==4 && last_block);
    assert(update_rect[0]==0 && update_rect[1]==0 && update_rect[2]==4 && update_rect[3]==4);
    g_setenv("HELIOS_FRAME_TRACE","1",true);
    pending_callback(NULL,NULL,pending_opaque);assert(!last_block);
    assert(strstr(diagnostic_line,"frame-ack source=4") && strstr(diagnostic_line,"transport=dmabuf"));
    g_unsetenv("HELIOS_FRAME_TRACE");
#endif
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
    /* MOD_INVALID by itself proves no layout. An unmatched native shape stays
     * on the existing DMA path; only the Vulkan importer's accepted shape may
     * select the immutable software-frame compatibility transport. */
    QemuDmaBuf unknown={.modifier=DRM_FORMAT_MOD_INVALID,.allocation=64};
    dbus_scanout_dmabuf(&listener.dcl,&unknown);
    assert(!listener.vk_readback && vulkan_imports==1);
    QemuDmaBuf optimal={.modifier=DRM_FORMAT_MOD_INVALID,.allocation=64,.optimal=true};
    int previous_dma=dma_scanouts,previous_updates=dma_updates;
    dbus_scanout_dmabuf(&listener.dcl,&optimal);
    assert(listener.vk_readback && dma_scanouts==previous_dma && !listener.vk_announced);
    /* Native GPU consoles need no software surface in QEMU. Damage refresh
     * must use the private Vulkan staging surface in that case. */
    listener.ds=NULL;last_block=false;
    dbus_gl_gfx_update(&listener.dcl,0,0,1,1);
    dbus_gl_gfx_update(&listener.dcl,3,3,1,1);
    dbus_gl_refresh(&listener.dcl);
    assert(software_baselines==1 && software_updates==0 && last_block);
    gsize n;const uint8_t *copy=g_variant_get_fixed_array(last_pixels,&n,1);
    assert(n==64 && copy[0]==97);
    memset(listener.vk_surface->pixels,12,64);
    assert(copy[0]==97); /* queued message owns its pixels */
    pending_callback(NULL,NULL,pending_opaque);assert(!last_block);
    DisplaySurface *canvas=listener.vk_surface;
    QemuDmaBuf replacement=optimal;
    dbus_scanout_dmabuf(&listener.dcl,&replacement);
    dbus_release_dmabuf(&listener.dcl,&optimal);
    assert(listener.vk_readback && listener.vk_surface==canvas && listener.vk_announced);
    dbus_call_update_gl(&listener.dcl,0,0,4,4);
    assert(software_updates==1 && dma_updates==previous_updates);
    pending_callback(NULL,NULL,pending_opaque);
    readback_failure=true;dbus_call_update_gl(&listener.dcl,0,0,4,4);readback_failure=false;
    assert(software_updates==1 && dma_updates==previous_updates && listener.vk_failed && !last_block);
    dbus_call_update_gl(&listener.dcl,0,0,4,4);
    int previous_diagnostics=diagnostics;
    reply_failure=true;pending_callback(NULL,NULL,pending_opaque);reply_failure=false;
    assert(!listener.vk_announced && !last_block && diagnostics>=previous_diagnostics+1);
    dbus_call_update_gl(&listener.dcl,0,0,4,4);assert(software_baselines==2);
    pending_callback(NULL,NULL,pending_opaque);
    g_setenv("HELIOS_READBACK_DAMAGE","1",TRUE);
    dbus_call_update_gl(&listener.dcl,1,2,2,1);
    copy=g_variant_get_fixed_array(last_pixels,&n,1);
    assert(n==8 && copy[0]==97 && update_rect[0]==1 && update_rect[1]==2 && update_rect[2]==2 && update_rect[3]==1);
    memset(canvas->pixels,0,64);assert(copy[0]==97);
    pending_callback(NULL,NULL,pending_opaque);
    readback_failure=true;dbus_call_update_gl(&listener.dcl,1,2,2,1);readback_failure=false;
    dbus_call_update_gl(&listener.dcl,1,2,2,1);
    copy=g_variant_get_fixed_array(last_pixels,&n,1);
    assert(n==64 && update_rect[0]==0 && update_rect[2]==4); /* full repair after missed damage */
    pending_callback(NULL,NULL,pending_opaque);
    g_unsetenv("HELIOS_READBACK_DAMAGE");
    QemuDmaBuf explicit_linear={.allocation=64,.optimal=true};
    int imports=vulkan_imports;
    dbus_scanout_dmabuf(&listener.dcl,&explicit_linear);
    assert(!listener.vk_readback && !listener.vk_surface && !listener.vk_announced && imports==vulkan_imports);
    dbus_release_dmabuf(&listener.dcl,&replacement);
    assert(listener.active_dmabuf==&explicit_linear);
    dbus_call_update_gl(&listener.dcl,0,0,4,4);assert(dma_updates==previous_updates+1);
    /* A copy preference never guesses the native opaque layout. */
    listener.copy_requested=true;
    QemuDmaBuf invalid_layout={.modifier=DRM_FORMAT_MOD_INVALID,.allocation=64,.optimal=false};
    dbus_scanout_dmabuf(&listener.dcl,&invalid_layout);
    assert(!listener.copy_active && !listener.vk_readback);
    /* Real EGL framebuffer readback, both orientations; protocol alone is mocked. */
    GLuint copy_texture;glGenTextures(1,&copy_texture);glBindTexture(GL_TEXTURE_2D,copy_texture);
    uint8_t rows[4][4][4];
    for(int y=0;y<4;y++)for(int x=0;x<4;x++) {
        rows[y][x][0]=y*60;rows[y][x][1]=0;rows[y][x][2]=255-y*60;rows[y][x][3]=255;
    }
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,4,4,0,GL_RGBA,GL_UNSIGNED_BYTE,rows);glFinish();
    explicit_linear.texture=copy_texture;
    for(int top=0;top<=1;top++) {
        explicit_linear.top=top;
        dbus_scanout_dmabuf(&listener.dcl,&explicit_linear);
        assert(listener.copy_active && !listener.vk_readback);
        dbus_call_update_gl(&listener.dcl,0,0,4,4);
        copy=g_variant_get_fixed_array(last_pixels,&n,1);
        assert(n==64 && copy[0]==(top?75:255) && copy[48]==(top?255:75));
        assert(last_block);pending_callback(NULL,NULL,pending_opaque);assert(!last_block);
    }
    previous_updates=software_updates;explicit_linear.texture=0;
    dbus_call_update_gl(&listener.dcl,0,0,4,4);
    assert(software_updates==previous_updates && listener.vk_failed && !last_block);
    glDeleteTextures(1,&copy_texture);listener.copy_requested=false;
    g_clear_pointer(&last_pixels,g_variant_unref);g_free(listener.vk_cache);listener.vk_cache=NULL;
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
    g_print("QEMU callbacks: real Mesa/EGL texture checks, scanout retirement, Vulkan routing fixtures, immutable frame snapshots, ACK/failure handling and DMA handoff passed.\n");
    return 0;
}
