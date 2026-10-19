/* Real WGL clear/readback over odd dimensions; no generic software fallback. */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    DWORD session=0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(),&session) || !session) return 2;
    WNDCLASSW wc={0};wc.style=CS_OWNDC;wc.lpfnWndProc=DefWindowProcW;
    wc.hInstance=GetModuleHandleW(NULL);wc.lpszClassName=L"HeliosPixelAcceptance";
    if (!RegisterClassW(&wc)) return 3;
    HWND window=CreateWindowW(wc.lpszClassName,L"Helios OpenGL pixel test",WS_OVERLAPPEDWINDOW,
                             0,0,256,256,NULL,NULL,wc.hInstance,NULL);
    if (!window) return 4;
    HDC dc=GetDC(window);
    PIXELFORMATDESCRIPTOR pf={0};pf.nSize=sizeof(pf);pf.nVersion=1;
    pf.dwFlags=PFD_DRAW_TO_WINDOW|PFD_SUPPORT_OPENGL|PFD_DOUBLEBUFFER;
    pf.iPixelType=PFD_TYPE_RGBA;pf.cColorBits=24;
    int format=ChoosePixelFormat(dc,&pf);
    if (!format || !SetPixelFormat(dc,format,&pf)) return 5;
    HGLRC context=wglCreateContext(dc);
    if (!context || !wglMakeCurrent(dc,context)) return 6;
    const char *renderer=(const char *)glGetString(GL_RENDERER);
    if (!renderer || !strcmp(renderer,"GDI Generic") || !GetModuleHandleW(L"libgallium_wgl.dll")) {
        fputs("Helios OpenGL ICD was not loaded.\n",stderr);return 7;
    }
    printf("OpenGL renderer: %s\n",renderer);
    const int sizes[2][2]={{31,17},{127,65}};
    unsigned char pixels[127*65*4];
    int result=0;
    for (int pass=0;pass<2 && !result;pass++) {
        const int width=sizes[pass][0],height=sizes[pass][1];
        glViewport(0,0,width,height);glReadBuffer(GL_BACK);
        glClearColor(pass?0.0f:1.0f,pass?1.0f:0.0f,0.0f,1.0f);
        glClear(GL_COLOR_BUFFER_BIT);glFinish();
        glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
        if (glGetError()!=GL_NO_ERROR) {result=8;break;}
        for (int i=0;i<width*height;i++) {
            if (pixels[i*4]!=(pass?0:255) || pixels[i*4+1]!=(pass?255:0) || pixels[i*4+2]!=0) {result=9;break;}
        }
        if (!SwapBuffers(dc)) result=10;
    }
    wglMakeCurrent(NULL,NULL);wglDeleteContext(context);ReleaseDC(window,dc);
    DestroyWindow(window);UnregisterClassW(wc.lpszClassName,wc.hInstance);
    if (!result) puts("OpenGL clear/readback: all pixels matched in both dimensions.");
    return result;
}
