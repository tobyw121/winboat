using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace WinBoat {
    // Read-only, bounded inspection. Never emit paths, user SIDs, window titles,
    // command lines, lock names, memory contents or unrelated process identities.
    public static class AtlasProcessDiagnostics {
        [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetThreadDesktop(uint thread);
        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder name, int length, out int needed);
        [StructLayout(LayoutKind.Explicit, Size=280)]
        struct WaitNode {
            [FieldOffset(0)] public int kind;
            [FieldOffset(4)] public int status;
            [FieldOffset(8)] public uint processId;
            [FieldOffset(12)] public uint threadId;
        }
        [DllImport("advapi32.dll", SetLastError=true)] static extern IntPtr OpenThreadWaitChainSession(uint flags, IntPtr callback);
        [DllImport("advapi32.dll")] static extern void CloseThreadWaitChainSession(IntPtr session);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GetThreadWaitChain(IntPtr session, IntPtr context, uint flags, uint thread,
            ref uint count, [In,Out] WaitNode[] nodes, [MarshalAs(UnmanagedType.Bool)] out bool cycle);

        public static string ClassifyDesktop(string name) {
            if (String.Equals(name, "Default", StringComparison.OrdinalIgnoreCase)) return "default";
            if (String.Equals(name, "Winlogon", StringComparison.OrdinalIgnoreCase)) return "winlogon";
            return "other";
        }
        static string Desktop(uint thread) {
            IntPtr handle=GetThreadDesktop(thread);
            if (handle==IntPtr.Zero) return "unavailable";
            int needed;
            var text=new StringBuilder(256);
            // HDESK belongs to the thread, and must not be closed here.
            return GetUserObjectInformation(handle, 2, text, text.Capacity*2, out needed)
                ? ClassifyDesktop(text.ToString()) : "unavailable";
        }
        static object WaitChain(uint thread, uint pid) {
            IntPtr handle=OpenThreadWaitChainSession(0, IntPtr.Zero);
            if (handle==IntPtr.Zero) return new { available=false, errorCode=Marshal.GetLastWin32Error() };
            try {
                uint count=16; bool cycle;
                var nodes=new WaitNode[16];
                if (!GetThreadWaitChain(handle, IntPtr.Zero, 1, thread, ref count, nodes, out cycle))
                    return new { available=false, errorCode=Marshal.GetLastWin32Error() };
                var safe=new List<object>();
                for (int i=0; i<Math.Min(count,16); i++) {
                    // A union contains a name for lock nodes: never interpret it
                    // as IDs or copy it into managed diagnostic output.
                    safe.Add(new { kind=nodes[i].kind, status=nodes[i].status,
                        sameProcess=nodes[i].kind==8 ? (bool?)(nodes[i].processId==pid) : null });
                }
                return new { available=true, cycle=cycle, nodes=safe };
            } finally { CloseThreadWaitChainSession(handle); }
        }
        public static object Inspect(uint pid, string executable, string setupSid) {
            var result=new Dictionary<string,object>();
            result["processId"]=pid;
            try {
                using (var process=Process.GetProcessById(checked((int)pid))) {
                    IntPtr processHandle=process.Handle;
                    result["sessionMatchesConsole"]=process.SessionId==WTSGetActiveConsoleSessionId();
                    bool expected=process.MainModule!=null && String.Equals(Path.GetFullPath(process.MainModule.FileName),
                        Path.GetFullPath(executable), StringComparison.OrdinalIgnoreCase);
                    result["expectedExecutable"]=expected;
                    if (!expected) return result;
                    result["ageSeconds"]=Math.Round((DateTime.UtcNow-process.StartTime.ToUniversalTime()).TotalSeconds);
                    IntPtr token;
                    if (!OpenProcessToken(processHandle, 8, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    try {
                        using (var identity=new WindowsIdentity(token)) {
                            string sid=identity.User==null ? "" : identity.User.Value;
                            result["ownerKind"]=sid==setupSid ? "setup-account" : sid=="S-1-5-18" ? "system" : "other";
                        }
                    } finally { CloseHandle(token); }
                    var modules=new List<string>();
                    foreach (ProcessModule module in process.Modules) {
                        string name=module.ModuleName.ToLowerInvariant();
                        if (Array.IndexOf(new[] {"coreclr.dll","microsoft.ui.xaml.dll","d3d11.dll","dxgi.dll","dcomp.dll","microsoft.windowsappruntime.bootstrap.dll"}, name)>=0)
                            modules.Add(name);
                    }
                    result["runtimeModules"]=modules;
                    result["cpuMilliseconds"]=Math.Round(process.TotalProcessorTime.TotalMilliseconds);
                    result["threadCount"]=process.Threads.Count;
                    var threads=new List<object>();
                    ProcessThread first=null;
                    foreach (ProcessThread thread in process.Threads) {
                        if (first==null || thread.StartTime<first.StartTime) first=thread;
                        if (threads.Count>=8) continue;
                        threads.Add(new { state=thread.ThreadState.ToString(),
                            waitReason=thread.ThreadState==System.Diagnostics.ThreadState.Wait ? thread.WaitReason.ToString() : "none",
                            desktop=Desktop((uint)thread.Id) });
                    }
                    result["threads"]=threads;
                    // One chain only, not every thread: keep API latency bounded.
                    if (first!=null) result["initialThreadWaitChain"]=WaitChain((uint)first.Id,pid);
                }
            } catch (Win32Exception e) { result["errorCode"]=e.NativeErrorCode; }
              catch (Exception e) { result["errorCode"]=e.HResult; }
            return result;
        }
    }
}
