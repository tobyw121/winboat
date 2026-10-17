/* SPDX-License-Identifier: MIT
 * Local QEMU Display1 client. DMA-BUF imports use one GPU presentation copy;
 * UpdateDMABUF is acknowledged only after the source has finished being read.
 */
/* Keep the GTK 4.8 API baseline when compiling with newer GTK headers. */
#ifndef GDK_VERSION_MIN_REQUIRED
#define GDK_VERSION_MIN_REQUIRED GDK_VERSION_4_8
#endif
#include <gtk/gtk.h>
#include <gio/gunixfdlist.h>
#include <glib-unix.h>
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdint.h>
#include <math.h>
#include <string.h>
#include <signal.h>

#define VM "/org/qemu/Display1/VM"
#define CONSOLE_PREFIX "/org/qemu/Display1/Console_"
#define LISTENER "/org/qemu/Display1/Listener"
#define IFACE "org.qemu.Display1."
#define MAX_DIM 8192u
#define MAX_BYTES (128u * 1024u * 1024u)
/* DRM_FORMAT_MOD_INVALID: vendor NONE and the reserved 56-bit value. */
#define MOD_INVALID UINT64_C(0x00ffffffffffffff)

static const char xml[] =
 "<node><interface name='" IFACE "Listener'>"
 "<method name='Scanout'><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='ay' direction='in'/></method>"
 "<method name='Update'><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='ay' direction='in'/></method>"
 "<method name='ScanoutDMABUF'><arg type='h' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='t' direction='in'/><arg type='b' direction='in'/></method>"
 "<method name='UpdateDMABUF'><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
 "<method name='Disable'/><method name='MouseSet'><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
 "<method name='CursorDefine'><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='ay' direction='in'/></method>"
 "<property name='Interfaces' type='as' access='read'/></interface>"
 "<interface name='" IFACE "Listener.Unix.ScanoutDMABUF2'><method name='ScanoutDMABUF2'>"
 "<arg type='ah' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/>"
 "<arg type='au' direction='in'/><arg type='au' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='u' direction='in'/><arg type='t' direction='in'/><arg type='b' direction='in'/>"
 "</method></interface></node>";

typedef struct Viewer Viewer;
struct Viewer {
 GtkWidget *window, *area, *waiting, *status;
 char *screenshot_path;
 GMainLoop *loop;
 GDBusConnection *bus, *peer;
 GDBusProxy *mouse;
 GDBusNodeInfo *info;
 GdkCursor *cursor;
 GLuint program, vao, texture, source, fbo;
 EGLImageKHR image;
 EGLDisplay display;
 guint width, height, resize_timer, requested_width, requested_height;
 gboolean auto_resize, stretch, resize_failed, last_dma;
 guint64 resize_requests;
 guint32 qemu_uid;
 float rect[4];
 gboolean flip, source_flip, ready, registered, cache_valid, held[256], buttons[7], have_position;
 double last_x, last_y;
 guint64 dma_frames, software_frames, rendered_frames;
 int exit_code;
 /* One frame cache/listener per graphical console; only the root owns the UI.
  * Keeping listeners alive lets a driver handoff happen without restarting QEMU. */
 Viewer *parent, *active;
 GPtrArray *consoles;
 char *console_path;
 guint console_id, pending_consoles, reconnect_timer;
 gboolean accelerated, seen_update, cursor_visible, awaiting_scanout;
 guint recovery_attempt;
 char frame_problem[256];
 gint helios_health, basic_health; /* 0 unknown, 1 running, 2 unavailable */
 gint64 health_at;
 guint health_watch, health_timer;
};
static Viewer *displayed(Viewer *v) {return v->active?v->active:v;}
static void update_cursor(Viewer *v) {
 if (v->parent && v->parent->active!=v) return;
 Viewer *d=displayed(v);
 if (d->cursor_visible && d->cursor) gtk_widget_set_cursor(v->area,d->cursor);
 else gtk_widget_set_cursor_from_name(v->area,d->cursor_visible?"default":"none");
}
static void select_console(Viewer *v);
static void refresh_scanout(Viewer *v);
static gboolean request_resize(gpointer data);

static gboolean external_only(GDBusAuthObserver *observer,const char *mechanism,gpointer data) {
 (void)observer;(void)data;return !strcmp(mechanism,"EXTERNAL");
}
static gboolean authorize_qemu(GDBusAuthObserver *observer,GIOStream *stream,GCredentials *credentials,gpointer data) {
 (void)observer;(void)stream;Viewer *v=data;GError *error=NULL;
 if (!credentials) return FALSE;
 uid_t uid=g_credentials_get_unix_user(credentials,&error);
 gboolean allowed=!error && uid==v->qemu_uid;
 g_clear_error(&error);return allowed;
}

