using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    internal static class PiExtensionConfigurator
    {
        internal const string ResourceName = "AgentHalo.PiStatusExtension";

        public static string Configure(string userProfile = null)
        {
            string root = ResolveAgentRoot(userProfile);
            string target = Path.Combine(root, "extensions", "agent-halo-status.ts");
            try
            {
                string source = ReadEmbeddedSource();
                if (String.IsNullOrWhiteSpace(source))
                {
                    return null;
                }
                if (File.Exists(target) && String.Equals(
                    File.ReadAllText(target, Encoding.UTF8), source,
                    StringComparison.Ordinal))
                {
                    return target;
                }
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                string temp = target + ".tmp";
                File.WriteAllText(temp, source, new UTF8Encoding(false));
                if (File.Exists(target))
                {
                    File.Delete(target);
                }
                File.Move(temp, target);
                return target;
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Pi extension configure failed: " + ex.Message);
                return null;
            }
        }

        internal static string ResolveAgentRoot(string userProfile = null)
        {
            string root = Environment.GetEnvironmentVariable("PI_CODING_AGENT_DIR");
            if (!String.IsNullOrWhiteSpace(root))
            {
                return root;
            }
            string home = String.IsNullOrWhiteSpace(userProfile)
                ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
                : userProfile;
            return Path.Combine(home, ".pi", "agent");
        }

        internal static string ReadEmbeddedSource()
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream stream = assembly.GetManifestResourceStream(ResourceName))
            {
                if (stream == null)
                {
                    return null;
                }
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                {
                    return reader.ReadToEnd();
                }
            }
        }
    }

    internal sealed class PiStatusRecord
    {
        public string SessionId;
        public string State;
        public string Event;
        public string WorkingDirectory;
        public string Provider;
        public string Model;
        public string ToolName;
        public string ErrorMessage;
        public int ProcessId;
        public DateTime TimestampUtc;
        public long InputTokens;
        public long OutputTokens;
        public long CacheReadTokens;
        public long ContextTokens;
        public long ContextWindowTokens;
    }

    internal sealed class PiSessionEvidence
    {
        public string SessionId;
        public string WorkingDirectory;
        public string Path;
        public DateTime CreatedUtc;
        public DateTime LastWriteUtc;
        public long Length;
        public string Provider;
        public string Model;
        public long InputTokens;
        public long OutputTokens;
        public long CacheReadTokens;
        public long ContextTokens;
        public long ContextWindowTokens;
    }

    internal sealed class PiRuntimeProcess
    {
        public int ProcessId;
        public int ParentProcessId;
        public string Name;
        public DateTime StartedUtc;
    }

    /// <summary>
    /// Presence fallback for Pi sessions that were already running before the
    /// Agent Halo extension was installed. Hook records remain authoritative;
    /// this reader only decides whether Pi itself is still online.
    /// </summary>
    internal sealed class PiRuntimeMonitor
    {
        private static readonly TimeSpan CheckInterval = TimeSpan.FromSeconds(2);
        private static readonly TimeSpan SessionEvidenceLifetime = TimeSpan.FromDays(3);
        private readonly string agentRoot;
        private DateTime nextCheckUtc = DateTime.MinValue;
        private bool running;
        private PiSessionEvidence latestSession;

        public PiRuntimeMonitor()
            : this(PiExtensionConfigurator.ResolveAgentRoot())
        {
        }

        internal PiRuntimeMonitor(string root)
        {
            agentRoot = root;
        }

        public bool IsRunning
        {
            get { return running; }
        }

        public bool Refresh()
        {
            DateTime now = DateTime.UtcNow;
            if (now < nextCheckUtc)
            {
                return false;
            }
            nextCheckUtc = now.Add(CheckInterval);
            string before = RuntimeFingerprint(running, latestSession);
            try
            {
                latestSession = ReadLatestSession(agentRoot, latestSession);
                running = IsRunningForTest(latestSession, now, ReadProcesses());
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Pi runtime detection failed: " + ex.Message);
                running = false;
                latestSession = null;
            }
            return !String.Equals(before, RuntimeFingerprint(running, latestSession),
                StringComparison.Ordinal);
        }

        public SessionSnapshot Snapshot()
        {
            if (!running || latestSession == null)
            {
                return null;
            }
            return new SessionSnapshot
            {
                ThreadId = latestSession.SessionId,
                ProjectName = ProjectName(latestSession.WorkingDirectory),
                WorkingDirectory = latestSession.WorkingDirectory,
                State = HaloState.Idle,
                Action = "Ready",
                LastEventUtc = latestSession.LastWriteUtc,
                Active = false,
                Agent = AgentKind.Pi,
                TurnPhase = AgentTurnPhase.None,
                Activity = AgentActivityKind.None,
                EvidenceSource = AgentEvidenceSource.PiExtension,
                EvidenceKind = "runtime-session",
                ModelName = latestSession.Model,
                ModelProvider = latestSession.Provider,
                TurnInputTokens = latestSession.InputTokens,
                TurnCachedInputTokens = latestSession.CacheReadTokens,
                TurnOutputTokens = latestSession.OutputTokens,
                ContextInputTokens = latestSession.ContextTokens,
                ContextWindowTokens = latestSession.ContextWindowTokens
            };
        }

        internal static bool IsRunningForTest(PiSessionEvidence session,
            DateTime nowUtc, IList<PiRuntimeProcess> processes)
        {
            if (session == null || processes == null ||
                session.LastWriteUtc == DateTime.MinValue ||
                session.LastWriteUtc > nowUtc.AddMinutes(5) ||
                nowUtc - session.LastWriteUtc > SessionEvidenceLifetime)
            {
                return false;
            }
            Dictionary<int, PiRuntimeProcess> byId = processes
                .Where(delegate(PiRuntimeProcess item)
                {
                    return item != null && item.ProcessId > 0;
                }).GroupBy(delegate(PiRuntimeProcess item) { return item.ProcessId; })
                .ToDictionary(delegate(IGrouping<int, PiRuntimeProcess> group)
                {
                    return group.Key;
                }, delegate(IGrouping<int, PiRuntimeProcess> group)
                {
                    return group.First();
                });
            foreach (PiRuntimeProcess process in byId.Values)
            {
                if (!IsNodeProcess(process.Name))
                {
                    continue;
                }
                PiRuntimeProcess parent;
                if (!byId.TryGetValue(process.ParentProcessId, out parent) ||
                    !IsShellProcess(parent.Name))
                {
                    continue;
                }
                // A Pi process may stay alive across several session files. A
                // session write after the process started ties the two together
                // without relying on command-line access, which can be denied
                // when Pi runs in an elevated terminal.
                if (process.StartedUtc == DateTime.MinValue ||
                    process.StartedUtc <= session.LastWriteUtc.AddSeconds(5))
                {
                    return true;
                }
            }
            return false;
        }

        internal static PiSessionEvidence ReadLatestSession(string root)
        {
            return ReadLatestSession(root, null);
        }

        private static PiSessionEvidence ReadLatestSession(string root,
            PiSessionEvidence previous)
        {
            string sessionsRoot = Path.Combine(root ?? String.Empty, "sessions");
            if (!Directory.Exists(sessionsRoot))
            {
                return null;
            }
            foreach (FileInfo file in Directory.EnumerateFiles(sessionsRoot, "*.jsonl",
                SearchOption.AllDirectories).Select(delegate(string path)
                {
                    return new FileInfo(path);
                }).OrderByDescending(delegate(FileInfo info)
                {
                    return info.LastWriteTimeUtc;
                }))
            {
                if (previous != null && String.Equals(previous.Path, file.FullName,
                    StringComparison.OrdinalIgnoreCase) &&
                    previous.LastWriteUtc == file.LastWriteTimeUtc &&
                    previous.Length == file.Length)
                {
                    return previous;
                }
                PiSessionEvidence evidence = ReadSession(file.FullName, root);
                if (evidence != null)
                {
                    return evidence;
                }
            }
            return null;
        }

        private static PiSessionEvidence ReadSession(string file, string root)
        {
            try
            {
                List<string> lines = new List<string>();
                using (FileStream stream = new FileStream(file, FileMode.Open,
                    FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
                {
                    string line;
                    while ((line = reader.ReadLine()) != null)
                    {
                        lines.Add(line);
                    }
                }
                if (lines.Count == 0)
                {
                    return null;
                }
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = Int32.MaxValue;
                Dictionary<string, object> data = serializer.DeserializeObject(lines[0])
                    as Dictionary<string, object>;
                object type;
                if (data == null || !data.TryGetValue("type", out type) ||
                    !String.Equals(Convert.ToString(type, CultureInfo.InvariantCulture),
                        "session", StringComparison.OrdinalIgnoreCase))
                {
                    return null;
                }
                object id;
                object cwd;
                FileInfo info = new FileInfo(file);
                PiSessionEvidence evidence = new PiSessionEvidence
                {
                    SessionId = data.TryGetValue("id", out id) && id != null
                        ? Convert.ToString(id, CultureInfo.InvariantCulture)
                        : Path.GetFileNameWithoutExtension(file),
                    WorkingDirectory = data.TryGetValue("cwd", out cwd) && cwd != null
                        ? Convert.ToString(cwd, CultureInfo.InvariantCulture) : null,
                    Path = file,
                    CreatedUtc = info.CreationTimeUtc,
                    LastWriteUtc = info.LastWriteTimeUtc,
                    Length = info.Length,
                    // -1 means "unknown" so a models.json window alone cannot
                    // produce a fake 0% context pill.
                    ContextTokens = -1
                };
                string changedProvider = null;
                string changedModel = null;
                for (int index = lines.Count - 1; index > 0; index--)
                {
                    string line = lines[index];
                    if (line.IndexOf("\"role\":\"assistant\"",
                        StringComparison.OrdinalIgnoreCase) < 0 &&
                        line.IndexOf("\"type\":\"model_change\"",
                            StringComparison.OrdinalIgnoreCase) < 0)
                    {
                        continue;
                    }
                    Dictionary<string, object> entry;
                    try
                    {
                        entry = serializer.DeserializeObject(line)
                            as Dictionary<string, object>;
                    }
                    catch
                    {
                        continue;
                    }
                    if (entry == null)
                    {
                        continue;
                    }
                    string entryType = GetString(entry, "type");
                    if (String.Equals(entryType, "model_change",
                        StringComparison.OrdinalIgnoreCase))
                    {
                        if (String.IsNullOrWhiteSpace(changedModel))
                        {
                            changedProvider = GetString(entry, "provider");
                            changedModel = GetString(entry, "modelId");
                        }
                        continue;
                    }
                    Dictionary<string, object> message = GetDictionary(entry, "message");
                    if (message == null || !String.Equals(GetString(message, "role"),
                        "assistant", StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }
                    evidence.Provider = String.IsNullOrWhiteSpace(changedProvider)
                        ? GetString(message, "provider") : changedProvider;
                    evidence.Model = String.IsNullOrWhiteSpace(changedModel)
                        ? GetString(message, "model") : changedModel;
                    Dictionary<string, object> usage = GetDictionary(message, "usage");
                    if (usage != null)
                    {
                        evidence.InputTokens = GetLong(usage, "input");
                        evidence.OutputTokens = GetLong(usage, "output");
                        evidence.CacheReadTokens = GetLong(usage, "cacheRead");
                        evidence.ContextTokens = GetLong(usage, "totalTokens");
                        if (evidence.ContextTokens <= 0)
                        {
                            evidence.ContextTokens = evidence.InputTokens +
                                evidence.OutputTokens + evidence.CacheReadTokens +
                                GetLong(usage, "cacheWrite");
                        }
                    }
                    break;
                }
                if (String.IsNullOrWhiteSpace(evidence.Model) &&
                    !String.IsNullOrWhiteSpace(changedModel))
                {
                    evidence.Provider = changedProvider;
                    evidence.Model = changedModel;
                }
                if (evidence.ContextTokens >= 0)
                {
                    evidence.ContextWindowTokens = ReadContextWindow(root,
                        evidence.Provider, evidence.Model);
                }
                return evidence;
            }
            catch
            {
                return null;
            }
        }

        private static long ReadContextWindow(string root, string provider, string model)
        {
            if (String.IsNullOrWhiteSpace(model))
            {
                return 0;
            }
            foreach (string name in new string[] { "models.json", "models-store.json" })
            {
                string path = Path.Combine(root ?? String.Empty, name);
                if (!File.Exists(path))
                {
                    continue;
                }
                try
                {
                    object parsed = new JavaScriptSerializer().DeserializeObject(
                        File.ReadAllText(path, Encoding.UTF8));
                    long value = FindContextWindow(parsed, provider, model, null);
                    if (value > 0)
                    {
                        return value;
                    }
                }
                catch
                {
                }
            }
            return 0;
        }

        private static long FindContextWindow(object node, string provider,
            string model, string inheritedProvider)
        {
            Dictionary<string, object> data = node as Dictionary<string, object>;
            if (data != null)
            {
                string currentProvider = GetString(data, "provider");
                if (String.IsNullOrWhiteSpace(currentProvider))
                {
                    currentProvider = inheritedProvider;
                }
                string id = GetString(data, "id");
                if (String.IsNullOrWhiteSpace(id)) id = GetString(data, "model");
                if (String.IsNullOrWhiteSpace(id)) id = GetString(data, "modelId");
                if (String.Equals(id, model, StringComparison.OrdinalIgnoreCase) &&
                    (String.IsNullOrWhiteSpace(provider) ||
                     String.IsNullOrWhiteSpace(currentProvider) ||
                     String.Equals(currentProvider, provider,
                         StringComparison.OrdinalIgnoreCase)))
                {
                    long value = GetLong(data, "contextWindow");
                    if (value <= 0) value = GetLong(data, "context_window");
                    if (value > 0)
                    {
                        return value;
                    }
                }
                object providersValue;
                Dictionary<string, object> providers = data.TryGetValue("providers",
                    out providersValue) ? providersValue as Dictionary<string, object> : null;
                if (providers != null)
                {
                    foreach (KeyValuePair<string, object> pair in providers)
                    {
                        long value = FindContextWindow(pair.Value, provider, model,
                            pair.Key);
                        if (value > 0) return value;
                    }
                }
                foreach (KeyValuePair<string, object> pair in data)
                {
                    if (String.Equals(pair.Key, "providers",
                        StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }
                    string childProvider = currentProvider;
                    Dictionary<string, object> child =
                        pair.Value as Dictionary<string, object>;
                    if (child != null && child.ContainsKey("models") &&
                        String.IsNullOrWhiteSpace(childProvider))
                    {
                        childProvider = pair.Key;
                    }
                    long value = FindContextWindow(pair.Value, provider, model,
                        childProvider);
                    if (value > 0) return value;
                }
                return 0;
            }
            object[] items = node as object[];
            if (items != null)
            {
                foreach (object item in items)
                {
                    long value = FindContextWindow(item, provider, model,
                        inheritedProvider);
                    if (value > 0) return value;
                }
            }
            return 0;
        }

        private static Dictionary<string, object> GetDictionary(
            Dictionary<string, object> data, string key)
        {
            object value;
            return data != null && data.TryGetValue(key, out value)
                ? value as Dictionary<string, object> : null;
        }

        private static string GetString(Dictionary<string, object> data, string key)
        {
            object value;
            return data != null && data.TryGetValue(key, out value) && value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture) : null;
        }

        private static long GetLong(Dictionary<string, object> data, string key)
        {
            object value;
            long result;
            return data != null && data.TryGetValue(key, out value) && value != null &&
                Int64.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                    NumberStyles.Any, CultureInfo.InvariantCulture, out result)
                ? result : 0;
        }

        private static string RuntimeFingerprint(bool isRunning,
            PiSessionEvidence session)
        {
            if (session == null)
            {
                return isRunning ? "1" : "0";
            }
            return (isRunning ? "1" : "0") + "|" + session.SessionId + "|" +
                session.LastWriteUtc.Ticks.ToString(CultureInfo.InvariantCulture) + "|" +
                session.Length.ToString(CultureInfo.InvariantCulture) + "|" +
                session.Model + "|" +
                session.ContextTokens.ToString(CultureInfo.InvariantCulture);
        }

        private static List<PiRuntimeProcess> ReadProcesses()
        {
            List<PiRuntimeProcess> result = new List<PiRuntimeProcess>();
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
                    DateTime started = DateTime.MinValue;
                    try
                    {
                        using (Process process = Process.GetProcessById((int)entry.ProcessId))
                        {
                            started = process.StartTime.ToUniversalTime();
                        }
                    }
                    catch
                    {
                    }
                    result.Add(new PiRuntimeProcess
                    {
                        ProcessId = (int)entry.ProcessId,
                        ParentProcessId = (int)entry.ParentProcessId,
                        Name = entry.ExecutableFile,
                        StartedUtc = started
                    });
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

        private static bool IsNodeProcess(string name)
        {
            string value = Path.GetFileNameWithoutExtension(name ?? String.Empty);
            return String.Equals(value, "node", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(value, "pi", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsShellProcess(string name)
        {
            string value = Path.GetFileNameWithoutExtension(name ?? String.Empty);
            return String.Equals(value, "pwsh", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(value, "powershell", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(value, "cmd", StringComparison.OrdinalIgnoreCase);
        }

        private static string ProjectName(string workingDirectory)
        {
            if (String.IsNullOrWhiteSpace(workingDirectory))
            {
                return "Pi";
            }
            string trimmed = workingDirectory.TrimEnd(Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            string leaf = Path.GetFileName(trimmed);
            return String.IsNullOrWhiteSpace(leaf) ? "Pi" : leaf;
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

    public sealed class PiStatusMonitor
    {
        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();
        private readonly string path;
        private readonly Dictionary<string, PiStatusRecord> records =
            new Dictionary<string, PiStatusRecord>(StringComparer.OrdinalIgnoreCase);
        private long lastLength = -1;
        private DateTime lastWriteUtc = DateTime.MinValue;

        public PiStatusMonitor()
            : this(AgentHaloPaths.PiStatusLog())
        {
        }

        internal PiStatusMonitor(string statusPath)
        {
            path = statusPath;
        }

        public bool Refresh()
        {
            try
            {
                if (!File.Exists(path))
                {
                    if (records.Count == 0)
                    {
                        return false;
                    }
                    records.Clear();
                    lastLength = -1;
                    lastWriteUtc = DateTime.MinValue;
                    return true;
                }
                FileInfo info = new FileInfo(path);
                if (info.Length == lastLength && info.LastWriteTimeUtc == lastWriteUtc)
                {
                    return false;
                }
                Dictionary<string, PiStatusRecord> next = ReadLatest(path);
                // Log rotation renames the file and starts a fresh one that only
                // contains the next event from one session. Keep last-known
                // records for other still-live PIDs so multi-session rings do
                // not flash offline mid-turn.
                foreach (KeyValuePair<string, PiStatusRecord> pair in records)
                {
                    if (next.ContainsKey(pair.Key))
                    {
                        continue;
                    }
                    if (IsLive(pair.Value))
                    {
                        next[pair.Key] = pair.Value;
                    }
                }
                string before = Fingerprint(records.Values);
                string after = Fingerprint(next.Values);
                records.Clear();
                foreach (KeyValuePair<string, PiStatusRecord> pair in next)
                {
                    records[pair.Key] = pair.Value;
                }
                lastLength = info.Length;
                lastWriteUtc = info.LastWriteTimeUtc;
                return !String.Equals(before, after, StringComparison.Ordinal);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Pi status refresh failed: " + ex.Message);
                return false;
            }
        }

        public List<SessionSnapshot> Snapshots()
        {
            return records.Values.Select(ToSnapshot).Where(delegate(SessionSnapshot item)
            {
                return item != null;
            }).ToList();
        }

        public HashSet<string> LiveSessionIds()
        {
            return new HashSet<string>(records.Values
                .Where(IsLive)
                .Select(delegate(PiStatusRecord record) { return record.SessionId; }),
                StringComparer.OrdinalIgnoreCase);
        }

        private static Dictionary<string, PiStatusRecord> ReadLatest(string file)
        {
            Dictionary<string, PiStatusRecord> result =
                new Dictionary<string, PiStatusRecord>(StringComparer.OrdinalIgnoreCase);
            using (FileStream stream = new FileStream(file, FileMode.Open,
                FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    PiStatusRecord record = Parse(line);
                    if (record == null)
                    {
                        continue;
                    }
                    PiStatusRecord previous;
                    if (!result.TryGetValue(record.SessionId, out previous) ||
                        record.TimestampUtc >= previous.TimestampUtc)
                    {
                        result[record.SessionId] = record;
                    }
                }
            }
            return result;
        }

        internal static PiStatusRecord Parse(string line)
        {
            try
            {
                Dictionary<string, object> data = Serializer.DeserializeObject(line)
                    as Dictionary<string, object>;
                if (data == null || !String.Equals(GetString(data, "source"),
                    "pi-extension", StringComparison.OrdinalIgnoreCase))
                {
                    return null;
                }
                int pid = (int)GetLong(data, "pid");
                string sessionId = GetString(data, "sessionId");
                if (String.IsNullOrWhiteSpace(sessionId))
                {
                    sessionId = "pi-" + pid.ToString(CultureInfo.InvariantCulture);
                }
                DateTime timestamp;
                if (!DateTime.TryParse(GetString(data, "timestamp"),
                    CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind,
                    out timestamp))
                {
                    return null;
                }
                return new PiStatusRecord
                {
                    SessionId = sessionId,
                    State = GetString(data, "state"),
                    Event = GetString(data, "event"),
                    WorkingDirectory = GetString(data, "cwd"),
                    Provider = GetString(data, "provider"),
                    Model = GetString(data, "model"),
                    ToolName = GetString(data, "toolName"),
                    ErrorMessage = GetString(data, "errorMessage"),
                    ProcessId = pid,
                    TimestampUtc = timestamp.ToUniversalTime(),
                    InputTokens = GetLong(data, "inputTokens"),
                    OutputTokens = GetLong(data, "outputTokens"),
                    CacheReadTokens = GetLong(data, "cacheRead"),
                    // Null/missing context fields map to -1 (unknown), not 0.
                    // A window-only payload must not look like "0% used".
                    ContextTokens = GetOptionalLong(data, "contextTokens"),
                    ContextWindowTokens = GetOptionalLong(data, "contextWindow")
                };
            }
            catch
            {
                return null;
            }
        }

        private static SessionSnapshot ToSnapshot(PiStatusRecord record)
        {
            if (record == null || String.Equals(record.State, "offline",
                StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
            HaloState state = HaloState.Idle;
            AgentTurnPhase phase = AgentTurnPhase.None;
            AgentActivityKind activity = AgentActivityKind.None;
            bool active = false;
            DateTime completed = DateTime.MinValue;
            string action = "Ready";
            if (String.Equals(record.State, "thinking", StringComparison.OrdinalIgnoreCase))
            {
                state = HaloState.Thinking;
                phase = AgentTurnPhase.Thinking;
                activity = AgentActivityKind.Reasoning;
                action = "Thinking";
                active = true;
            }
            else if (String.Equals(record.State, "working", StringComparison.OrdinalIgnoreCase))
            {
                state = HaloState.Working;
                phase = AgentTurnPhase.Executing;
                activity = String.IsNullOrWhiteSpace(record.ToolName)
                    ? AgentActivityKind.WritingAnswer : AgentActivityKind.UsingTool;
                action = String.IsNullOrWhiteSpace(record.ToolName)
                    ? "Writing answer" : "Using tool: " + record.ToolName;
                active = true;
            }
            else if (String.Equals(record.State, "done", StringComparison.OrdinalIgnoreCase))
            {
                state = HaloState.Done;
                phase = AgentTurnPhase.Completed;
                action = "Complete";
                completed = record.TimestampUtc;
            }
            else if (String.Equals(record.State, "error", StringComparison.OrdinalIgnoreCase))
            {
                state = HaloState.Error;
                phase = AgentTurnPhase.Failed;
                action = String.IsNullOrWhiteSpace(record.ErrorMessage)
                    ? "Task failed" : record.ErrorMessage;
            }
            return new SessionSnapshot
            {
                ThreadId = record.SessionId,
                ProjectName = ProjectName(record.WorkingDirectory),
                WorkingDirectory = record.WorkingDirectory,
                State = state,
                Action = action,
                LastEventUtc = record.TimestampUtc,
                CompletedUtc = completed,
                Active = active,
                Agent = AgentKind.Pi,
                TurnPhase = phase,
                Activity = activity,
                EvidenceSource = AgentEvidenceSource.PiExtension,
                EvidenceKind = record.Event,
                ModelName = record.Model,
                ModelProvider = record.Provider,
                TurnInputTokens = record.InputTokens,
                TurnCachedInputTokens = record.CacheReadTokens,
                TurnOutputTokens = record.OutputTokens,
                ContextInputTokens = record.ContextTokens,
                ContextWindowTokens = record.ContextWindowTokens,
                FailureSeverity = state == HaloState.Error
                    ? AgentFailureSeverity.FatalTurn : AgentFailureSeverity.None
            };
        }

        private static bool IsLive(PiStatusRecord record)
        {
            if (record == null || record.ProcessId <= 0 ||
                String.Equals(record.State, "offline", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
            try
            {
                using (Process process = Process.GetProcessById(record.ProcessId))
                {
                    return !process.HasExited &&
                        process.StartTime.ToUniversalTime() <= record.TimestampUtc.AddSeconds(5);
                }
            }
            catch
            {
                return false;
            }
        }

        private static string ProjectName(string workingDirectory)
        {
            if (String.IsNullOrWhiteSpace(workingDirectory))
            {
                return "Pi";
            }
            string trimmed = workingDirectory.TrimEnd(Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            string leaf = Path.GetFileName(trimmed);
            return String.IsNullOrWhiteSpace(leaf) ? "Pi" : leaf;
        }

        private static string GetString(Dictionary<string, object> data, string key)
        {
            object value;
            return data.TryGetValue(key, out value) && value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture) : null;
        }

        private static long GetLong(Dictionary<string, object> data, string key)
        {
            object value;
            long result;
            return data.TryGetValue(key, out value) && value != null &&
                Int64.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                    NumberStyles.Any, CultureInfo.InvariantCulture, out result)
                ? result : 0;
        }

        /// <summary>
        /// Like <see cref="GetLong"/> but returns -1 when the key is missing or
        /// null, so callers can distinguish "unknown" from a real zero.
        /// </summary>
        private static long GetOptionalLong(Dictionary<string, object> data, string key)
        {
            object value;
            long result;
            if (!data.TryGetValue(key, out value) || value == null)
            {
                return -1;
            }
            return Int64.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                NumberStyles.Any, CultureInfo.InvariantCulture, out result)
                ? result : -1;
        }

        private static string Fingerprint(IEnumerable<PiStatusRecord> values)
        {
            return String.Join("|", values.OrderBy(delegate(PiStatusRecord item)
            {
                return item.SessionId;
            }).Select(delegate(PiStatusRecord item)
            {
                return item.SessionId + ":" + item.State + ":" +
                    item.TimestampUtc.Ticks.ToString(CultureInfo.InvariantCulture);
            }).ToArray());
        }
    }
}
