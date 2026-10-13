using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    // Read-only integration: WorkBuddy's own state machine owns lifecycle decisions.
    internal sealed class WorkBuddyMonitor
    {
        // Cap historical display rows only. Live registrations are never aged out.
        internal const string SessionQueryTemplate = @"SELECT s.id, s.status, coalesce(s.custom_title, s.title), s.cwd, s.model, s.updated_at,
       coalesce(u.used, 0), coalesce(u.size, 0)
FROM sessions s
LEFT JOIN session_usage u ON u.session_id = s.id
WHERE s.deleted_at IS NULL AND (
    s.id IN ({0}) OR s.id IN (
        SELECT id FROM sessions
        WHERE deleted_at IS NULL AND id NOT IN ({0})
        ORDER BY updated_at DESC LIMIT 64
    )
)
ORDER BY s.updated_at DESC";
        internal static string SessionQuery(IEnumerable<string> liveIds)
        {
            // Hex-encoded UTF-8 literals safely preserve quotes, Unicode and NULs
            // without interpolating registration contents as SQL syntax.
            string ids = String.Join(",", liveIds.Select(id => "CAST(X'" +
                BitConverter.ToString(Encoding.UTF8.GetBytes(id)).Replace("-", "") + "' AS TEXT)"));
            return String.Format(CultureInfo.InvariantCulture, SessionQueryTemplate,
                ids.Length == 0 ? "SELECT NULL WHERE 0" : ids);
        }
        private readonly string root;
        private readonly DateTime launched = DateTime.UtcNow;
        private DateTime nextPoll;
        private Task<Observation> pending;
        private Observation current = new Observation();
        private readonly Dictionary<string, TranscriptCache> transcripts = new Dictionary<string, TranscriptCache>();
        internal sealed class Observation
        {
            internal bool Present;
            internal bool Connected;
            internal int Pid;
            internal List<SessionSnapshot> Sessions = new List<SessionSnapshot>();
        }
        private sealed class TranscriptCache
        {
            internal long Length;
            internal DateTime Written;
            internal long Input, Output;
            internal string Model;
        }
        internal WorkBuddyMonitor(string home = null)
        {
            root = Path.Combine(home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".workbuddy");
        }
        internal int HostPid() { return current.Pid; }
        internal AggregateSnapshot Aggregate(bool paused)
        {
            if (pending != null && pending.IsCompleted)
            {
                if (!pending.IsFaulted) current = pending.Result;
                else current = new Observation();
                pending = null;
            }
            if (!paused && pending == null && DateTime.UtcNow >= nextPoll)
            {
                nextPoll = DateTime.UtcNow.AddMilliseconds(500);
                pending = Task.Run(() => Scan());
            }
            return BuildAggregate(current, paused, launched, DateTime.UtcNow);
        }
        internal Observation Scan()
        {
            var observation = new Observation();
            DateTime appStart = DateTime.MaxValue;
            foreach (Process p in Process.GetProcessesByName("WorkBuddy")) using (p)
            {
                DateTime start;
                if (!WindowsProcessProbe.TryGetLiveStartTime(p.Id, out start)) continue;
                observation.Present = true;
                if (start < appStart) { appStart = start; observation.Pid = p.Id; }
            }
            if (!observation.Present) return observation;
            var json = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 };
            var liveIds = new HashSet<string>();
            string sessionsPath = Path.Combine(root, "sessions");
            if (Directory.Exists(sessionsPath)) foreach (string path in Directory.EnumerateFiles(sessionsPath, "*.json"))
            {
                try
                {
                    if (new FileInfo(path).Length > 65536) continue;
                    var d = json.DeserializeObject(File.ReadAllText(path)) as Dictionary<string, object>;
                    if (d == null || Text(d, "kind") != "interactive") continue;
                    int pid; DateTime started;
                    if (!Int32.TryParse(Text(d, "pid"), out pid) || !WindowsProcessProbe.TryGetLiveStartTime(pid, out started)) continue;
                    DateTime registered = Milliseconds(Text(d, "startedAt"));
                    if (registered < started.AddSeconds(-5) || registered < appStart.AddSeconds(-5)) continue;
                    liveIds.Add(Text(d, "sessionId"));
                }
                catch (Exception) { /* Session registration can be replaced while being read. */ }
            }
            using (var db = new CodexSQLiteLogStore(Path.Combine(root, "workbuddy.db")))
            {
                // No credentials, prompts or account metadata are read from settings.
                var rows = db.QueryRows(SessionQuery(liveIds), 8);
                observation.Connected = db.LastQuerySucceeded;
                foreach (string[] row in rows)
                {
                    SessionSnapshot snapshot = ParseRow(row);
                    if (!IsSessionEligible(snapshot, liveIds.Contains(row[0]), appStart)) continue;
                    try { ReadMetrics(snapshot, json); }
                    catch (IOException) { /* Usage can lag without discarding lifecycle evidence. */ }
                    catch (UnauthorizedAccessException) { }
                    observation.Sessions.Add(snapshot);
                }
            }
            return observation;
        }
        internal static bool IsSessionEligible(SessionSnapshot snapshot, bool live, DateTime appStart)
        {
            // Neither a prewarm process nor an orphaned saved task proves activity.
            if ((snapshot.Active || snapshot.State == HaloState.Error) && !live) return false;
            return live || snapshot.LastEventUtc >= appStart;
        }
        internal static SessionSnapshot ParseRow(string[] row)
        {
            var s = new SessionSnapshot { Agent = AgentKind.WorkBuddy, ThreadId = row[0], ProjectName = row[2],
                WorkingDirectory = row[3], ModelName = row[4], LastEventUtc = Milliseconds(row[5]),
                ContextInputTokens = Number(row[6]), ContextWindowTokens = Number(row[7]),
                EvidenceSource = AgentEvidenceSource.WorkBuddyStore, EvidenceKind = row[1] };
            switch ((row[1] ?? "").ToLowerInvariant())
            {
                case "planning": s.State = HaloState.Thinking; s.Action = "Thinking"; s.TurnPhase = AgentTurnPhase.Thinking; break;
                case "working": case "streaming": s.State = HaloState.Working; s.Action = "Using tools"; s.TurnPhase = AgentTurnPhase.Executing; break;
                case "pending": case "waiting_permission": case "waiting_question": case "paused":
                    s.State = HaloState.Attention; s.Action = "Awaiting permission or input"; s.TurnPhase = AgentTurnPhase.AwaitingUser; break;
                case "error": case "failed": case "interrupted":
                    s.State = HaloState.Error; s.Action = L10n.Instance["status.error"]; s.TurnPhase = AgentTurnPhase.Failed; break;
                case "completed":
                    s.State = HaloState.Done; s.Action = "Complete"; s.CompletedUtc = s.LastEventUtc; s.TurnPhase = AgentTurnPhase.Completed; break;
                default: s.State = HaloState.Idle; s.Action = "Ready"; break;
            }
            s.Active = s.State == HaloState.Thinking || s.State == HaloState.Working || s.State == HaloState.Attention;
            return s;
        }
        internal static AggregateSnapshot BuildAggregate(Observation observation, bool paused, DateTime launched, DateTime now)
        {
            var result = new AggregateSnapshot { FocusedAgent = AgentKind.WorkBuddy, State = HaloState.Idle,
                Label = "OFFLINE", Detail = L10n.Instance["status.offline_workbuddy"], Sessions = new List<SessionSnapshot>() };
            if (paused) { result.Label = "PAUSED"; result.Detail = L10n.Instance["status.paused"]; return result; }
            if (!observation.Present) return result;
            if (!observation.Connected)
            {
                result.Label = "CONNECTING";
                result.Detail = L10n.Instance["status.connecting_workbuddy"];
                return result;
            }
            result.Sessions = observation.Sessions.OrderBy(s => CodexSessionMonitor.StatePriority(s.State)).ThenByDescending(s => s.LastEventUtc).ToList();
            var primary = result.Sessions.FirstOrDefault();
            bool standby = primary == null || primary.State == HaloState.Idle ||
                (primary.State == HaloState.Done && (primary.CompletedUtc < launched || (now - primary.CompletedUtc).TotalSeconds > 8));
            result.State = standby ? HaloState.Done : primary.State;
            result.Label = standby ? "STANDBY" : CodexSessionMonitor.StateLabel(result.State);
            result.Detail = standby ? L10n.Instance["status.standby_workbuddy"] : primary.Action;
            result.Presence = standby ? AgentPresenceState.Standby : AgentPresenceState.Active;
            result.EvidenceSource = AgentEvidenceSource.WorkBuddyStore;
            return result;
        }
        internal void ReadMetrics(SessionSnapshot session, JavaScriptSerializer json)
        {
            // WorkBuddy uses the same project-directory escaping as its CLI.
            // Preserve directory casing: it matters on shared filesystems and in escaped names.
            string projects = Path.Combine(root, "projects");
            if (!Directory.Exists(projects)) return;
            string escaped = session.WorkingDirectory.Replace(":", "").Replace('\\', '-').Replace('/', '-');
            escaped = escaped.Length > 0 ? Char.ToLowerInvariant(escaped[0]) + escaped.Substring(1) : escaped;
            string path = Path.Combine(projects, escaped, session.ThreadId + ".jsonl");
            if (!File.Exists(path)) return;
            var info = new FileInfo(path);
            TranscriptCache cache;
            if (!transcripts.TryGetValue(path, out cache) || cache.Length != info.Length || cache.Written != info.LastWriteTimeUtc)
            {
                if (cache == null || info.Length < cache.Length ||
                    (info.Length == cache.Length && info.LastWriteTimeUtc != cache.Written)) cache = new TranscriptCache();
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    // Usage is attached to completed model responses, not arbitrary tool outputs.
                    long start = cache.Length > 0 ? cache.Length : Math.Max(0, stream.Length - 512 * 1024);
                    stream.Seek(start, SeekOrigin.Begin);
                    byte[] buffer = new byte[(int)Math.Min(512 * 1024, stream.Length - start)];
                    int read = 0, count;
                    while (read < buffer.Length && (count = stream.Read(buffer, read, buffer.Length - read)) > 0) read += count;
                    int last = read - 1;
                    while (last >= 0 && buffer[last] != 10) last--;
                    if (last >= 0)
                    {
                        int first = 0;
                        if (cache.Length == 0 && start > 0) { while (first <= last && buffer[first++] != 10) { } }
                        foreach (string line in Encoding.UTF8.GetString(buffer, first, last + 1 - first).Split('\n')) try
                        {
                            var d = json.DeserializeObject(line) as Dictionary<string, object>;
                            if (d == null) continue;
                            var provider = Object(d, "providerData");
                            string model = Text(provider, "requestModelName");
                            if (!String.IsNullOrEmpty(model)) cache.Model = model;
                            var usage = Object(Object(d, "message"), "usage");
                            long input = Number(Text(usage, "input_tokens")), output = Number(Text(usage, "output_tokens"));
                            if (input > 0 || output > 0) { cache.Input = input; cache.Output = output; }
                        }
                        catch (Exception) { /* Ignore an incomplete last JSONL line. */ }
                        cache.Length = start + last + 1;
                    }
                    else if (read == 512 * 1024)
                    {
                        // Skip oversized tool-result records instead of rescanning them forever.
                        cache.Length = start + read;
                    }
                }
                cache.Written = info.LastWriteTimeUtc;
                if (transcripts.Count > 128) transcripts.Clear();
                transcripts[path] = cache;
            }
            session.TurnInputTokens = cache.Input; session.TurnOutputTokens = cache.Output;
            if (!String.IsNullOrEmpty(cache.Model)) session.ModelName = cache.Model;
        }
        private static Dictionary<string, object> Object(Dictionary<string, object> d, string key)
        { object v; return d != null && d.TryGetValue(key, out v) ? v as Dictionary<string, object> : null; }
        private static string Text(Dictionary<string, object> d, string key)
        { object v; return d != null && d.TryGetValue(key, out v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : ""; }
        private static long Number(string value) { long n; return Int64.TryParse(value, out n) ? Math.Max(0, n) : 0; }
        private static DateTime Milliseconds(string value)
        { long n; return Int64.TryParse(value, out n) && n > 0 && n < 253402300799999 ? new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(n) : DateTime.MinValue; }
    }
}
