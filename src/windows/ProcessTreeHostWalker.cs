using System;
using System.Collections.Generic;
using System.IO;

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
            Dictionary<int, HostProcessRecord> processes,
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
}
