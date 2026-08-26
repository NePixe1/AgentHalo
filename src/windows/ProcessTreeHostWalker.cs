using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace CodexHalo
{
    public sealed class HostProcessRecord
    {
        public int ProcessId;
        public int ParentProcessId;
        public string Name;
        public bool IsRegularApp;
    }

    public static class ProcessTreeHostWalker
    {
        public const int MaxDepth = 32;

        private static readonly HashSet<string> SkipNames = new HashSet<string>(
            StringComparer.Ordinal)
        {
            "claude", "grok", "pi", "agy", "node", "bun",
            "conhost", "openconsole", "wslrelay", "wslhost",
            "language_server", "agenthalo", "agenthalomac"
        };

        public static bool ShouldSkipName(string name)
        {
            string normalized = Normalize(name);
            if (SkipNames.Contains(normalized))
            {
                return true;
            }
            return normalized.EndsWith(" helper", StringComparison.Ordinal);
        }

        public static bool IsKnownGuiName(string name)
        {
            string normalized = Normalize(name);
            return normalized == "windowsterminal"
                || normalized == "code"
                || normalized == "cursor"
                || normalized == "devenv"
                || normalized == "wezterm-gui"
                || normalized == "tabby"
                || normalized == "alacritty"
                || normalized == "hyper"
                || normalized == "fluentterminal";
        }

        public static int ResolveHost(
            int startingProcessId,
            IDictionary<int, HostProcessRecord> processes,
            int selfProcessId)
        {
            if (processes == null)
            {
                return 0;
            }
            int current = startingProcessId;
            HashSet<int> visited = new HashSet<int>();
            int depth = 0;
            while (current > 1 && depth < MaxDepth)
            {
                if (visited.Contains(current))
                {
                    return 0;
                }
                visited.Add(current);
                HostProcessRecord record;
                if (!processes.TryGetValue(current, out record) || record == null)
                {
                    return 0;
                }
                bool skipSelf = record.ProcessId == selfProcessId;
                if (!skipSelf && !ShouldSkipName(record.Name) && record.IsRegularApp)
                {
                    return record.ProcessId;
                }
                current = record.ParentProcessId;
                depth += 1;
            }
            return 0;
        }

        private static string Normalize(string name)
        {
            if (String.IsNullOrEmpty(name))
            {
                return String.Empty;
            }
            string value = Path.GetFileName(name).ToLowerInvariant();
            if (value.EndsWith(".exe", StringComparison.Ordinal))
            {
                value = value.Substring(0, value.Length - 4);
            }
            return value;
        }
    }

    public static class HostProcessTable
    {
        public static Dictionary<int, HostProcessRecord> Live()
        {
            Dictionary<int, HostProcessRecord> result =
                new Dictionary<int, HostProcessRecord>();
            IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
            if (snapshot == new IntPtr(-1))
            {
                return result;
            }
            try
            {
                ProcessEntry entry = new ProcessEntry();
                entry.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry));
                if (!Process32First(snapshot, ref entry))
                {
                    return result;
                }
                do
                {
                    int processId = (int)entry.ProcessId;
                    string name = entry.ExecutableFile;
                    bool hasMainWindow = false;
                    try
                    {
                        using (Process process = Process.GetProcessById(processId))
                        {
                            hasMainWindow = process.MainWindowHandle != IntPtr.Zero;
                        }
                    }
                    catch
                    {
                    }
                    result[processId] = new HostProcessRecord
                    {
                        ProcessId = processId,
                        ParentProcessId = (int)entry.ParentProcessId,
                        Name = name,
                        IsRegularApp = hasMainWindow ||
                            ProcessTreeHostWalker.IsKnownGuiName(name)
                    };
                    entry.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry));
                }
                while (Process32Next(snapshot, ref entry));
            }
            finally
            {
                CloseHandle(snapshot);
            }
            return result;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct ProcessEntry
        {
            public uint Size;
            public uint Usage;
            public uint ProcessId;
            public IntPtr DefaultHeapId;
            public uint ModuleId;
            public uint Threads;
            public uint ParentProcessId;
            public int BasePriority;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string ExecutableFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry entry);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry entry);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