static void fatal(Viewer *v, const char *message) {
 if (v->parent) v=v->parent;
 g_printerr("Helios viewer: %s\n", message);
 v->exit_code = 1;
 g_main_loop_quit(v->loop);
}
static gboolean dimensions(guint w, guint h) {
 return w && h && w <= MAX_DIM && h <= MAX_DIM && (guint64)w*h*4 <= MAX_BYTES;
}
static gboolean region(Viewer *v, gint x, gint y, gint w, gint h) {
 return x >= 0 && y >= 0 && w > 0 && h > 0 && (guint64)x+w <= v->width && (guint64)y+h <= v->height;
}
static guint qnum(guint code) {
 guint key = code >= 8 ? code-8 : 0;
 if (key > 0 && key <= 88) return key;
 switch (key) {
 case 96:return 0x9c; case 97:return 0x9d; case 98:return 0xb5;
 case 99:return 0xb7; case 100:return 0xb8; case 102:return 0xc7;
 case 103:return 0xc8; case 104:return 0xc9; case 105:return 0xcb;
 case 106:return 0xcd; case 107:return 0xcf; case 108:return 0xd0;
 case 109:return 0xd1; case 110:return 0xd2; case 111:return 0xd3;
 case 125:return 0xdb; case 126:return 0xdc; case 127:return 0xdd;
 default:return 0;
 }
}
static void input(Viewer *v, const char *iface, const char *method, GVariant *args) {
 Viewer *d=displayed(v);
 if (!d->console_path) return;
 g_dbus_connection_call(v->bus,"org.qemu",d->console_path,iface,method,args,NULL,
                        G_DBUS_CALL_FLAGS_NONE,2000,NULL,NULL,NULL);
}
static void release_input(Viewer *v) {
 if (!v->bus) return;
 for (guint i=1;i<256;i++) if (v->held[i]) {
  input(v,IFACE "Keyboard","Release",g_variant_new("(u)",i)); v->held[i]=FALSE;
 }
 for (guint i=0;i<7;i++) if (v->buttons[i]) {
  input(v,IFACE "Mouse","Release",g_variant_new("(u)",i)); v->buttons[i]=FALSE;
 }
 v->have_position=FALSE;
}
static gboolean key_press(GtkEventControllerKey *controller, guint value, guint code, GdkModifierType state, Viewer *v) {
 (void)controller;
 if (value==GDK_KEY_Return && (state&(GDK_CONTROL_MASK|GDK_ALT_MASK))==(GDK_CONTROL_MASK|GDK_ALT_MASK)) {
  release_input(v);
  if (gtk_window_is_fullscreen(GTK_WINDOW(v->window))) gtk_window_unfullscreen(GTK_WINDOW(v->window));
  else gtk_window_fullscreen(GTK_WINDOW(v->window));
  return TRUE;
 }
 guint n=qnum(code);
 if (!n) return FALSE;
 if (!v->held[n]) input(v,IFACE "Keyboard","Press",g_variant_new("(u)",n));
 v->held[n]=TRUE; return TRUE;
}
static void key_release(GtkEventControllerKey *controller, guint value, guint code, GdkModifierType state, Viewer *v) {
 (void)controller;(void)value;(void)state;
 guint n=qnum(code);
 if (n && v->held[n]) {input(v,IFACE "Keyboard","Release",g_variant_new("(u)",n));v->held[n]=FALSE;}
}
static void focus_leave(GtkEventControllerFocus *controller, Viewer *v) {(void)controller;release_input(v);}
static void viewport(Viewer *v, int w, int h, int *x, int *y, int *dw, int *dh) {
 if (v->stretch) {*x=0;*y=0;*dw=w;*dh=h;return;}
 Viewer *d=displayed(v);
 double scale=MIN((double)w/MAX(d->width,1u),(double)h/MAX(d->height,1u));
 *dw=MAX(1,(int)(d->width*scale));*dh=MAX(1,(int)(d->height*scale));
 *x=(w-*dw)/2;*y=(h-*dh)/2;
}
static void motion(GtkEventControllerMotion *controller, double x, double y, Viewer *v) {
 (void)controller;
 Viewer *d=displayed(v);
 if (!d->width || !d->height) return;
 int ox,oy,w,h;viewport(v,gtk_widget_get_width(v->area),gtk_widget_get_height(v->area),&ox,&oy,&w,&h);
 if (x<ox || y<oy || x>=ox+w || y>=oy+h) {v->have_position=FALSE;return;}
 GVariant *mode=g_dbus_proxy_get_cached_property(d->mouse,"IsAbsolute");
 gboolean absolute=mode && g_variant_get_boolean(mode);
 if (mode) g_variant_unref(mode);
 if (absolute) input(v,IFACE "Mouse","SetAbsPosition",g_variant_new("(uu)",
   (guint)((x-ox)*d->width/w),(guint)((y-oy)*d->height/h)));
 else if (v->have_position) input(v,IFACE "Mouse","RelMotion",g_variant_new("(ii)",(int)(x-v->last_x),(int)(y-v->last_y)));
 v->last_x=x;v->last_y=y;v->have_position=TRUE;
}
static void click(GtkGestureClick *gesture, int count, double x, double y, Viewer *v) {
 (void)count;
 guint b=gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
 int n=b==1?0:b==2?1:b==3?2:b==8?5:b==9?6:-1;
 if (n<0) return;
 gtk_widget_grab_focus(v->area);
 gboolean pressed=gdk_event_get_event_type(gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(gesture)))==GDK_BUTTON_PRESS;
 if (pressed) {
  int ox,oy,w,h;viewport(v,gtk_widget_get_width(v->area),gtk_widget_get_height(v->area),&ox,&oy,&w,&h);
  if (!displayed(v)->cache_valid || x<ox || y<oy || x>=ox+w || y>=oy+h) return;
  motion(NULL,x,y,v);
 }
 input(v,IFACE "Mouse",pressed?"Press":"Release",g_variant_new("(u)",(guint)n));v->buttons[n]=pressed;
}
static gboolean scroll(GtkEventControllerScroll *controller, double dx, double dy, Viewer *v) {
 (void)controller;(void)dx;
 guint b=dy<0?3:4;
 for (int i=0;i<MIN(8,(int)ceil(fabs(dy)));i++) {
  input(v,IFACE "Mouse","Press",g_variant_new("(u)",b));input(v,IFACE "Mouse","Release",g_variant_new("(u)",b));
 }
 return TRUE;
}
static GLuint shader(GLenum type,const char *text) {
 GLuint s=glCreateShader(type);glShaderSource(s,1,&text,NULL);glCompileShader(s);
 GLint ok;glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
 if (!ok) {glDeleteShader(s);return 0;}return s;
}
static GtkWidget *display_area(void) {
 GtkWidget *area=gtk_gl_area_new();
 /* GTK 4.12+ allows GLES by default, but our shaders and BGRA uploads use
  * desktop OpenGL. Select it explicitly, also when built against GTK 4.8.
  * set_use_es(FALSE) alone is a no-op with the newer mixed-API default. */
 if (g_object_class_find_property(G_OBJECT_GET_CLASS(area),"allowed-apis"))
  g_object_set(area,"allowed-apis",GDK_GL_API_GL,NULL);
 else g_object_set(area,"use-es",FALSE,NULL);
 gtk_gl_area_set_required_version(GTK_GL_AREA(area),3,3);
 return area;
}
static void add_gtk_flag(const char *name,const char *flag) {
 const char *previous=g_getenv(name);
 char **flags=g_strsplit_set(previous?previous:"",",:; \t",-1);
 gboolean present=FALSE;
 for (guint i=0;flags[i];i++) present|=!strcmp(flags[i],flag);
 g_strfreev(flags);
 if (!present) {
  char *value=previous && *previous?g_strconcat(previous,",",flag,NULL):g_strdup(flag);
  g_setenv(name,value,TRUE);g_free(value);
 }
}
static void desktop_gl(void) {
 /* DMA-BUF import requires an EGL context. A valid GLX desktop GL context
  * passed our old preflight but can never satisfy eglGetCurrentDisplay(). */
 if (!gtk_check_version(4,16,0)) {
  add_gtk_flag("GDK_DISABLE","gles-api");add_gtk_flag("GDK_DISABLE","glx");
 } else {
  add_gtk_flag("GDK_DEBUG","gl-egl");
  if (!gtk_check_version(4,14,0)) add_gtk_flag("GDK_DEBUG","gl-disable-gles");
 }
}
static void draw(Viewer *v, GLuint texture, const float *rect, gboolean flip) {
 glUseProgram(v->program);glBindVertexArray(v->vao);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,texture);
 glUniform1i(glGetUniformLocation(v->program,"image"),0);
 glUniform4fv(glGetUniformLocation(v->program,"rect"),1,rect);
 glUniform1i(glGetUniformLocation(v->program,"flip"),flip);glDrawArrays(GL_TRIANGLES,0,3);
}
static gboolean save_screenshot(Viewer *v,const char *path) {
 int scale=gtk_widget_get_scale_factor(v->area),w=gtk_widget_get_width(v->area)*scale,h=gtk_widget_get_height(v->area)*scale;
 if (!displayed(v)->cache_valid || !dimensions(w,h)) return FALSE;
 /* Explicit screenshots alone read back pixels; normal DMA-BUF rendering does not. */
 GdkPixbuf *pixels=gdk_pixbuf_new(GDK_COLORSPACE_RGB,FALSE,8,w,h);
 if (!pixels) return FALSE;
 glPixelStorei(GL_PACK_ALIGNMENT,4);
 glReadPixels(0,0,w,h,GL_RGB,GL_UNSIGNED_BYTE,gdk_pixbuf_get_pixels(pixels));
 if (glGetError()!=GL_NO_ERROR) {g_object_unref(pixels);return FALSE;}
 GdkPixbuf *flipped=gdk_pixbuf_flip(pixels,FALSE);g_object_unref(pixels);
 if (!flipped) return FALSE;
 GError *error=NULL;gboolean ok=gdk_pixbuf_save(flipped,path,"png",&error,NULL);
 if (error) {g_printerr("Screenshot: %s\n",error->message);g_error_free(error);}
 g_object_unref(flipped);return ok;
}
static gboolean render(GtkGLArea *area,GdkGLContext *context,Viewer *v) {
 (void)area;(void)context;
 Viewer *d=displayed(v);
 gtk_widget_set_visible(v->waiting,!d->width || !d->cache_valid);
 int scale=gtk_widget_get_scale_factor(v->area), x,y,w,h;
 glDisable(GL_BLEND);glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
 viewport(v,gtk_widget_get_width(v->area)*scale,gtk_widget_get_height(v->area)*scale,&x,&y,&w,&h);
 glViewport(x,y,w,h);
 if (d->texture && d->width && d->cache_valid) {
  const float rect[]={0,0,1,1};draw(v,d->texture,rect,d->flip);v->rendered_frames++;
 }
 if (glGetError()!=GL_NO_ERROR) fatal(v,"OpenGL window rendering failed.");
 if (v->screenshot_path) {
  gtk_label_set_text(GTK_LABEL(v->status),save_screenshot(v,v->screenshot_path)?"Screenshot saved.":"Screenshot could not be saved; no active frame or file error.");
  g_clear_pointer(&v->screenshot_path,g_free);
 }
 return TRUE;
}
static void discard_source(Viewer *v) {
 if (v->source) {glDeleteTextures(1,&v->source);v->source=0;}
 if (v->image!=EGL_NO_IMAGE_KHR) {eglDestroyImageKHR(v->display,v->image);v->image=EGL_NO_IMAGE_KHR;}
}
static void texture_size(Viewer *v,guint w,guint h) {
 v->width=w;v->height=h;v->cache_valid=FALSE;v->seen_update=FALSE;glBindTexture(GL_TEXTURE_2D,v->texture);
 glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,w,h,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
}
static void dma_geometry(Viewer *v,guint x,guint y,guint w,guint h,guint bw,guint bh,gboolean top) {
 texture_size(v,w,h);
 v->rect[0]=(float)x/bw;v->rect[1]=(float)y/bh;v->rect[2]=(float)w/bw;v->rect[3]=(float)h/bh;
 /* Match QEMU's egl_fb_blit(..., !y0_top): its display-origin flag is
  * opposite to the vertical flip needed by our bottom-up GL coordinates. */
 v->source_flip=!top;
}
static gboolean import_dma(Viewer *v,GDBusMethodInvocation *inv,GVariant *handles,
 guint x,guint y,guint w,guint h,GVariant *offsets,GVariant *strides,guint planes,
 guint fourcc,guint bw,guint bh,guint64 modifier,gboolean top) {
 const guint rgb[]={0x34325258,0x34325241,0x34324258,0x34324241};
 gboolean known=FALSE;for (guint i=0;i<G_N_ELEMENTS(rgb);i++) known|=fourcc==rgb[i];
 g_snprintf(v->frame_problem,sizeof(v->frame_problem),"DMA-BUF geometry/format invalid: fourcc=0x%08x, backing=%ux%u, crop=%u,%u %ux%u, planes=%u",fourcc,bw,bh,x,y,w,h,planes);
 if (!known || !dimensions(bw,bh) || !dimensions(w,h) || (guint64)x+w>bw || (guint64)y+h>bh || !planes || planes>4
  || g_variant_n_children(handles)!=planes || g_variant_n_children(offsets)!=planes || g_variant_n_children(strides)!=planes) return FALSE;
 g_strlcpy(v->frame_problem,"DMA-BUF import requires an EGL context with EGL_EXT_image_dma_buf_import and GL_OES_EGL_image",sizeof(v->frame_problem));
 v->display=eglGetCurrentDisplay();
 if (v->display==EGL_NO_DISPLAY || !epoxy_has_egl_extension(v->display,"EGL_EXT_image_dma_buf_import")
     || !epoxy_has_gl_extension("GL_OES_EGL_image")) return FALSE;
 gboolean mods=epoxy_has_egl_extension(v->display,"EGL_EXT_image_dma_buf_import_modifiers");
 g_snprintf(v->frame_problem,sizeof(v->frame_problem),"DMA-BUF modifier unsupported: 0x%016" G_GINT64_MODIFIER "x",modifier);
 if (!mods && modifier!=0 && modifier!=MOD_INVALID) return FALSE;
 GUnixFDList *list=g_dbus_message_get_unix_fd_list(g_dbus_method_invocation_get_message(inv));
 if (!list) {g_strlcpy(v->frame_problem,"DMA-BUF descriptors missing",sizeof(v->frame_problem));return FALSE;}
 const EGLint fdkeys[]={EGL_DMA_BUF_PLANE0_FD_EXT,EGL_DMA_BUF_PLANE1_FD_EXT,EGL_DMA_BUF_PLANE2_FD_EXT,EGL_DMA_BUF_PLANE3_FD_EXT};
 const EGLint offkeys[]={EGL_DMA_BUF_PLANE0_OFFSET_EXT,EGL_DMA_BUF_PLANE1_OFFSET_EXT,EGL_DMA_BUF_PLANE2_OFFSET_EXT,EGL_DMA_BUF_PLANE3_OFFSET_EXT};
 const EGLint pitchkeys[]={EGL_DMA_BUF_PLANE0_PITCH_EXT,EGL_DMA_BUF_PLANE1_PITCH_EXT,EGL_DMA_BUF_PLANE2_PITCH_EXT,EGL_DMA_BUF_PLANE3_PITCH_EXT};
 EGLint attrs[64]={EGL_WIDTH,(EGLint)bw,EGL_HEIGHT,(EGLint)bh,EGL_LINUX_DRM_FOURCC_EXT,(EGLint)fourcc};
 int n=6,fds[4]={-1,-1,-1,-1};gboolean ok=TRUE;
 for (guint p=0;p<planes;p++) {
  gint32 handle;guint32 offset,stride;
  g_variant_get_child(handles,p,"h",&handle);g_variant_get_child(offsets,p,"u",&offset);g_variant_get_child(strides,p,"u",&stride);
  fds[p]=g_unix_fd_list_get(list,handle,NULL);
  if (fds[p]<0 || !stride || stride>INT32_MAX || offset>INT32_MAX) {ok=FALSE;break;}
  attrs[n++]=fdkeys[p];attrs[n++]=fds[p];attrs[n++]=offkeys[p];attrs[n++]=(EGLint)offset;attrs[n++]=pitchkeys[p];attrs[n++]=(EGLint)stride;
  if (mods && modifier!=MOD_INVALID) {
   attrs[n++]=EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT+2*p;attrs[n++]=(EGLint)modifier;
   attrs[n++]=EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT+2*p;attrs[n++]=(EGLint)(modifier>>32);
  }
 }
 attrs[n]=EGL_NONE;
 EGLImageKHR image=ok?eglCreateImageKHR(v->display,EGL_NO_CONTEXT,EGL_LINUX_DMA_BUF_EXT,NULL,attrs):EGL_NO_IMAGE_KHR;
 for (guint p=0;p<planes;p++) if (fds[p]>=0) close(fds[p]);
 if (image==EGL_NO_IMAGE_KHR) {g_snprintf(v->frame_problem,sizeof(v->frame_problem),"EGL DMA-BUF import failed: egl=0x%04x, fourcc=0x%08x, modifier=0x%016" G_GINT64_MODIFIER "x",eglGetError(),fourcc,modifier);return FALSE;}
 discard_source(v);v->image=image;glGenTextures(1,&v->source);glBindTexture(GL_TEXTURE_2D,v->source);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
 glEGLImageTargetTexture2DOES(GL_TEXTURE_2D,image);
 if (glGetError()!=GL_NO_ERROR) {g_strlcpy(v->frame_problem,"OpenGL could not bind the imported EGL image",sizeof(v->frame_problem));discard_source(v);return FALSE;}
 dma_geometry(v,x,y,w,h,bw,bh,top);v->frame_problem[0]=0;return TRUE;
}
static gboolean copy_dma(Viewer *v) {
 if (!v->source) return FALSE;
 GLint previous;glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&previous);
 glBindFramebuffer(GL_DRAW_FRAMEBUFFER,v->fbo);glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,v->texture,0);
 if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE) {glBindFramebuffer(GL_DRAW_FRAMEBUFFER,previous);return FALSE;}
 glViewport(0,0,v->width,v->height);glDisable(GL_BLEND);draw(v,v->source,v->rect,v->source_flip);
 /* QEMU blocks its GL console until UpdateDMABUF returns. Finish source reads
  * before ACK; redraws only sample our own texture, never a released scanout.
  * Producer completion still relies on the protocol/driver's implicit sync.
  */
 glFinish();glBindFramebuffer(GL_DRAW_FRAMEBUFFER,previous);v->flip=FALSE;
 v->cache_valid=glGetError()==GL_NO_ERROR;return v->cache_valid;
}
static void report_display_recovery(Viewer *v,const char *message) {
 char *reason=g_strescape(message,NULL);
 g_print("{\"event\":\"display-recovery\",\"console\":%u,\"accelerated\":%s,\"reason\":\"%s\"}\n",v->console_id,v->accelerated?"true":"false",reason);
 fflush(stdout);g_free(reason);
}
static void method(GDBusConnection *conn,const gchar *sender,const gchar *path,const gchar *iface,
 const gchar *name,GVariant *params,GDBusMethodInvocation *inv,gpointer data) {
 (void)conn;(void)sender;(void)path;(void)iface;
 Viewer *v=data;gboolean ok=TRUE;
 gboolean scanout=!strcmp(name,"Scanout") || !strcmp(name,"ScanoutDMABUF") || !strcmp(name,"ScanoutDMABUF2");
 gboolean update=!strcmp(name,"Update") || !strcmp(name,"UpdateDMABUF");
 gboolean frame=scanout || update || !strcmp(name,"Disable");
 if (update && v->awaiting_scanout) {
  /* Acknowledge/drop queued updates while QEMU republishes the baseline.
   * No producer buffer is read or displayed in this state. */
  g_dbus_method_invocation_return_value(inv,NULL);return;
 }
 g_strlcpy(v->frame_problem,"Invalid adapter frame",sizeof(v->frame_problem));
 gtk_gl_area_make_current(GTK_GL_AREA(v->area));
 if (gtk_gl_area_get_error(GTK_GL_AREA(v->area))) ok=FALSE;
 else if (!strcmp(name,"Scanout") || !strcmp(name,"Update")) {
  gint x=0,y=0,w,h;guint stride,format;GVariant *pixels;
  gboolean initial=!strcmp(name,"Scanout");
  if (initial) {
   guint sw,sh;g_variant_get(params,"(uuuu@ay)",&sw,&sh,&stride,&format,&pixels);
   w=sw<=MAX_DIM?(gint)sw:0;h=sh<=MAX_DIM?(gint)sh:0;
  }
  else g_variant_get(params,"(iiiiuu@ay)",&x,&y,&w,&h,&stride,&format,&pixels);
  gsize len;const void *bytes=g_variant_get_fixed_array(pixels,&len,1);
  ok=dimensions(w,h) && stride%4==0 && (guint64)stride>=(guint64)w*4 && (guint64)stride*h<=len && len<=MAX_BYTES
     && (format==0x20020888 || format==0x20028888 || format==0x20030888 || format==0x20038888);
  if (ok && initial) {discard_source(v);texture_size(v,w,h);}
  ok=ok && !v->source && region(v,x,y,w,h);
  if (!ok) g_printerr("%s: region=%d,%d %dx%d, stride=%u, pixman=0x%08x, bytes=%zu, scanout=%ux%u\n",
                     name,x,y,w,h,stride,format,(size_t)len,v->width,v->height);
  if (ok) {
   glBindTexture(GL_TEXTURE_2D,v->texture);glPixelStorei(GL_UNPACK_ROW_LENGTH,stride/4);
   glTexSubImage2D(GL_TEXTURE_2D,0,x,y,w,h,(format&0x000f0000)==0x00020000?GL_BGRA:GL_RGBA,GL_UNSIGNED_BYTE,bytes);
   glPixelStorei(GL_UNPACK_ROW_LENGTH,0);v->flip=TRUE;v->cache_valid=TRUE;v->software_frames++;v->last_dma=FALSE;
  }
  g_variant_unref(pixels);
 } else if (!strcmp(name,"ScanoutDMABUF")) {
  gint handle;guint w,h,stride,fourcc;guint64 mod;gboolean top;
  g_variant_get(params,"(huuuutb)",&handle,&w,&h,&stride,&fourcc,&mod,&top);
  GVariant *handles=g_variant_ref_sink(g_variant_new_fixed_array(G_VARIANT_TYPE_HANDLE,&handle,1,sizeof(handle)));
  guint offset=0;
  GVariant *offsets=g_variant_ref_sink(g_variant_new_fixed_array(G_VARIANT_TYPE_UINT32,&offset,1,sizeof(offset)));
  GVariant *strides=g_variant_ref_sink(g_variant_new_fixed_array(G_VARIANT_TYPE_UINT32,&stride,1,sizeof(stride)));
  ok=import_dma(v,inv,handles,0,0,w,h,offsets,strides,1,fourcc,w,h,mod,top);
  g_variant_unref(handles);g_variant_unref(offsets);g_variant_unref(strides);
 } else if (!strcmp(name,"ScanoutDMABUF2")) {
  GVariant *handles,*offsets,*strides;guint x,y,w,h,planes,fourcc,bw,bh;guint64 mod;gboolean top;
  g_variant_get(params,"(@ahuuuu@au@auuuuutb)",&handles,&x,&y,&w,&h,&offsets,&strides,&planes,&fourcc,&bw,&bh,&mod,&top);
  ok=import_dma(v,inv,handles,x,y,w,h,offsets,strides,planes,fourcc,bw,bh,mod,top);
  g_variant_unref(handles);g_variant_unref(offsets);g_variant_unref(strides);
 } else if (!strcmp(name,"UpdateDMABUF")) {
  gint x,y,w,h;g_variant_get(params,"(iiii)",&x,&y,&w,&h);
  g_snprintf(v->frame_problem,sizeof(v->frame_problem),"UpdateDMABUF region=%d,%d %dx%d, scanout=%ux%u, imported=%s",x,y,w,h,v->width,v->height,v->source?"yes":"no");
  ok=region(v,x,y,w,h) && copy_dma(v);
  if (ok) {v->dma_frames++;v->last_dma=TRUE;}
 } else if (!strcmp(name,"Disable")) {
  discard_source(v);v->width=v->height=0;v->cache_valid=FALSE;v->seen_update=FALSE;release_input(v);
 } else if (!strcmp(name,"MouseSet")) {
  gint x,y,on;g_variant_get(params,"(iii)",&x,&y,&on);(void)x;(void)y;
  v->cursor_visible=on;update_cursor(v);
 } else if (!strcmp(name,"CursorDefine")) {
  gint w,h,x,y;GVariant *pixels;g_variant_get(params,"(iiii@ay)",&w,&h,&x,&y,&pixels);
  gsize len;const void *bytes=g_variant_get_fixed_array(pixels,&len,1);
  ok=w>0 && w<=256 && h>0 && h<=256 && x>=0 && x<w && y>=0 && y<h && len==(gsize)w*h*4;
  if (ok) {
   GBytes *copy=g_bytes_new(bytes,len);
   GdkTexture *texture=GDK_TEXTURE(gdk_memory_texture_new(w,h,GDK_MEMORY_B8G8R8A8_PREMULTIPLIED,copy,w*4));
   g_clear_object(&v->cursor);v->cursor=gdk_cursor_new_from_texture(texture,x,y,NULL);
   update_cursor(v);
   g_object_unref(texture);g_bytes_unref(copy);
  }
  g_variant_unref(pixels);
 } else ok=FALSE;
 GLenum frame_error=GL_NO_ERROR;
 if (!gtk_gl_area_get_error(GTK_GL_AREA(v->area))) frame_error=glGetError();
 if (frame_error!=GL_NO_ERROR) ok=FALSE;
 if (ok) {
  if (scanout) {
   v->awaiting_scanout=FALSE;
   if (v->reconnect_timer) {g_source_remove(v->reconnect_timer);v->reconnect_timer=0;}
  }
  if (frame && v->cache_valid && v->recovery_attempt) {
   v->recovery_attempt=0;
   g_print("{\"event\":\"display-recovered\",\"console\":%u,\"accelerated\":%s}\n",v->console_id,v->accelerated?"true":"false");fflush(stdout);
  }
  if (!strcmp(name,"Update") || !strcmp(name,"UpdateDMABUF")) v->seen_update=TRUE;
  if (v->parent) select_console(v->parent);
  if (!strcmp(name,"Scanout") || !strcmp(name,"Update") || !strcmp(name,"UpdateDMABUF") || !strcmp(name,"Disable"))
   gtk_gl_area_queue_render(GTK_GL_AREA(v->area));
  g_dbus_method_invocation_return_value(inv,NULL);
 }
 else {
  char *detail=g_strdup_printf("Console %u %s: %s; GL=0x%04x; requesting fresh scanout.",v->console_id,name,v->frame_problem,frame_error);
  g_dbus_method_invocation_return_dbus_error(inv,"org.winboat.Helios.DisplayError",detail);
  g_printerr("%s\n",detail);g_free(detail);
  if (frame && v->parent) report_display_recovery(v,v->frame_problem);
  if (!frame && frame_error==GL_NO_ERROR && !gtk_gl_area_get_error(GTK_GL_AREA(v->area))) return;
  if (v->parent && frame_error!=GL_CONTEXT_LOST && !gtk_gl_area_get_error(GTK_GL_AREA(v->area))) {
   /* A broken adapter frame must not tear down another working console. */
   discard_source(v);
   for (int i=0;i<8 && glGetError()!=GL_NO_ERROR;i++) {} /* Isolate adapter GL errors. */
   v->cache_valid=FALSE;v->seen_update=FALSE;v->width=v->height=0;
   select_console(v->parent);gtk_gl_area_queue_render(GTK_GL_AREA(v->area));
   refresh_scanout(v);
  } else {
   char *message=g_strdup_printf("%s failed: host OpenGL display error.",name);
   fatal(v,message);g_free(message);
  }
 }
}
static GVariant *property(GDBusConnection *conn,const gchar *sender,const gchar *path,const gchar *iface,const gchar *name,GError **err,gpointer data) {
 (void)conn;(void)sender;(void)path;(void)iface;(void)name;(void)err;(void)data;
 const char *interfaces[]={IFACE "Listener.Unix.ScanoutDMABUF2",NULL};return g_variant_new_strv(interfaces,-1);
}
static const GDBusInterfaceVTable vtable={.method_call=method,.get_property=property};
static void maybe_ready(Viewer *v) {
 Viewer *root=v->parent?v->parent:v;
 if (v->registered && v->peer && !root->ready) {
  root->ready=TRUE;g_print("{\"event\":\"ready\",\"transport\":\"dbus\"}\n");fflush(stdout);
 }
}
static void registered(GObject *object,GAsyncResult *result,gpointer data);
static gboolean reconnect_console(gpointer data) {
 Viewer *d=data;d->reconnect_timer=0;d->registered=FALSE;
 if (d->peer) {
  g_signal_handlers_disconnect_by_data(d->peer,d);
  if (!g_dbus_connection_is_closed(d->peer)) g_dbus_connection_close_sync(d->peer,NULL,NULL);
  g_clear_object(&d->peer);
 }
 g_dbus_connection_call_with_unix_fd_list(d->bus,"org.qemu",d->console_path,IFACE "Console","RegisterListenerReverse",NULL,
  G_VARIANT_TYPE("(h)"),G_DBUS_CALL_FLAGS_NONE,10000,NULL,NULL,registered,d);
 return G_SOURCE_REMOVE;
}
static void refresh_scanout(Viewer *v) {
 v->awaiting_scanout=TRUE;
 if (v->reconnect_timer) return;
 guint attempt=MIN(v->recovery_attempt,4u);v->recovery_attempt++;
 guint delay=MIN(10u,1u<<attempt);
 g_printerr("Console %u: re-registering in %u seconds to recover its scanout.\n",v->console_id,delay);
 v->reconnect_timer=g_timeout_add_seconds(delay,reconnect_console,v);
}
static void listener_failed(Viewer *d,const char *message) {
 Viewer *root=d->parent;
 gboolean other=FALSE;
 if (root && root->ready) for (guint i=0;i<root->consoles->len;i++) {
  Viewer *candidate=g_ptr_array_index(root->consoles,i);
  if (candidate!=d && candidate->peer && !g_dbus_connection_is_closed(candidate->peer)) other=TRUE;
 }
 if (!other) {fatal(d,message);return;}
 d->cache_valid=FALSE;d->seen_update=FALSE;d->registered=FALSE;d->awaiting_scanout=TRUE;select_console(root);
 report_display_recovery(d,"Display listener disconnected; reconnecting this adapter");
 g_printerr("Console %u: %s; reconnecting this adapter.\n",d->console_id,message);
 if (!d->reconnect_timer) d->reconnect_timer=g_timeout_add_seconds(1,reconnect_console,d);
}
static void closed(GDBusConnection *conn,gboolean vanished,GError *err,Viewer *v) {
 (void)conn;(void)vanished;(void)err;
 if (v->parent) {
  Viewer *root=v->parent;
  v->cache_valid=FALSE;v->registered=FALSE;select_console(root);
  gboolean disconnected=root->pending_consoles==0;
  for (guint i=0;i<root->consoles->len;i++) {
   Viewer *d=g_ptr_array_index(root->consoles,i);
   if (!d->peer || !g_dbus_connection_is_closed(d->peer)) disconnected=FALSE;
  }
  if (disconnected) fatal(root,"All QEMU display consoles disconnected.");
  else listener_failed(v,"Display listener disconnected");
  return;
 }
 fatal(v,"The QEMU display disconnected. Browser Display remains available.");
}
static void peer_ready(GObject *object,GAsyncResult *result,gpointer data) {
 (void)object;Viewer *v=data;GError *err=NULL;
 v->peer=g_dbus_connection_new_finish(result,&err);
 if (!v->peer) {listener_failed(v,err->message);g_error_free(err);return;}
 for (int i=0;v->info->interfaces[i];i++) {
  if (!g_dbus_connection_register_object(v->peer,LISTENER,v->info->interfaces[i],&vtable,v,NULL,&err)) {
   fatal(v,err->message);g_error_free(err);return;
  }
 }
 g_signal_connect(v->peer,"closed",G_CALLBACK(closed),v);g_dbus_connection_start_message_processing(v->peer);
 maybe_ready(v);
}
static void registered(GObject *object,GAsyncResult *result,gpointer data) {
 Viewer *v=data;GError *err=NULL;
 GUnixFDList *fds=NULL;
 GVariant *reply=g_dbus_connection_call_with_unix_fd_list_finish(G_DBUS_CONNECTION(object),&fds,result,&err);
 if (!reply) {listener_failed(v,err->message);g_error_free(err);return;}
 int handle;g_variant_get(reply,"(h)",&handle);g_variant_unref(reply);
 int fd=fds?g_unix_fd_list_get(fds,handle,&err):-1;
 g_clear_object(&fds);
 if (fd<0) {listener_failed(v,err?err->message:"QEMU returned no listener FD");g_clear_error(&err);return;}
 GSocket *socket=g_socket_new_from_fd(fd,&err);
 if (!socket) {close(fd);listener_failed(v,err->message);g_error_free(err);return;}
 GSocketConnection *stream=g_socket_connection_factory_create_connection(socket);g_object_unref(socket);
 /* QEMU creates the socket pair: SO_PEERCRED must identify QEMU, rather than
  * this viewer. Authenticate on the host, where its process is visible.
  */
 GDBusAuthObserver *auth=g_dbus_auth_observer_new();
 g_signal_connect(auth,"allow-mechanism",G_CALLBACK(external_only),v);
 g_signal_connect(auth,"authorize-authenticated-peer",G_CALLBACK(authorize_qemu),v);
 char *guid=g_dbus_generate_guid();v->registered=TRUE;
 g_dbus_connection_new(G_IO_STREAM(stream),guid,G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_SERVER|G_DBUS_CONNECTION_FLAGS_DELAY_MESSAGE_PROCESSING,
                       auth,NULL,peer_ready,v);g_free(guid);g_object_unref(auth);g_object_unref(stream);
}
static gboolean initialize_gl(Viewer *v) {
 const char *vertex="#version 330\nout vec2 uv;void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);uv=p;gl_Position=vec4(p*2-1,0,1);}";
 const char *fragment="#version 330\nin vec2 uv;out vec4 color;uniform sampler2D image;uniform vec4 rect;uniform bool flip;void main(){vec2 p=uv;if(flip)p.y=1-p.y;color=vec4(texture(image,rect.xy+p*rect.zw).rgb,1);}";
 GLuint vs=shader(GL_VERTEX_SHADER,vertex),fs=shader(GL_FRAGMENT_SHADER,fragment);
 v->program=glCreateProgram();glAttachShader(v->program,vs);glAttachShader(v->program,fs);glLinkProgram(v->program);
 glDeleteShader(vs);glDeleteShader(fs);GLint ok;glGetProgramiv(v->program,GL_LINK_STATUS,&ok);
 if (!ok) return FALSE;
 glGenVertexArrays(1,&v->vao);glGenFramebuffers(1,&v->fbo);glGenTextures(1,&v->texture);glBindTexture(GL_TEXTURE_2D,v->texture);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
 return glGetError()==GL_NO_ERROR;
}
static void console_discovered(Viewer *v) {
 if (--v->pending_consoles==0 && !v->consoles->len && !v->exit_code)
  fatal(v,"QEMU provides no graphical desktop console.");
}
static void mouse_ready(GObject *object,GAsyncResult *result,gpointer data) {
 (void)object;Viewer *d=data,*v=d->parent;GError *error=NULL;
 d->mouse=g_dbus_proxy_new_finish(result,&error);
 if (!d->mouse) {fatal(v,error->message);g_error_free(error);}
 else if (!v->exit_code) {
  /* Discovery callbacks run after realize, so restore our GL context. */
  gtk_gl_area_make_current(GTK_GL_AREA(v->area));
  const GError *gl_error=gtk_gl_area_get_error(GTK_GL_AREA(v->area));
  if (gl_error) fatal(v,gl_error->message);
  else {
   glGenTextures(1,&d->texture);glBindTexture(GL_TEXTURE_2D,d->texture);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
   g_dbus_connection_call_with_unix_fd_list(v->bus,"org.qemu",d->console_path,IFACE "Console","RegisterListenerReverse",NULL,
    G_VARIANT_TYPE("(h)"),G_DBUS_CALL_FLAGS_NONE,10000,NULL,NULL,registered,d);
  }
 }
 console_discovered(v);
}
static void console_ready(GObject *object,GAsyncResult *result,gpointer data) {
 (void)object;Viewer *d=data,*v=d->parent;GError *error=NULL;
 GDBusProxy *console=g_dbus_proxy_new_finish(result,&error);
 if (!console) {
  fatal(v,error->message);g_error_free(error);
  g_free(d->console_path);g_free(d);console_discovered(v);return;
 }
 GVariant *type=g_dbus_proxy_get_cached_property(console,"Type"),*label=g_dbus_proxy_get_cached_property(console,"Label"),
          *head=g_dbus_proxy_get_cached_property(console,"Head");
 gboolean graphic=type && g_variant_is_of_type(type,G_VARIANT_TYPE_STRING) && !strcmp(g_variant_get_string(type,NULL),"Graphic");
 /* The default desktop is head 0; do not replace it with an extended monitor. */
 if (!v->exit_code && graphic && (!head || (g_variant_is_of_type(head,G_VARIANT_TYPE_UINT32) && g_variant_get_uint32(head)==0))) {
  const char *name=label && g_variant_is_of_type(label,G_VARIANT_TYPE_STRING)?g_variant_get_string(label,NULL):"";
  char *normalized=g_ascii_strdown(name,-1);
  /* QEMU labels this VM's device by its explicit id, "heliosgpu". */
  d->accelerated=!strstr(normalized,"bootstrap") && (strstr(normalized,"virtio") || strstr(normalized,"helios"));
  g_free(normalized);
  g_ptr_array_add(v->consoles,d);
  g_dbus_proxy_new(v->bus,G_DBUS_PROXY_FLAGS_NONE,NULL,"org.qemu",d->console_path,IFACE "Mouse",NULL,mouse_ready,d);
 } else {
  g_free(d->console_path);g_free(d);console_discovered(v);
 }
 g_clear_pointer(&type,g_variant_unref);g_clear_pointer(&label,g_variant_unref);g_clear_pointer(&head,g_variant_unref);
 g_object_unref(console);
}
static void console_ids_ready(GObject *object,GAsyncResult *result,gpointer data) {
 Viewer *v=data;GError *error=NULL;
 GVariant *reply=g_dbus_connection_call_finish(G_DBUS_CONNECTION(object),result,&error);
 if (!reply) {fatal(v,error->message);g_error_free(error);return;}
 GVariant *boxed,*ids;g_variant_get(reply,"(@v)",&boxed);ids=g_variant_get_variant(boxed);
 if (!g_variant_is_of_type(ids,G_VARIANT_TYPE("au")) || g_variant_n_children(ids)>32) {
  fatal(v,"Invalid QEMU graphical console list.");
 } else if (!(v->pending_consoles=g_variant_n_children(ids))) {
  fatal(v,"QEMU provides no graphical desktop console.");
 } else for (gsize i=0;i<g_variant_n_children(ids);i++) {
  guint id;g_variant_get_child(ids,i,"u",&id);
  /* Copy only shared resources: another console may already be displaying
   * frames when its asynchronous sibling finishes discovery. */
  Viewer *d=g_new0(Viewer,1);
  d->parent=v;d->area=v->area;d->bus=v->bus;d->info=v->info;d->qemu_uid=v->qemu_uid;
  d->program=v->program;d->vao=v->vao;d->fbo=v->fbo;
  d->image=EGL_NO_IMAGE_KHR;d->display=EGL_NO_DISPLAY;d->cursor_visible=TRUE;
  d->console_path=g_strdup_printf(CONSOLE_PREFIX "%u",id);d->console_id=id;
  g_dbus_proxy_new(v->bus,G_DBUS_PROXY_FLAGS_DO_NOT_CONNECT_SIGNALS,NULL,"org.qemu",d->console_path,IFACE "Console",NULL,console_ready,d);
 }
 g_variant_unref(ids);g_variant_unref(boxed);g_variant_unref(reply);
}
static void register_consoles(Viewer *v) {
 /* Never block GTK while discovering consoles. QEMU may wait for a listener
  * handshake on its main loop before it can answer another property query. */
 g_dbus_connection_call(v->bus,"org.qemu",VM,"org.freedesktop.DBus.Properties","Get",
  g_variant_new("(ss)",IFACE "VM","ConsoleIDs"),G_VARIANT_TYPE("(v)"),G_DBUS_CALL_FLAGS_NONE,5000,NULL,console_ids_ready,v);
}
static gboolean console_eligible(Viewer *v,Viewer *d) {
 return d->cache_valid && (d->accelerated?v->helios_health:v->basic_health)!=2;
}
static void select_console(Viewer *v) {
 Viewer *next=v->active && console_eligible(v,v->active)?v->active:NULL;
 for (guint i=0;i<v->consoles->len;i++) {
  Viewer *d=g_ptr_array_index(v->consoles,i);
  if (!console_eligible(v,d)) continue;
  /* A confirmed running driver may publish a complete Scanout with no later
   * Update on a static desktop. Its initial frame must already beat VGA. */
  if (!next || (d->accelerated && !next->accelerated && (d->seen_update || v->helios_health==1))) next=d;
 }
 if (next==v->active) return;
 release_input(v);v->active=next;v->requested_width=v->requested_height=0;
 if (v->resize_timer) {g_source_remove(v->resize_timer);v->resize_timer=0;}
 update_cursor(v);
 if (next) {
  g_printerr("{\"event\":\"console\",\"id\":%u,\"accelerated\":%s}\n",next->console_id,next->accelerated?"true":"false");
  request_resize(v);
 }
 gtk_gl_area_queue_render(GTK_GL_AREA(v->area));
}
static void adapter_health(Viewer *v,gint helios,gint basic) {
 for (guint i=0;i<v->consoles->len;i++) {
  Viewer *d=g_ptr_array_index(v->consoles,i);
  if ((d->accelerated?helios:basic)==2) {d->cache_valid=FALSE;d->seen_update=FALSE;}
 }
 v->helios_health=helios;v->basic_health=basic;v->health_at=g_get_monotonic_time();
 select_console(v);
}
static gboolean adapter_control(GIOChannel *channel,GIOCondition condition,gpointer data) {
 Viewer *v=data;
 if (condition&(G_IO_HUP|G_IO_ERR|G_IO_NVAL)) {v->health_watch=0;adapter_health(v,0,0);return G_SOURCE_REMOVE;}
 char *line=NULL;gsize length=0;GError *error=NULL;
 GIOStatus status=g_io_channel_read_line(channel,&line,&length,NULL,&error);
 if (status==G_IO_STATUS_NORMAL && length<=64) {
  int helios,basic;char extra;
  if (sscanf(line,"adapters %d %d %c",&helios,&basic,&extra)==2 && helios>=0 && helios<=2 && basic>=0 && basic<=2)
   adapter_health(v,helios,basic);
 }
 g_free(line);g_clear_error(&error);
 if (status==G_IO_STATUS_EOF || status==G_IO_STATUS_ERROR) {v->health_watch=0;adapter_health(v,0,0);return G_SOURCE_REMOVE;}
 return G_SOURCE_CONTINUE;
}
static gboolean expire_adapter_health(gpointer data) {
 Viewer *v=data;
 /* API loss/reboots are unknown, never evidence that an adapter failed. */
 if (v->health_at && g_get_monotonic_time()-v->health_at>15*G_USEC_PER_SEC) {
  adapter_health(v,0,0);v->health_at=0;
 }
 return G_SOURCE_CONTINUE;
}
static void realize(GtkGLArea *area,Viewer *v) {
 gtk_gl_area_make_current(area);
 const GError *gl_error=gtk_gl_area_get_error(area);
 if (gl_error) {
  char *message=g_strdup_printf("Host GTK OpenGL (%s): %s",G_OBJECT_TYPE_NAME(gdk_display_get_default()),gl_error->message);
  fatal(v,message);g_free(message);return;
 }
 if (!initialize_gl(v)) {fatal(v,"OpenGL shader initialization failed.");return;}
 register_consoles(v);
}
static gboolean close_window(GtkWindow *window,Viewer *v) {(void)window;release_input(v);g_main_loop_quit(v->loop);return FALSE;}
static gboolean terminate_viewer(gpointer data) {Viewer *v=data;release_input(v);g_main_loop_quit(v->loop);return G_SOURCE_REMOVE;}
static void fullscreen_clicked(GtkButton *button,Viewer *v) {
 (void)button;release_input(v);
 if (gtk_window_is_fullscreen(GTK_WINDOW(v->window))) gtk_window_unfullscreen(GTK_WINDOW(v->window));
 else gtk_window_fullscreen(GTK_WINDOW(v->window));
 gtk_widget_grab_focus(v->area);
}
static void secure_attention(GtkButton *button,Viewer *v) {
 (void)button;release_input(v);const guint keys[]={0x1d,0x38,0xd3};
 for (guint i=0;i<G_N_ELEMENTS(keys);i++) input(v,IFACE "Keyboard","Press",g_variant_new("(u)",keys[i]));
 for (guint i=G_N_ELEMENTS(keys);i>0;i--) input(v,IFACE "Keyboard","Release",g_variant_new("(u)",keys[i-1]));
 gtk_widget_grab_focus(v->area);
}
static void screenshot_response(GtkNativeDialog *dialog,int response,Viewer *v) {
 if (response==GTK_RESPONSE_ACCEPT) {
  GFile *file=gtk_file_chooser_get_file(GTK_FILE_CHOOSER(dialog));
  g_clear_pointer(&v->screenshot_path,g_free);
  if (file) {v->screenshot_path=g_file_get_path(file);g_object_unref(file);}
  if (v->screenshot_path) gtk_gl_area_queue_render(GTK_GL_AREA(v->area));
  else gtk_label_set_text(GTK_LABEL(v->status),"Choose a local file for the screenshot.");
 }
 gtk_native_dialog_destroy(dialog);g_object_unref(dialog);gtk_widget_grab_focus(v->area);
}
static void screenshot_clicked(GtkButton *button,Viewer *v) {
 (void)button;release_input(v);
 GtkFileChooserNative *dialog=gtk_file_chooser_native_new("Save Windows screenshot",GTK_WINDOW(v->window),GTK_FILE_CHOOSER_ACTION_SAVE,"Save","Cancel");
 gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog),"WinBoat-screenshot.png");
 GtkFileFilter *filter=gtk_file_filter_new();gtk_file_filter_set_name(filter,"PNG image");gtk_file_filter_add_pattern(filter,"*.png");
 gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog),filter);g_object_unref(filter);
 gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog),TRUE);
 g_signal_connect(dialog,"response",G_CALLBACK(screenshot_response),v);gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
}
static void resize_finished(GObject *object,GAsyncResult *result,gpointer data) {
 Viewer *v=data;GError *error=NULL;
 GVariant *reply=g_dbus_connection_call_finish(G_DBUS_CONNECTION(object),result,&error);
 if (!reply) {
  v->resize_failed=TRUE;
  gtk_label_set_text(GTK_LABEL(v->status),"Guest resolution request failed; scaling remains available.");
  g_printerr("Guest resize request failed: %s\n",error->message);g_error_free(error);
 } else {v->resize_failed=FALSE;v->resize_requests++;g_variant_unref(reply);}
}
static gboolean request_resize(gpointer data) {
 Viewer *v=data;v->resize_timer=0;
 Viewer *d=displayed(v);
 if (!v->auto_resize || !d->console_path) return G_SOURCE_REMOVE;
 guint scale=gtk_widget_get_scale_factor(v->area);
 guint w=gtk_widget_get_width(v->area)*scale,h=gtk_widget_get_height(v->area)*scale;
 if (!dimensions(w,h) || w<640 || h<480 || (w==v->requested_width && h==v->requested_height)) return G_SOURCE_REMOVE;
 v->requested_width=w;v->requested_height=h;
 g_dbus_connection_call(v->bus,"org.qemu",d->console_path,IFACE "Console","SetUIInfo",
  g_variant_new("(qqiiuu)",(guint16)(w*25.4/96),(guint16)(h*25.4/96),0,0,w,h),
  NULL,G_DBUS_CALL_FLAGS_NONE,2000,NULL,resize_finished,v);
 return G_SOURCE_REMOVE;
}
static void resized(GtkGLArea *area,int width,int height,Viewer *v) {
 (void)area;(void)width;(void)height;v->have_position=FALSE;
 if (v->resize_timer) g_source_remove(v->resize_timer);
 v->resize_timer=v->auto_resize?g_timeout_add(300,request_resize,v):0;
 gtk_gl_area_queue_render(GTK_GL_AREA(v->area));
}
static void resize_toggled(GtkCheckButton *button,Viewer *v) {
 v->auto_resize=gtk_check_button_get_active(button);v->requested_width=0;v->requested_height=0;
 resized(GTK_GL_AREA(v->area),0,0,v);gtk_widget_grab_focus(v->area);
}
static void aspect_toggled(GtkCheckButton *button,Viewer *v) {
 v->stretch=!gtk_check_button_get_active(button);v->have_position=FALSE;
 gtk_gl_area_queue_render(GTK_GL_AREA(v->area));gtk_widget_grab_focus(v->area);
}
static gboolean stats(Viewer *v) {
 Viewer *d=displayed(v);
 char *text=g_strdup_printf("%u × %u · %s · guest resize: %s (%" G_GUINT64_FORMAT " accepted)",
  d->width,d->height,d->last_dma?"DMA-BUF / OpenGL":"Software / OpenGL",v->resize_failed?"unsupported/failed":v->auto_resize?"enabled":"off",v->resize_requests);
 gtk_label_set_text(GTK_LABEL(v->status),text);g_free(text);
 g_printerr("{\"event\":\"statistics\",\"dmabufFrames\":%" G_GUINT64_FORMAT ",\"softwareFrames\":%" G_GUINT64_FORMAT ",\"renderedFrames\":%" G_GUINT64_FORMAT "}\n",d->dma_frames,d->software_frames,v->rendered_frames);return G_SOURCE_CONTINUE;
}
static gboolean smoke_done(Viewer *v) {
 stats(v);
 if (!v->ready || !displayed(v)->software_frames || !v->rendered_frames || !v->resize_requests) fatal(v,"Software display smoke test requires rendered frames and an accepted guest resize request.");
 else {
  /* Readback exists only in this explicit test mode, not the normal viewer. */
  gtk_gl_area_make_current(GTK_GL_AREA(v->area));gtk_gl_area_attach_buffers(GTK_GL_AREA(v->area));
  /* GTK may hand its last front buffer to the compositor and attach a recycled
   * back buffer. Draw the current cache before explicit test readback. */
  render(GTK_GL_AREA(v->area),gtk_gl_area_get_context(GTK_GL_AREA(v->area)),v);
  int scale=gtk_widget_get_scale_factor(v->area), w=gtk_widget_get_width(v->area)*scale, h=gtk_widget_get_height(v->area)*scale;
  if (!dimensions(w,h)) {fatal(v,"Invalid smoke-test screenshot size.");return G_SOURCE_REMOVE;}
  guint8 *pixels=g_malloc((gsize)w*h*3);glPixelStorei(GL_PACK_ALIGNMENT,1);
  glReadPixels(0,0,w,h,GL_RGB,GL_UNSIGNED_BYTE,pixels);glFinish();
  char *png=g_build_filename(g_get_tmp_dir(),"helios-viewer-smoke.png",NULL);
  if (!save_screenshot(v,png)) {g_free(png);g_free(pixels);fatal(v,"PNG screenshot test failed.");return G_SOURCE_REMOVE;}
  GdkPixbuf *check=gdk_pixbuf_new_from_file(png,NULL);g_free(png);
  if (!check || gdk_pixbuf_get_width(check)!=w || gdk_pixbuf_get_height(check)!=h) {
   g_clear_object(&check);g_free(pixels);fatal(v,"PNG screenshot dimensions failed.");return G_SOURCE_REMOVE;
  }
  g_object_unref(check);
  char *filename=g_build_filename(g_get_tmp_dir(),"helios-viewer-smoke.ppm",NULL);
  FILE *output=glGetError()==GL_NO_ERROR?fopen(filename,"wb"):NULL;
  if (!output) fatal(v,"Could not capture the software display test.");
  else {
   fprintf(output,"P6\n%d %d\n255\n",w,h);
   for (int row=h-1;row>=0;row--) fwrite(pixels+(gsize)row*w*3,1,w*3,output);
   if (fclose(output)) fatal(v,"Could not save the software display test.");
   else g_main_loop_quit(v->loop);
  }
  g_free(filename);g_free(pixels);
 }
 return G_SOURCE_REMOVE;
}
int main(int argc,char **argv) {
 const char *version_error=gtk_check_version(4,8,0);
 if (version_error) {g_printerr("GTK 4.8 or newer is required: %s\n",version_error);return 1;}
 desktop_gl();
 if (argc==2 && !strcmp(argv[1],"--version")) {puts("winboat-helios-viewer 5");return 0;}
 if (argc==2 && !strcmp(argv[1],"--check-gl")) {
  if (!gtk_init_check()) {g_printerr("GTK cannot open the host X11/Wayland display.\n");return 1;}
  GtkWidget *window=gtk_window_new(),*area=display_area();
  gtk_window_set_child(GTK_WINDOW(window),area);gtk_widget_realize(window);gtk_widget_realize(area);
  gtk_gl_area_make_current(GTK_GL_AREA(area));
  const GError *error=gtk_gl_area_get_error(GTK_GL_AREA(area));
  int result=error?1:0;
  if (error) g_printerr("Host GTK OpenGL: %s\n",error->message);
  else if (eglGetCurrentDisplay()==EGL_NO_DISPLAY) {g_printerr("Host GTK OpenGL has no EGL context; DMA-BUF import is unavailable.\n");result=1;}
  else if (!glGetString(GL_VERSION) || !glGetString(GL_RENDERER)) {g_printerr("Host GTK OpenGL returned no version/renderer.\n");result=1;}
  else g_print("Host GTK OpenGL: %s; renderer: %s; backend: %s\n",glGetString(GL_VERSION),glGetString(GL_RENDERER),G_OBJECT_TYPE_NAME(gdk_display_get_default()));
  gtk_window_destroy(GTK_WINDOW(window));return result;
 }
 if (argc==2 && !strcmp(argv[1],"--self-test")) {
  g_assert(dimensions(1920,1080));g_assert(!dimensions(0,1));g_assert(!dimensions(UINT32_MAX,2));g_assert(!dimensions(8192,8192));
  g_assert_cmpuint(qnum(38),==,30);g_assert_cmpuint(qnum(105),==,0x9d);g_assert_cmpuint(qnum(119),==,0xd3);g_assert_cmpuint(qnum(1),==,0);
  Viewer geometry={.width=1920,.height=1080};int x,y,w,h;
  viewport(&geometry,800,600,&x,&y,&w,&h);g_assert_cmpint(w,==,800);g_assert_cmpint(h,==,450);g_assert_cmpint(y,==,75);
  geometry.stretch=TRUE;viewport(&geometry,800,600,&x,&y,&w,&h);g_assert_cmpint(h,==,600);g_assert_cmpint(y,==,0);
  Viewer check={.qemu_uid=1234};GCredentials *credentials=g_credentials_new();
  g_assert_true(g_credentials_set_unix_user(credentials,1234,NULL));
  g_assert_true(authorize_qemu(NULL,NULL,credentials,&check));check.qemu_uid=5678;
  g_assert_false(authorize_qemu(NULL,NULL,credentials,&check));g_assert_false(authorize_qemu(NULL,NULL,NULL,&check));
  g_assert_false(external_only(NULL,"ANONYMOUS",NULL));g_assert_true(external_only(NULL,"EXTERNAL",NULL));g_object_unref(credentials);
  GError *err=NULL;GDBusNodeInfo *info=g_dbus_node_info_new_for_xml(xml,&err);g_assert_no_error(err);g_assert_nonnull(info);g_dbus_node_info_unref(info);
  puts("Viewer bounds, key mapping and D-Bus interfaces passed.");return 0;
 }
 gboolean ping=argc==3 && !strcmp(argv[1],"--ping");
 gboolean control=argc==4 && !strcmp(argv[3],"--control-stdin");
 gboolean smoke=(argc==3 || control) && !strcmp(argv[1],"--smoke-test");
 if ((argc!=3 && !control) || (!ping && !smoke && strcmp(argv[1],"--address"))) {g_printerr("Usage: winboat-helios-viewer --address unix:path=...\n");return 2;}
 if (!g_str_has_prefix(argv[2],"unix:path=")) {g_printerr("Only local Unix display sockets are supported.\n");return 2;}
 Viewer v={.image=EGL_NO_IMAGE_KHR,.display=EGL_NO_DISPLAY,.cursor_visible=TRUE};GError *err=NULL;v.loop=g_main_loop_new(NULL,FALSE);
 v.bus=g_dbus_connection_new_for_address_sync(argv[2],G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT|G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,NULL,NULL,&err);
 if (!v.bus) {g_printerr("%s\n",err->message);g_error_free(err);return 1;}
 if (ping) {
  GVariant *reply=g_dbus_connection_call_sync(v.bus,"org.freedesktop.DBus","/org/freedesktop/DBus","org.freedesktop.DBus.Peer","Ping",NULL,NULL,G_DBUS_CALL_FLAGS_NONE,1500,NULL,&err);
  if (!reply) {g_printerr("%s\n",err->message);g_error_free(err);return 1;}
  g_variant_unref(reply);g_object_unref(v.bus);g_main_loop_unref(v.loop);return 0;
 }
 g_signal_connect(v.bus,"closed",G_CALLBACK(closed),&v);
 GVariant *owner=g_dbus_connection_call_sync(v.bus,"org.freedesktop.DBus","/org/freedesktop/DBus","org.freedesktop.DBus","GetConnectionUnixUser",g_variant_new("(s)","org.qemu"),G_VARIANT_TYPE("(u)"),G_DBUS_CALL_FLAGS_NONE,3000,NULL,&err);
 if (!owner) {g_printerr("No authenticated QEMU display: %s\n",err->message);g_error_free(err);return 1;}
 g_variant_get(owner,"(u)",&v.qemu_uid);g_variant_unref(owner);
 v.consoles=g_ptr_array_new();
 v.info=g_dbus_node_info_new_for_xml(xml,&err);
 if (!gtk_init_check()) {g_printerr("No GTK display available.\n");return 1;}
 v.window=gtk_window_new();gtk_window_set_title(GTK_WINDOW(v.window),"WinBoat — Helios Desktop");gtk_window_set_default_size(GTK_WINDOW(v.window),1024,640);
 v.area=display_area();gtk_gl_area_set_auto_render(GTK_GL_AREA(v.area),FALSE);
 gtk_widget_set_focusable(v.area,TRUE);
 GtkWidget *overlay=gtk_overlay_new();gtk_overlay_set_child(GTK_OVERLAY(overlay),v.area);
 v.waiting=gtk_label_new("Waiting for the Windows display…\nCtrl+Alt+Enter toggles fullscreen.");
 gtk_widget_set_halign(v.waiting,GTK_ALIGN_CENTER);gtk_widget_set_valign(v.waiting,GTK_ALIGN_CENTER);
 gtk_widget_set_can_target(v.waiting,FALSE);gtk_overlay_add_overlay(GTK_OVERLAY(overlay),v.waiting);
 GtkWidget *layout=gtk_box_new(GTK_ORIENTATION_VERTICAL,0);gtk_widget_set_vexpand(overlay,TRUE);
 v.status=gtk_label_new("Connecting to Windows display…");gtk_widget_set_can_target(v.status,FALSE);
 gtk_box_append(GTK_BOX(layout),overlay);gtk_box_append(GTK_BOX(layout),v.status);
 gtk_window_set_child(GTK_WINDOW(v.window),layout);
 GtkWidget *bar=gtk_header_bar_new(),*full=gtk_button_new_with_label("Fullscreen"),*attention=gtk_button_new_with_label("Ctrl+Alt+Del");
 gtk_widget_set_tooltip_text(full,"Toggle fullscreen (Ctrl+Alt+Enter)");
 gtk_widget_set_tooltip_text(attention,"Send Ctrl+Alt+Delete to Windows");
 gtk_header_bar_pack_start(GTK_HEADER_BAR(bar),attention);gtk_header_bar_pack_end(GTK_HEADER_BAR(bar),full);
 GtkWidget *resize=gtk_check_button_new_with_label("Resize guest"),*aspect=gtk_check_button_new_with_label("Keep aspect");
 gtk_check_button_set_active(GTK_CHECK_BUTTON(aspect),TRUE);
 gtk_widget_set_tooltip_text(resize,"Request window resolution from Windows; requires guest driver support.");
 gtk_header_bar_pack_start(GTK_HEADER_BAR(bar),resize);gtk_header_bar_pack_start(GTK_HEADER_BAR(bar),aspect);
 g_signal_connect(resize,"toggled",G_CALLBACK(resize_toggled),&v);g_signal_connect(aspect,"toggled",G_CALLBACK(aspect_toggled),&v);
 g_signal_connect(v.area,"resize",G_CALLBACK(resized),&v);
 if (smoke) gtk_check_button_set_active(GTK_CHECK_BUTTON(resize),TRUE);
 GtkWidget *shot=gtk_button_new_with_label("Screenshot");gtk_header_bar_pack_end(GTK_HEADER_BAR(bar),shot);
 g_signal_connect(shot,"clicked",G_CALLBACK(screenshot_clicked),&v);
 gtk_window_set_titlebar(GTK_WINDOW(v.window),bar);
 g_signal_connect(full,"clicked",G_CALLBACK(fullscreen_clicked),&v);g_signal_connect(attention,"clicked",G_CALLBACK(secure_attention),&v);
 g_unix_signal_add(SIGTERM,terminate_viewer,&v);g_unix_signal_add(SIGINT,terminate_viewer,&v);
 g_signal_connect(v.area,"realize",G_CALLBACK(realize),&v);g_signal_connect(v.area,"render",G_CALLBACK(render),&v);
 g_signal_connect(v.window,"close-request",G_CALLBACK(close_window),&v);
 GtkEventController *keys=gtk_event_controller_key_new();g_signal_connect(keys,"key-pressed",G_CALLBACK(key_press),&v);g_signal_connect(keys,"key-released",G_CALLBACK(key_release),&v);gtk_widget_add_controller(v.area,keys);
 GtkEventController *focus=gtk_event_controller_focus_new();g_signal_connect(focus,"leave",G_CALLBACK(focus_leave),&v);gtk_widget_add_controller(v.area,focus);
 GtkEventController *move=gtk_event_controller_motion_new();g_signal_connect(move,"motion",G_CALLBACK(motion),&v);gtk_widget_add_controller(v.area,move);
 GtkGesture *buttons=gtk_gesture_click_new();gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(buttons),0);
 g_signal_connect(buttons,"pressed",G_CALLBACK(click),&v);g_signal_connect(buttons,"released",G_CALLBACK(click),&v);gtk_widget_add_controller(v.area,GTK_EVENT_CONTROLLER(buttons));
 GtkEventController *wheel=gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES|GTK_EVENT_CONTROLLER_SCROLL_DISCRETE);g_signal_connect(wheel,"scroll",G_CALLBACK(scroll),&v);gtk_widget_add_controller(v.area,wheel);
 if (control) {
  GIOChannel *channel=g_io_channel_unix_new(STDIN_FILENO);
  g_io_channel_set_flags(channel,g_io_channel_get_flags(channel)|G_IO_FLAG_NONBLOCK,NULL);
  v.health_watch=g_io_add_watch(channel,G_IO_IN|G_IO_HUP|G_IO_ERR|G_IO_NVAL,adapter_control,&v);
  g_io_channel_unref(channel);v.health_timer=g_timeout_add_seconds(2,expire_adapter_health,&v);
 }
 gtk_window_present(GTK_WINDOW(v.window));gtk_widget_grab_focus(v.area);g_timeout_add_seconds(5,(GSourceFunc)stats,&v);
 if (smoke) g_timeout_add_seconds(12,(GSourceFunc)smoke_done,&v);
 if (!v.exit_code) g_main_loop_run(v.loop);
 if (v.resize_timer) g_source_remove(v.resize_timer);
 if (v.health_watch) g_source_remove(v.health_watch);
 if (v.health_timer) g_source_remove(v.health_timer);
 g_clear_pointer(&v.screenshot_path,g_free);
 release_input(&v);g_dbus_connection_flush_sync(v.bus,NULL,NULL);
 for (guint i=0;i<v.consoles->len;i++) {
  Viewer *d=g_ptr_array_index(v.consoles,i);
  if (d->reconnect_timer) g_source_remove(d->reconnect_timer);
  if (d->peer) {g_signal_handlers_disconnect_by_data(d->peer,d);g_dbus_connection_close_sync(d->peer,NULL,NULL);g_object_unref(d->peer);}
  g_clear_object(&d->mouse);g_clear_object(&d->cursor);g_free(d->console_path);g_free(d);
 }
 g_ptr_array_free(v.consoles,TRUE);
 g_signal_handlers_disconnect_by_data(v.bus,&v);
 g_clear_object(&v.mouse);g_clear_object(&v.bus);g_clear_object(&v.cursor);g_dbus_node_info_unref(v.info);g_main_loop_unref(v.loop);
 return v.exit_code;
}
