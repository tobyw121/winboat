/* Exercise the real viewer shaders and DMA presentation copy with Mesa/Xvfb.
 * Synthetic textures avoid requiring a physical GPU or a Windows guest. */
#include <epoxy/gl.h>
static int reject_texture_binding;
static void texture_image(GLenum target,GLeglImageOES image);
#undef glEGLImageTargetTexture2DOES
#define glEGLImageTargetTexture2DOES texture_image
#define main viewer_main
#include "../native/helios-viewer/viewer.c"
#undef main
#undef glEGLImageTargetTexture2DOES
static void texture_image(GLenum target,GLeglImageOES image) {
 if (reject_texture_binding) {
  /* Reproduce the NVIDIA GL_INVALID_OPERATION without replacing EGLImage
   * creation or the renderbuffer import/blit that must actually succeed. */
  GLint texture;glGetIntegerv(GL_TEXTURE_BINDING_2D,&texture);
  glBindTexture(GL_TEXTURE_CUBE_MAP,texture);return;
 }
 epoxy_glEGLImageTargetTexture2DOES(target,image);
}

static void expect_corners(GLuint fbo) {
 /* GL readback order: bottom-left, bottom-right, top-left, top-right. */
 const guint8 expected[][3]={{0,0,255},{255,255,0},{255,0,0},{0,255,0}};
 glBindFramebuffer(GL_FRAMEBUFFER,fbo);
 for (int y=0;y<2;y++) for (int x=0;x<2;x++) {
  guint8 pixel[4];
  glReadPixels(x*3,y*3,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel);
  for (int c=0;c<3;c++) g_assert_cmpuint(pixel[c],==,expected[y*2+x][c]);
 }
 g_assert_cmpuint(glGetError(),==,GL_NO_ERROR);
}

