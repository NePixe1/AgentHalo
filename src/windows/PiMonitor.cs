using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    internal static class PiExtensionConfigurator
    {
        internal const string ResourceName = "AgentHalo.PiStatusExtension";

        public static string Configure(string userProfile = null)
        {
            string root = Environment.GetEnvironmentVariable("PI_CODING_AGENT_DIR");
            if (String.IsNullOrWhiteSpace(root))
            {
                string home = String.IsNullOrWhiteSpace(userProfile)
                    ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
                    : userProfile;
                root = Path.Combine(home, ".pi", "agent");
            }
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
                    ContextTokens = GetLong(data, "contextTokens"),
                    ContextWindowTokens = GetLong(data, "contextWindow")
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
