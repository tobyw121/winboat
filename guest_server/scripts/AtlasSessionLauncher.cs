using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace WinBoat {
    // Start the original UI as the existing setup user, never as SYSTEM or a
    // different logged-on user. No password, new logon, or profile creation.
    public static class AtlasSessionLauncher {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct StartupInfo {
            public int cb;
            public string reserved, desktop, title;
            public uint x, y, width, height, xChars, yChars, fill, flags;
            public short showWindow, reserved2;
            public IntPtr reservedPtr, stdin, stdout, stderr;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInfo { public IntPtr process, thread; public uint processId, threadId; }
        public sealed class Result { public uint ProcessId, SessionId; public uint? EarlyExitCode; }
        [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] static extern bool WTSQueryUserToken(uint session, out IntPtr token);
        [DllImport("userenv.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);
        [DllImport("userenv.dll")] static extern bool DestroyEnvironmentBlock(IntPtr environment);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] static extern bool CreateProcessAsUser(
            IntPtr token, string application, StringBuilder command, IntPtr processAttributes,
            IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment,
            string directory, ref StartupInfo startup, out ProcessInfo process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
        public static Result Start(string executable, string setupSid) { return Run(executable, setupSid, true); }
        public static void ValidateSession(string setupSid) { Run(null, setupSid, false); }
        static Result Run(string executable, string setupSid, bool launch) {
            uint session = WTSGetActiveConsoleSessionId();
            IntPtr token = IntPtr.Zero, environment = IntPtr.Zero;
            ProcessInfo process = new ProcessInfo();
            try {
                if (session == UInt32.MaxValue) throw new Win32Exception(1008);
                if (!WTSQueryUserToken(session, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
                using (var identity = new WindowsIdentity(token)) {
                    if (identity.User == null || identity.User.Value != setupSid)
                        throw new InvalidOperationException("The active session is not the temporary setup account.");
                    if (!launch) return new Result { SessionId = session };
                    if (!CreateEnvironmentBlock(out environment, token, false))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    var startup = new StartupInfo { cb = Marshal.SizeOf(typeof(StartupInfo)),
                        desktop = @"winsta0\default", flags = 1, showWindow = 1 };
                    if (!CreateProcessAsUser(token, executable, new StringBuilder("\"" + executable + "\" --oobe"),
                        IntPtr.Zero, IntPtr.Zero, false, 0x400, environment,
                        System.IO.Path.GetDirectoryName(executable), ref startup, out process))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    var result = new Result { ProcessId = process.processId, SessionId = session };
                    uint wait = WaitForSingleObject(process.process, 2000);
                    if (wait == UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                    if (wait == 0) {
                        uint code;
                        if (!GetExitCodeProcess(process.process, out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
                        result.EarlyExitCode = code;
                    }
                    return result;
                }
            } finally {
                if (process.thread != IntPtr.Zero) CloseHandle(process.thread);
                if (process.process != IntPtr.Zero) CloseHandle(process.process);
                if (environment != IntPtr.Zero) DestroyEnvironmentBlock(environment);
                if (token != IntPtr.Zero) CloseHandle(token);
            }
        }
    }
}