int main(void) {
 desktop_gl();
 g_assert_true(gtk_init_check());
 /* Exercise GTK's default/shared API as well as the explicit GtkGLArea API.
  * On newer GTK, constraining only the area can leave a GLES display context. */
 GError *error=NULL;
 GdkGLContext *shared=gdk_display_create_gl_context(gdk_display_get_default(),&error);
 g_assert_no_error(error);g_assert_nonnull(shared);
 g_assert_true(gdk_gl_context_realize(shared,&error));g_assert_no_error(error);
 g_assert_cmpint(gdk_gl_context_get_api(shared),==,GDK_GL_API_GL);
 g_object_unref(shared);
 GtkWidget *window=gtk_window_new(),*area=display_area();
 if (g_object_class_find_property(G_OBJECT_GET_CLASS(area),"allowed-apis")) {
  GdkGLAPI allowed;g_object_get(area,"allowed-apis",&allowed,NULL);
  g_assert_cmpint(allowed,==,GDK_GL_API_GL);
 }
 gtk_window_set_child(GTK_WINDOW(window),area);
 gtk_widget_realize(window);gtk_widget_realize(area);
 gtk_gl_area_make_current(GTK_GL_AREA(area));
 g_assert_null(gtk_gl_area_get_error(GTK_GL_AREA(area)));
 g_assert_cmpint(gdk_gl_context_get_api(gtk_gl_area_get_context(GTK_GL_AREA(area))),==,GDK_GL_API_GL);
 g_assert_true(eglGetCurrentDisplay()!=EGL_NO_DISPLAY);
 Viewer v={0};g_assert_true(initialize_gl(&v));
 GLuint target,fbo;glGenTextures(1,&target);glBindTexture(GL_TEXTURE_2D,target);
 glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,4,4,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
 glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
 glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,target,0);
 g_assert_cmpuint(glCheckFramebufferStatus(GL_FRAMEBUFFER),==,GL_FRAMEBUFFER_COMPLETE);
 const float full[]={0,0,1,1};
 glGenTextures(1,&v.source);
 for (int top=0;top<=1;top++) {
  /* Nonzero crop in a larger backing texture also detects wrong offsets.
   * QEMU y0_top=true presents GL row zero at the bottom, as in egl_fb_blit. */
  guint8 pixels[8][6][4]={0};
  const guint8 colors[][4]={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,0,255}};
  for (int y=0;y<4;y++) for (int x=0;x<4;x++) {
   int row=top?1-y/2:y/2;
   memcpy(pixels[y+2][x+1],colors[row*2+x/2],4);
  }
  glBindTexture(GL_TEXTURE_2D,v.source);
  glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,6,8,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
  dma_geometry(&v,1,2,4,4,6,8,top);
  g_assert_true(copy_dma(&v));
  glBindFramebuffer(GL_FRAMEBUFFER,fbo);glViewport(0,0,4,4);
  draw(&v,v.texture,full,v.flip);expect_corners(fbo);
 }
 /* Software scanouts remain top-down and must still flip on presentation. */
 const guint8 software[][4]={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,0,255}};
 texture_size(&v,2,2);glTexSubImage2D(GL_TEXTURE_2D,0,0,0,2,2,GL_RGBA,GL_UNSIGNED_BYTE,software);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
 glBindFramebuffer(GL_FRAMEBUFFER,fbo);glViewport(0,0,4,4);
 draw(&v,v.texture,full,TRUE);expect_corners(fbo);
 /* Real EGLImage binding, independently of DMA-BUF availability in Xvfb.
  * A stale GL error must not make a valid imported image look unsupported. */
 discard_source(&v);
 GLuint original;glGenTextures(1,&original);glBindTexture(GL_TEXTURE_2D,original);
 glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,2,2,0,GL_RGBA,GL_UNSIGNED_BYTE,software);
 glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
 EGLDisplay display=eglGetCurrentDisplay();
 EGLImageKHR image=eglCreateImageKHR(display,eglGetCurrentContext(),EGL_GL_TEXTURE_2D_KHR,(EGLClientBuffer)(uintptr_t)original,NULL);
 g_assert_true(image!=EGL_NO_IMAGE_KHR);
 glEnable(0xffffffffu); /* Deliberately leave GL_INVALID_ENUM in shared state. */
 g_assert_true(bind_egl_source(&v,image,FALSE));
 dma_geometry(&v,0,0,2,2,2,2,FALSE);g_assert_true(copy_dma(&v));
 glBindFramebuffer(GL_FRAMEBUFFER,fbo);glViewport(0,0,4,4);
 draw(&v,v.texture,full,v.flip);expect_corners(fbo);
 if (epoxy_has_gl_extension("GL_OES_EGL_image_external")) {
  g_assert_cmpuint(v.external_program,!=,0);
  g_assert_true(bind_egl_source(&v,image,TRUE));
  g_assert_true(copy_dma(&v));
  glBindFramebuffer(GL_FRAMEBUFFER,fbo);glViewport(0,0,4,4);
  draw(&v,v.texture,full,v.flip);expect_corners(fbo);
  puts("External EGLImage sampler and presentation copy passed.");
 } else puts("External EGLImage sampler unavailable in this GL context; external sampling test skipped.");
 puts("Real EGLImage binding, stale GL error isolation and presentation corners passed.");
 g_assert_true(eglDestroyImageKHR(display,image));glDeleteTextures(1,&original);
 discard_source(&v);
 /* Force the reported 2D error, then require a real renderbuffer import and
  * blit to recover both cropped orientations, including repeated updates. */
 GLuint external=v.external_program;v.external_program=0;reject_texture_binding=1;
 for (int top=0;top<=1;top++) {
  guint8 pixels[8][6][4]={0};
  for (int y=0;y<4;y++) for (int x=0;x<4;x++) {
   int row=top?1-y/2:y/2;memcpy(pixels[y+2][x+1],software[row*2+x/2],4);
  }
  glGenTextures(1,&original);glBindTexture(GL_TEXTURE_2D,original);
  glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,6,8,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
  image=eglCreateImageKHR(display,eglGetCurrentContext(),EGL_GL_TEXTURE_2D_KHR,(EGLClientBuffer)(uintptr_t)original,NULL);
  g_assert_true(image!=EGL_NO_IMAGE_KHR);
  g_assert_true(bind_egl_image(&v,image,0x34325241,MOD_INVALID,1));
  g_assert_cmpuint(v.source,==,0);g_assert_cmpuint(v.source_renderbuffer,!=,0);
  dma_geometry(&v,1,2,4,4,6,8,top);
  for (int update=0;update<2;update++) {
   glBindFramebuffer(GL_FRAMEBUFFER,fbo);glViewport(0,0,4,4);
   g_assert_true(copy_dma(&v));
   GLint read,write;glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&read);glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&write);
   g_assert_cmpuint(read,==,fbo);g_assert_cmpuint(write,==,fbo);
   draw(&v,v.texture,full,v.flip);expect_corners(fbo);
  }
  discard_source(&v);g_assert_cmpuint(v.source_fbo,==,0);g_assert_cmpuint(v.source_renderbuffer,==,0);
  g_assert_true(eglDestroyImageKHR(display,image));glDeleteTextures(1,&original);
 }
 reject_texture_binding=0;v.external_program=external;
 puts("Rejected 2D image binding recovered through real EGL renderbuffer GPU blits: both orientations/crops, repeated updates, framebuffer restoration and source cleanup passed.");
 glDeleteProgram(v.external_program);
 glDeleteTextures(1,&v.source);glDeleteTextures(1,&v.texture);glDeleteTextures(1,&target);
 glDeleteFramebuffers(1,&fbo);glDeleteFramebuffers(1,&v.fbo);
 glDeleteVertexArrays(1,&v.vao);glDeleteProgram(v.program);
 gtk_window_destroy(GTK_WINDOW(window));
 puts("Desktop OpenGL, both DMA orientations/crops and software frame corners passed without GDK_DEBUG.");
 return 0;
}
