using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    internal static class OpenCodePluginConfigurator
    {
        internal static string Configure(string home = null)
        {
            home = home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string config = Environment.GetEnvironmentVariable("OPENCODE_CONFIG_DIR");
            if (String.IsNullOrWhiteSpace(config))
            {
                string xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
                config = Path.Combine(String.IsNullOrWhiteSpace(xdg) ? Path.Combine(home, ".config") : xdg, "opencode");
            }
            string path = Path.Combine(config, "plugins", "agent-halo-status.js");
            try
            {
                using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("AgentHalo.OpenCodeStatusPlugin"))
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                {
                    string source = reader.ReadToEnd();
                    if (File.Exists(path) && File.ReadAllText(path) == source) return path;
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    string temp = path + ".tmp";
                    File.WriteAllText(temp, source, new UTF8Encoding(false));
                    if (File.Exists(path)) File.Replace(temp, path, null);
                    else File.Move(temp, path);
                }
                return path;
            }
            catch (Exception ex) { SettingsStorage.Log("OpenCode plugin: " + ex.Message); return null; }
        }
    }

    internal sealed class OpenCodeMonitor
    {
        private readonly string root;
        private readonly JavaScriptSerializer json = new JavaScriptSerializer();
        private readonly DateTime launched = DateTime.UtcNow;
        private DateTime nextPoll;
        private List<SessionSnapshot> sessions = new List<SessionSnapshot>();
        private Dictionary<string, int> pids = new Dictionary<string, int>();
        private Task<ScanResult> pending;
        private bool processPresent;
        private sealed class ScanResult
        {
            internal List<SessionSnapshot> Sessions = new List<SessionSnapshot>();
            internal Dictionary<string, int> Pids = new Dictionary<string, int>();
            internal bool Present;
            internal bool ProcessPresent;
        }
        internal bool Present { get; private set; }
        internal OpenCodeMonitor(string home = null)
        {
            root = Path.Combine(home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".agent-halo", "cache", "opencode");
        }
        internal void Refresh()
        {
            DateTime now = DateTime.UtcNow;
            if (pending != null)
            {
                if (!pending.IsCompleted) return;
                if (!pending.IsFaulted)
                {
                    sessions = pending.Result.Sessions;
                    pids = pending.Result.Pids;
                    Present = pending.Result.Present;
                    processPresent = pending.Result.ProcessPresent;
                }
                else { Present = false; processPresent = false; sessions.Clear(); pids.Clear(); }
                pending = null;
            }
            if (now < nextPoll) return;
            nextPoll = now.AddMilliseconds(500);
            pending = Task.Run(() => Scan(now));
        }
        private ScanResult Scan(DateTime now)
        {
            var result = new ScanResult();
            // Process presence proves only that OpenCode is running, not its task state.
            foreach (Process process in Process.GetProcessesByName("opencode"))
            {
                using (process)
                {
                    result.ProcessPresent = true;
                }
            }
            var next = new List<SessionSnapshot>();
            if (Directory.Exists(root)) foreach (string file in Directory.EnumerateFiles(root, "*.json")
                .OrderByDescending(File.GetLastWriteTimeUtc).Take(128))
            {
                try
                {
                    var info = new FileInfo(file);
                    if (info.Length > 1048576 || (now - info.LastWriteTimeUtc).TotalSeconds > 15) continue;
                    var data = json.DeserializeObject(File.ReadAllText(file)) as Dictionary<string, object>;
                    if (data == null || Num(data, "version") != 1) continue;
                    int pid = (int)Num(data, "pid");
                    DateTime processStart;
                    if (!TryGetLiveProcessStartTime(pid, out processStart) ||
                        Math.Abs((processStart - Date(data, "startedAt")).TotalSeconds) > 5) continue;
                    if (Math.Abs((now - Date(data, "timestamp")).TotalSeconds) > 15) continue;
                    result.Present = true;
                    foreach (SessionSnapshot s in Parse(data))
                    {
                        // A saved completion before this launch is standby, not a new alert.
                        if (s.State == HaloState.Done && (s.CompletedUtc < launched ||
                            !HaloWindow.IsHookActivitySessionVisible(s, now, true)))
                        { s.State = HaloState.Idle; s.CompletedUtc = DateTime.MinValue; }
                        next.Add(s); result.Pids[s.ThreadId] = pid;
                    }
                }
                catch (Exception) { /* A concurrent atomic replacement or exited process is retried next poll. */ }
            }
            result.Sessions = next.GroupBy(s => s.ThreadId).Select(g => g.OrderByDescending(s => s.LastEventUtc).First()).ToList();
            return result;
        }
        internal int HostPid()
        {
            var first = sessions.OrderBy(s => CodexSessionMonitor.StatePriority(s.State)).ThenByDescending(s => s.LastEventUtc).FirstOrDefault();
            int pid;
            return first != null && pids.TryGetValue(first.ThreadId, out pid) ? pid : 0;
        }
        internal static bool TryGetLiveProcessStartTime(int pid, out DateTime started)
        {
            return WindowsProcessProbe.TryGetLiveStartTime(pid, out started);
        }
        internal AggregateSnapshot Aggregate(bool paused)
        {
            Refresh();
            return BuildAggregate(sessions, Present, paused, DateTime.UtcNow, processPresent);
        }
        internal static AggregateSnapshot BuildAggregate(List<SessionSnapshot> source, bool present, bool paused, DateTime now, bool processPresent = false)
        {
            var ordered = present ? source.OrderBy(s => CodexSessionMonitor.StatePriority(s.State)).ThenByDescending(s => s.LastEventUtc).ToList() : new List<SessionSnapshot>();
            var result = new AggregateSnapshot { FocusedAgent = AgentKind.OpenCode, Sessions = ordered,
                State = HaloState.Idle, Label = "OFFLINE", Detail = L10n.Instance["status.offline_opencode"] };
            if (paused) { result.Label = "PAUSED"; result.Detail = "Monitoring paused"; return result; }
            if (!present && processPresent)
            {
                result.Label = "CONNECTING";
                result.Detail = L10n.Instance["status.connecting_opencode"];
                return result;
            }
            if (!present) return result;
            var primary = ordered.FirstOrDefault();
            bool standby = primary == null || primary.State == HaloState.Idle ||
                (primary.State == HaloState.Done && !HaloWindow.IsHookActivitySessionVisible(primary, now, true));
            result.State = standby ? HaloState.Done : primary.State;
            result.Label = standby ? "STANDBY" : CodexSessionMonitor.StateLabel(result.State);
            result.Detail = standby ? L10n.Instance["status.standby_opencode"] : primary.Action;
            result.Presence = standby ? AgentPresenceState.Standby : AgentPresenceState.Active;
            return result;
        }
        internal static List<SessionSnapshot> Parse(Dictionary<string, object> data)
        {
            var result = new List<SessionSnapshot>();
            object raw;
            var rows = data.TryGetValue("sessions", out raw) ? raw as IEnumerable : null;
            if (rows == null) return result;
            var map = new Dictionary<string, Dictionary<string, object>>();
            foreach (object row in rows)
            {
                var d = row as Dictionary<string, object>;
                if (d != null && Text(d, "id") != "") map[Text(d, "id")] = d;
            }
            foreach (var d in map.Values)
            {
                string state = Text(d, "state");
                bool child = Text(d, "parentID") != "";
                // Child completion never completes the root. Child attention must remain visible.
                if (child && state != "attention") continue;
                var s = new SessionSnapshot { Agent = AgentKind.OpenCode, ThreadId = Text(d, "id"),
                    ProjectName = Text(d, "title"), WorkingDirectory = Text(d, "directory"),
                    LastEventUtc = Date(d, "updatedAt"), CompletedUtc = Date(d, "completedAt"),
                    ModelName = Text(d, "model"), ModelProvider = Text(d, "provider"),
                    TurnInputTokens = Num(d, "input"), TurnOutputTokens = Num(d, "output"),
                    TurnCachedInputTokens = Num(d, "cacheRead"), ContextInputTokens = Num(d, "context"),
                    ContextWindowTokens = Num(d, "contextWindow"), EvidenceKind = Text(d, "event"),
                    EvidenceSource = AgentEvidenceSource.OpenCodePlugin };
                if (s.ProjectName == "") s.ProjectName = Path.GetFileName(s.WorkingDirectory.TrimEnd('\\', '/'));
                switch (state)
                {
                    case "thinking": s.State = HaloState.Thinking; s.Action = "Thinking"; break;
                    case "working": s.State = HaloState.Working; s.Action = s.EvidenceKind == "context.compacting" ? "Compressing context" : "Using tools"; break;
                    case "attention": s.State = HaloState.Attention; s.Action = "Awaiting permission or input"; break;
                    case "error": s.State = HaloState.Error; s.Action = L10n.Instance["status.error"]; break;
                    case "done": s.State = HaloState.Done; s.Action = "Complete"; break;
                    default: s.State = HaloState.Idle; s.Action = "Ready"; break;
                }
                s.Active = s.State == HaloState.Thinking || s.State == HaloState.Working || s.State == HaloState.Attention;
                result.Add(s);
            }
            return result;
        }
        private static string Text(Dictionary<string, object> d, string key) { object v; return d.TryGetValue(key, out v) && v != null ? Convert.ToString(v) : ""; }
        private static long Num(Dictionary<string, object> d, string key) { long v; return Int64.TryParse(Text(d, key), out v) ? Math.Max(0, v) : 0; }
        private static DateTime Date(Dictionary<string, object> d, string key) { DateTime v; return DateTime.TryParse(Text(d, key), null, System.Globalization.DateTimeStyles.RoundtripKind, out v) ? v.ToUniversalTime() : DateTime.MinValue; }
    }
}
