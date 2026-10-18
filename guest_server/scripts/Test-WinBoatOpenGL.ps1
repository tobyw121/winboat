<#
.SYNOPSIS
Read actual OpenGL capabilities in the interactive desktop (Minecraft Java).
Run from ordinary Windows PowerShell, not the guest service's SYSTEM/session 0.
For a 32-bit Java installation, run this with SysWOW64\WindowsPowerShell\v1.0\powershell.exe.
#>
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not ('WinBoat.OpenGLGameProbe' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace WinBoat {
    public sealed class OpenGLGameResult {
        public string version, renderer, vendor;
        public bool openGl33Core, process64Bit;
        public int sessionId;
    }
    public static class OpenGLGameProbe {
        [StructLayout(LayoutKind.Sequential)]
        struct PixelFormat {
            public ushort size, version;
            public uint flags;
            public byte pixelType, colorBits, redBits, redShift, greenBits, greenShift,
                blueBits, blueShift, alphaBits, alphaShift, accumBits, accumRedBits,
                accumGreenBits, accumBlueBits, accumAlphaBits, depthBits, stencilBits,
                auxBuffers, layerType, reserved;
            public uint layerMask, visibleMask, damageMask;
        }
        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style,
            int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr window);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr window, IntPtr dc);
        [DllImport("gdi32.dll", SetLastError=true)] static extern int ChoosePixelFormat(IntPtr dc, ref PixelFormat format);
        [DllImport("gdi32.dll", SetLastError=true)] static extern bool SetPixelFormat(IntPtr dc, int index, ref PixelFormat format);
        [DllImport("opengl32.dll", SetLastError=true)] static extern IntPtr wglCreateContext(IntPtr dc);
        [DllImport("opengl32.dll")] static extern bool wglDeleteContext(IntPtr context);
        [DllImport("opengl32.dll", SetLastError=true)] static extern bool wglMakeCurrent(IntPtr dc, IntPtr context);
        [DllImport("opengl32.dll")] static extern IntPtr wglGetCurrentContext();
        [DllImport("opengl32.dll")] static extern IntPtr wglGetCurrentDC();
        [DllImport("opengl32.dll", CharSet=CharSet.Ansi)] static extern IntPtr wglGetProcAddress(string name);
        [DllImport("opengl32.dll")] static extern IntPtr glGetString(uint name);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        delegate IntPtr CreateCore(IntPtr dc, IntPtr share, int[] attributes);
        public static OpenGLGameResult Run() {
            int session = Process.GetCurrentProcess().SessionId;
            if(session == 0) throw new InvalidOperationException("Run the OpenGL probe from the logged-in Windows desktop, not session 0.");
            IntPtr window=IntPtr.Zero, dc=IntPtr.Zero, context=IntPtr.Zero;
            IntPtr previousContext=wglGetCurrentContext(), previousDC=wglGetCurrentDC();
            try {
                window=CreateWindowExW(0,"STATIC","WinBoat OpenGL probe",0,0,0,64,64,
                    IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
                if(window==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                dc=GetDC(window);
                if(dc==IntPtr.Zero) throw new InvalidOperationException("Cannot create a desktop device context.");
                PixelFormat format=new PixelFormat();
                format.size=(ushort)Marshal.SizeOf(typeof(PixelFormat)); format.version=1;
                format.flags=0x25; format.colorBits=32; format.depthBits=24; format.stencilBits=8;
                int index=ChoosePixelFormat(dc,ref format);
                if(index==0 || !SetPixelFormat(dc,index,ref format)) throw new Win32Exception(Marshal.GetLastWin32Error());
                context=wglCreateContext(dc);
                if(context==IntPtr.Zero || !wglMakeCurrent(dc,context)) throw new Win32Exception(Marshal.GetLastWin32Error());
                bool core33=false;
                IntPtr address=wglGetProcAddress("wglCreateContextAttribsARB");
                long value=address.ToInt64();
                if(value!=0 && value!=1 && value!=2 && value!=3 && value!=-1){
                    CreateCore create=(CreateCore)Marshal.GetDelegateForFunctionPointer(address,typeof(CreateCore));
                    // Request a real 3.3 core context, not an overridden version string.
                    IntPtr core=create(dc,IntPtr.Zero,new int[]{0x2091,3,0x2092,3,0x9126,1,0});
                    if(core!=IntPtr.Zero){
                        if(wglMakeCurrent(dc,core)){wglDeleteContext(context);context=core;core33=true;}
                        else {wglDeleteContext(core);if(!wglMakeCurrent(dc,context)) throw new Win32Exception(Marshal.GetLastWin32Error());}
                    }
                }
                OpenGLGameResult result=new OpenGLGameResult();
                result.version=Marshal.PtrToStringAnsi(glGetString(0x1F02));
                result.renderer=Marshal.PtrToStringAnsi(glGetString(0x1F01));
                result.vendor=Marshal.PtrToStringAnsi(glGetString(0x1F00));
                result.openGl33Core=core33; result.process64Bit=Environment.Is64BitProcess; result.sessionId=session;
                return result;
            } finally {
                wglMakeCurrent(previousDC,previousContext);
                if(context!=IntPtr.Zero) wglDeleteContext(context);
                if(dc!=IntPtr.Zero) ReleaseDC(window,dc);
                if(window!=IntPtr.Zero) DestroyWindow(window);
            }
        }
    }
}
'@
}
[WinBoat.OpenGLGameProbe]::Run() | ConvertTo-Json
