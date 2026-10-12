using System;
using System.Runtime.InteropServices;

namespace CodexHalo
{
    internal static class WindowsProcessProbe
    {
        internal static bool TryGetLiveStartTime(int pid, out DateTime started)
        {
            started = DateTime.MinValue;
            if (pid <= 0) return false;
            // Limited query rights work across elevation without requesting terminate/synchronize rights.
            IntPtr handle = OpenProcess(0x1000, false, pid);
            if (handle == IntPtr.Zero) return false;
            try
            {
                uint exitCode;
                long creation, exit, kernel, user;
                if (!GetExitCodeProcess(handle, out exitCode) || exitCode != 259 ||
                    !GetProcessTimes(handle, out creation, out exit, out kernel, out user)) return false;
                started = DateTime.FromFileTimeUtc(creation);
                return true;
            }
            finally { CloseHandle(handle); }
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
