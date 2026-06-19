using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;
using DrawingColor = System.Drawing.Color;
using MediaColor = System.Windows.Media.Color;
using MediaBrush = System.Windows.Media.Brush;
using MediaPen = System.Windows.Media.Pen;
using MediaPoint = System.Windows.Point;

namespace CodexHalo
{
public sealed class SessionTracker
    {
        private readonly JavaScriptSerializer serializer;
        private long offset;
        private string pending;
        private DateTime observedWriteUtc;
        private long observedLength;
        private int inFlightTools;
        private DateTime workingVisibleUntilUtc;
        private bool liveTracking;
        private bool currentTurnIsPlanMode;
        private bool planProposalSeen;

        public string FilePath { get; private set; }
        public SessionSnapshot Snapshot { get; private set; }

        public SessionTracker(string path)
        {
            FilePath = path;
            serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = Int32.MaxValue;
            pending = String.Empty;
            Snapshot = new SessionSnapshot();
            Snapshot.ThreadId = ExtractThreadId(path);
            Snapshot.ProjectName = "Codex";
            Snapshot.WorkingDirectory = String.Empty;
            Snapshot.State = HaloState.Idle;
            Snapshot.Action = "Ready";
            Snapshot.LastEventUtc = File.GetLastWriteTimeUtc(path);
            ReadMetadata();
            ReadInitialTail();
            FileInfo initialInfo = new FileInfo(path);
            observedWriteUtc = initialInfo.LastWriteTimeUtc;
            observedLength = initialInfo.Length;
            liveTracking = true;
        }

        private static string ExtractThreadId(string path)
        {
            string name = Path.GetFileNameWithoutExtension(path);
            if (name.Length >= 36)
            {
                string candidate = name.Substring(name.Length - 36);
                Guid parsed;
                if (Guid.TryParse(candidate, out parsed))
                {
                    return candidate;
                }
            }
            return name;
        }

        private void ReadMetadata()
        {
            try
            {
                using (FileStream stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true, 4096, true))
                {
                    string line = reader.ReadLine();
                    if (!String.IsNullOrEmpty(line))
                    {
                        ParseLine(line);
                    }
                }
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Metadata read failed: " + ex.Message);
            }
        }

        private void ReadInitialTail()
        {
            try
            {
                using (FileStream stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                {
                    long start = Math.Max(0, stream.Length - (384 * 1024));
                    stream.Seek(start, SeekOrigin.Begin);
                    if (start > 0)
                    {
                        int value;
                        while ((value = stream.ReadByte()) >= 0 && value != '\n')
                        {
                        }
                    }
                    ReadAvailable(stream);
                    offset = stream.Length;
                }
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Initial session read failed: " + ex.Message);
            }
        }

        public bool Refresh()
        {
            long previousTicks = Snapshot.LastEventUtc.Ticks;
            HaloState previousState = Snapshot.State;
            string previousAction = Snapshot.Action;
            ApplyWorkingVisibility();
            try
            {
                FileInfo info = new FileInfo(FilePath);
                DateTime writeUtc = info.LastWriteTimeUtc;
                if (writeUtc <= observedWriteUtc && info.Length <= observedLength)
                {
                    return previousState != Snapshot.State ||
                        previousAction != Snapshot.Action;
                }
                using (FileStream stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                {
                    if (stream.Length < offset)
                    {
                        offset = 0;
                        pending = String.Empty;
                    }
                    if (stream.Length > offset)
                    {
                        stream.Seek(offset, SeekOrigin.Begin);
                        ReadAvailable(stream);
                        offset = stream.Length;
                    }
                }
                observedWriteUtc = writeUtc;
                observedLength = info.Length;
            }
            catch (IOException)
            {
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Session refresh failed: " + ex.Message);
            }
            return previousTicks != Snapshot.LastEventUtc.Ticks ||
                previousState != Snapshot.State || previousAction != Snapshot.Action;
        }

        private void ApplyWorkingVisibility()
        {
            if (Snapshot.Active && inFlightTools == 0 &&
                Snapshot.State == HaloState.Working &&
                workingVisibleUntilUtc != DateTime.MinValue &&
                DateTime.UtcNow >= workingVisibleUntilUtc)
            {
                workingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.State = HaloState.Thinking;
                Snapshot.Action = "Reviewing result";
            }
        }

        private void ExtendWorkingVisibility(double seconds)
        {
            if (!liveTracking)
            {
                return;
            }
            DateTime candidate = DateTime.UtcNow.AddSeconds(seconds);
            if (candidate > workingVisibleUntilUtc)
            {
                workingVisibleUntilUtc = candidate;
            }
        }

        private void ReadAvailable(FileStream stream)
        {
            long remaining = stream.Length - stream.Position;
            if (remaining <= 0)
            {
                return;
            }
            byte[] bytes = new byte[(int)Math.Min(remaining, Int32.MaxValue)];
            int total = 0;
            while (total < bytes.Length)
            {
                int read = stream.Read(bytes, total, bytes.Length - total);
                if (read <= 0)
                {
                    break;
                }
                total += read;
            }
            string text = pending + Encoding.UTF8.GetString(bytes, 0, total);
            string[] lines = text.Split('\n');
            int complete = lines.Length;
            if (!text.EndsWith("\n", StringComparison.Ordinal))
            {
                pending = lines[lines.Length - 1];
                complete--;
            }
            else
            {
                pending = String.Empty;
            }
            for (int i = 0; i < complete; i++)
            {
                string line = lines[i].TrimEnd('\r');
                if (!String.IsNullOrEmpty(line))
                {
                    ParseLine(line);
                }
            }
        }

        private void ParseLine(string line)
        {
            try
            {
                Dictionary<string, object> root = serializer.DeserializeObject(line) as Dictionary<string, object>;
                if (root == null)
                {
                    return;
                }
                string topType = GetString(root, "type");
                Dictionary<string, object> payload = GetDictionary(root, "payload");
                DateTime eventUtc = ParseTimestamp(GetString(root, "timestamp"));
                if (eventUtc != DateTime.MinValue)
                {
                    Snapshot.LastEventUtc = eventUtc;
                }

                if (topType == "turn_context" && payload != null)
                {
                    UpdatePlanModeFromTurnContext(payload);
                    return;
                }
                if (topType == "session_meta" && payload != null)
                {
                    string cwd = GetString(payload, "cwd");
                    if (!String.IsNullOrEmpty(cwd))
                    {
                        Snapshot.WorkingDirectory = cwd;
                        string leaf = Path.GetFileName(cwd.TrimEnd(Path.DirectorySeparatorChar,
                            Path.AltDirectorySeparatorChar));
                        Snapshot.ProjectName = String.IsNullOrEmpty(leaf) ? cwd : leaf;
                    }
                    string id = GetString(payload, "id");
                    if (!String.IsNullOrEmpty(id))
                    {
                        Snapshot.ThreadId = id;
                    }
                    return;
                }
                if (payload == null)
                {
                    return;
                }

                string payloadType = GetString(payload, "type");
                if (topType == "event_msg")
                {
                    ReduceEvent(payloadType, payload, eventUtc);
                }
                else if (topType == "response_item")
                {
                    ReduceResponse(payloadType, payload, eventUtc);
                }
            }
            catch
            {
                // Event lines can contain arbitrary tool output. Unsupported lines are ignored.
            }
        }

        private void UpdatePlanModeFromTurnContext(Dictionary<string, object> payload)
        {
            Dictionary<string, object> collaborationMode =
                GetDictionary(payload, "collaboration_mode");
            string mode = GetString(collaborationMode, "mode");
            if (String.Equals(mode, "plan", StringComparison.OrdinalIgnoreCase))
            {
                currentTurnIsPlanMode = true;
            }
        }

        private void ReduceEvent(string payloadType,
            Dictionary<string, object> payload, DateTime eventUtc)
        {
            string lower = (payloadType ?? String.Empty).ToLowerInvariant();
            if (GeneratedHaloSpec.IsTaskStartEvent(lower))
            {
                inFlightTools = 0;
                workingVisibleUntilUtc = DateTime.MinValue;
                if (lower == "task_started")
                {
                    currentTurnIsPlanMode = IsPlanModePayload(payload);
                }
                planProposalSeen = false;
                Snapshot.Active = true;
                Snapshot.State = HaloState.Thinking;
                Snapshot.Action = "Planning";
            }
            else if (GeneratedHaloSpec.IsTaskCompleteEvent(lower))
            {
                inFlightTools = 0;
                workingVisibleUntilUtc = DateTime.MinValue;
                if (currentTurnIsPlanMode && planProposalSeen)
                {
                    Snapshot.Active = true;
                    Snapshot.State = HaloState.Attention;
                    Snapshot.Action = "Waiting for your choice";
                }
                else
                {
                    Snapshot.Active = false;
                    Snapshot.State = HaloState.Done;
                    Snapshot.Action = "Complete";
                }
                Snapshot.CompletedUtc = eventUtc == DateTime.MinValue ? DateTime.UtcNow : eventUtc;
            }
            else if (lower == "agent_message" || lower.EndsWith("_end"))
            {
                if (lower.EndsWith("_end") && inFlightTools > 0)
                {
                    inFlightTools--;
                }
                if (lower == "agent_message" && IsFinalAnswerPayload(payload))
                {
                    if (currentTurnIsPlanMode && ContainsProposedPlan(payload))
                    {
                        planProposalSeen = true;
                    }
                    Snapshot.Active = true;
                    Snapshot.State = HaloState.Working;
                    Snapshot.Action = "Writing answer";
                }
                else if (Snapshot.Active)
                {
                    if (inFlightTools > 0)
                    {
                        Snapshot.State = HaloState.Working;
                    }
                    else if (DateTime.UtcNow < workingVisibleUntilUtc)
                    {
                        Snapshot.State = HaloState.Working;
                        Snapshot.Action = "Reviewing result";
                    }
                    else
                    {
                        Snapshot.State = HaloState.Thinking;
                        Snapshot.Action = "Thinking";
                    }
                }
            }
            else if (GeneratedHaloSpec.IsAttentionEvent(lower))
            {
                Snapshot.Active = true;
                Snapshot.State = HaloState.Attention;
                Snapshot.Action = "Needs you";
            }
            else if (lower == "item_completed")
            {
                if (currentTurnIsPlanMode && IsCompletedPlanItem(payload))
                {
                    planProposalSeen = true;
                }
            }
            else if (GeneratedHaloSpec.IsFatalEvent(lower))
            {
                Snapshot.Active = false;
                Snapshot.State = HaloState.Error;
                Snapshot.Action = "Interrupted";
            }
            else if (lower.EndsWith("_begin") || lower.EndsWith("_start"))
            {
                Snapshot.Active = true;
                Snapshot.State = HaloState.Working;
                Snapshot.Action = GeneratedHaloSpec.FriendlyAction(lower);
            }
        }

        private void ReduceResponse(string payloadType, Dictionary<string, object> payload, DateTime eventUtc)
        {
            string lower = (payloadType ?? String.Empty).ToLowerInvariant();
            if (lower == "function_call" || lower == "custom_tool_call")
            {
                string name = GetString(payload, "name");
                Snapshot.Active = true;
                if (name == "request_user_input")
                {
                    Snapshot.State = HaloState.Attention;
                    Snapshot.Action = "Needs you";
                }
                else
                {
                    inFlightTools++;
                    ExtendWorkingVisibility(2.2);
                    Snapshot.State = HaloState.Working;
                    Snapshot.Action = GeneratedHaloSpec.FriendlyAction(name);
                }
            }
            else if (lower == "message" && IsFinalAnswerPayload(payload))
            {
                if (currentTurnIsPlanMode && ContainsProposedPlan(payload))
                {
                    planProposalSeen = true;
                }
                Snapshot.Active = true;
                Snapshot.State = HaloState.Working;
                Snapshot.Action = "Writing answer";
            }
            else if (GeneratedHaloSpec.IsToolCall(lower) || lower.EndsWith("_call"))
            {
                inFlightTools++;
                ExtendWorkingVisibility(2.2);
                Snapshot.Active = true;
                Snapshot.State = HaloState.Working;
                Snapshot.Action = GeneratedHaloSpec.FriendlyAction(lower);
            }
            else if (GeneratedHaloSpec.IsToolOutput(lower) || lower.EndsWith("_output"))
            {
                if (inFlightTools > 0)
                {
                    inFlightTools--;
                }
                if (Snapshot.Active)
                {
                    if (inFlightTools > 0)
                    {
                        Snapshot.State = HaloState.Working;
                    }
                    else if (liveTracking)
                    {
                        ExtendWorkingVisibility(1.8);
                        Snapshot.State = HaloState.Working;
                        Snapshot.Action = "Reviewing result";
                    }
                    else
                    {
                        Snapshot.State = HaloState.Thinking;
                        Snapshot.Action = "Reviewing result";
                    }
                }
            }
            else if (lower == "reasoning")
            {
                if (Snapshot.Active)
                {
                    if (inFlightTools > 0)
                    {
                        Snapshot.State = HaloState.Working;
                    }
                    else if (DateTime.UtcNow < workingVisibleUntilUtc)
                    {
                        Snapshot.State = HaloState.Working;
                        Snapshot.Action = "Reviewing result";
                    }
                    else
                    {
                        Snapshot.State = HaloState.Thinking;
                        Snapshot.Action = "Thinking";
                    }
                }
            }
        }

        private static bool IsPlanModePayload(Dictionary<string, object> payload)
        {
            string mode = GetString(payload, "collaboration_mode_kind");
            return String.Equals(mode, "plan", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsFinalAnswerPayload(Dictionary<string, object> payload)
        {
            string phase = GetString(payload, "phase");
            return String.Equals(phase, "final_answer",
                StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsCompletedPlanItem(Dictionary<string, object> payload)
        {
            Dictionary<string, object> item = GetDictionary(payload, "item");
            return item != null &&
                String.Equals(GetString(item, "type"), "Plan",
                    StringComparison.OrdinalIgnoreCase);
        }

        private static bool ContainsProposedPlan(object value)
        {
            if (value == null)
            {
                return false;
            }
            string text = value as string;
            if (text != null)
            {
                return text.IndexOf("<proposed_plan",
                    StringComparison.OrdinalIgnoreCase) >= 0;
            }
            Dictionary<string, object> dictionary =
                value as Dictionary<string, object>;
            if (dictionary != null)
            {
                foreach (object child in dictionary.Values)
                {
                    if (ContainsProposedPlan(child))
                    {
                        return true;
                    }
                }
                return false;
            }
            System.Collections.IEnumerable enumerable =
                value as System.Collections.IEnumerable;
            if (enumerable != null)
            {
                foreach (object child in enumerable)
                {
                    if (ContainsProposedPlan(child))
                    {
                        return true;
                    }
                }
            }
            return false;
        }

        private static DateTime ParseTimestamp(string value)
        {
            DateTime parsed;
            if (DateTime.TryParse(value, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out parsed))
            {
                return parsed.ToUniversalTime();
            }
            return DateTime.MinValue;
        }

        private static string GetString(Dictionary<string, object> dictionary, string key)
        {
            object value;
            if (dictionary != null && dictionary.TryGetValue(key, out value) && value != null)
            {
                return Convert.ToString(value, CultureInfo.InvariantCulture);
            }
            return String.Empty;
        }

        private static Dictionary<string, object> GetDictionary(
            Dictionary<string, object> dictionary, string key)
        {
            object value;
            if (dictionary != null && dictionary.TryGetValue(key, out value))
            {
                return value as Dictionary<string, object>;
            }
            return null;
        }
    }

public sealed class CodexSessionMonitor : IDisposable
    {
        private readonly string root;
        private readonly Dictionary<string, SessionTracker> trackers;
        private readonly CodexRealtimeActivityReader realtimeActivity;
        private readonly System.Threading.Timer timer;
        private readonly Dispatcher dispatcher;
        private readonly object sync;
        private DateTime lastDiscoveryUtc;
        private DateTime nextRealtimePollUtc;
        private HaloState realtimeState;
        private string realtimeAction;
        private bool realtimeAnswerStreaming;
        private bool hasRealtimeActivity;
        private int pollInProgress;

        public event EventHandler Changed;

        public CodexSessionMonitor()
        {
            root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".codex", "sessions");
            trackers = new Dictionary<string, SessionTracker>(StringComparer.OrdinalIgnoreCase);
            realtimeActivity = new CodexRealtimeActivityReader();
            realtimeAction = String.Empty;
            dispatcher = Dispatcher.CurrentDispatcher;
            sync = new object();
            timer = new System.Threading.Timer(OnTick, null,
                Timeout.Infinite, Timeout.Infinite);
        }

        public void Start()
        {
            timer.Change(0, 220);
        }

        public void Stop()
        {
            timer.Change(Timeout.Infinite, Timeout.Infinite);
        }

        private void OnTick(object state)
        {
            if (Interlocked.Exchange(ref pollInProgress, 1) != 0)
            {
                return;
            }
            bool changed = false;
            try
            {
                lock (sync)
                {
                    if ((DateTime.UtcNow - lastDiscoveryUtc).TotalSeconds >= 2)
                    {
                        changed = Discover();
                    }
                    foreach (SessionTracker tracker in trackers.Values.ToList())
                    {
                        if (File.Exists(tracker.FilePath) && tracker.Refresh())
                        {
                            changed = true;
                        }
                    }
                    if (DateTime.UtcNow >= nextRealtimePollUtc)
                    {
                        nextRealtimePollUtc = DateTime.UtcNow.AddMilliseconds(300);
                        HaloState activeState;
                        string activeAction;
                        bool answerStreaming;
                        bool active = realtimeActivity.TryReadActive(out activeState,
                            out activeAction, out answerStreaming);
                        if (active != hasRealtimeActivity ||
                            activeState != realtimeState ||
                            answerStreaming != realtimeAnswerStreaming ||
                            !String.Equals(activeAction, realtimeAction,
                                StringComparison.Ordinal))
                        {
                            hasRealtimeActivity = active;
                            realtimeState = activeState;
                            realtimeAction = activeAction ?? String.Empty;
                            realtimeAnswerStreaming = answerStreaming;
                            changed = true;
                        }
                    }
                }
            }
            finally
            {
                Interlocked.Exchange(ref pollInProgress, 0);
            }
            if (changed && Changed != null)
            {
                dispatcher.BeginInvoke(DispatcherPriority.Background,
                    new Action(delegate
                    {
                        EventHandler handler = Changed;
                        if (handler != null)
                        {
                            handler(this, EventArgs.Empty);
                        }
                    }));
            }
        }

        private bool Discover()
        {
            lastDiscoveryUtc = DateTime.UtcNow;
            if (!Directory.Exists(root))
            {
                return false;
            }
            bool changed = false;
            try
            {
                List<string> recent = Directory.GetFiles(root, "*.jsonl", SearchOption.AllDirectories)
                    .Select(delegate(string path)
                    {
                        return new { Path = path, Time = File.GetLastWriteTimeUtc(path) };
                    })
                    .Where(delegate(dynamic item)
                    {
                        return item.Time >= DateTime.UtcNow.AddDays(-2);
                    })
                    .OrderByDescending(delegate(dynamic item) { return item.Time; })
                    .Take(16)
                    .Select(delegate(dynamic item) { return (string)item.Path; })
                    .ToList();

                foreach (string path in recent)
                {
                    if (!trackers.ContainsKey(path))
                    {
                        trackers[path] = new SessionTracker(path);
                        changed = true;
                    }
                }
                List<string> stale = trackers.Keys.Where(delegate(string path)
                {
                    return !recent.Contains(path, StringComparer.OrdinalIgnoreCase);
                }).ToList();
                foreach (string path in stale)
                {
                    trackers.Remove(path);
                    changed = true;
                }
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Session discovery failed: " + ex.Message);
            }
            return changed;
        }

        public AggregateSnapshot GetAggregate(HaloSettings settings)
        {
            lock (sync)
            {
                DateTime now = DateTime.UtcNow;
                List<SessionSnapshot> sessions = trackers.Values
                .Select(delegate(SessionTracker tracker)
                {
                    return CloneSnapshot(tracker.Snapshot);
                })
                .Where(delegate(SessionSnapshot snapshot)
                {
                    if (snapshot.State == HaloState.Done)
                    {
                        return snapshot.CompletedUtc > settings.GetAcknowledgedUtc(snapshot.ThreadId) &&
                            snapshot.CompletedUtc >= settings.GetInstalledUtc() &&
                            snapshot.CompletedUtc >= now.AddDays(-1);
                    }
                    return snapshot.Active ||
                        (snapshot.State == HaloState.Error &&
                         snapshot.LastEventUtc >= now.AddHours(-12));
                })
                .OrderBy(delegate(SessionSnapshot snapshot) { return StatePriority(snapshot.State); })
                .ThenByDescending(delegate(SessionSnapshot snapshot) { return snapshot.LastEventUtc; })
                .ToList();

                AggregateSnapshot result = new AggregateSnapshot();
                result.Sessions = sessions;
                if (settings.Paused)
                {
                    result.State = HaloState.Idle;
                    result.Label = "PAUSED";
                    result.Detail = "Monitoring paused";
                    return result;
                }
                bool hasBlockingState = sessions.Any(delegate(SessionSnapshot snapshot)
                {
                    return snapshot.State == HaloState.Error ||
                        snapshot.State == HaloState.Attention;
                });
                if (hasRealtimeActivity && !hasBlockingState)
                {
                    SessionSnapshot current = sessions.FirstOrDefault();
                    result.State = realtimeState;
                    result.Label = StateLabel(realtimeState);
                    result.Detail = (current == null ? "Codex" : current.ProjectName) +
                        " · " + realtimeAction;
                    result.AnswerStreaming = realtimeAnswerStreaming;
                    return result;
                }
                if (sessions.Count == 0)
                {
                    result.State = HaloState.Idle;
                    result.Label = "READY";
                    result.Detail = "Codex is standing by";
                    return result;
                }

                SessionSnapshot primary = sessions[0];
                result.State = primary.State;
                result.Label = StateLabel(primary.State);
                result.Detail = sessions.Count == 1
                    ? primary.ProjectName + " · " + primary.Action
                    : primary.ProjectName + " +" +
                        (sessions.Count - 1).ToString(CultureInfo.InvariantCulture);
                return result;
            }
        }

        public List<SessionSnapshot> GetAllRecent()
        {
            lock (sync)
            {
                return trackers.Values.Select(delegate(SessionTracker tracker)
                {
                    return CloneSnapshot(tracker.Snapshot);
                })
                .Where(delegate(SessionSnapshot snapshot)
                {
                    return snapshot.LastEventUtc >= DateTime.UtcNow.AddHours(-24);
                })
                .OrderBy(delegate(SessionSnapshot snapshot) { return StatePriority(snapshot.State); })
                .ThenByDescending(delegate(SessionSnapshot snapshot) { return snapshot.LastEventUtc; })
                .Take(8)
                .ToList();
            }
        }

        private static SessionSnapshot CloneSnapshot(SessionSnapshot snapshot)
        {
            return new SessionSnapshot
            {
                ThreadId = snapshot.ThreadId,
                ProjectName = snapshot.ProjectName,
                WorkingDirectory = snapshot.WorkingDirectory,
                State = snapshot.State,
                Action = snapshot.Action,
                LastEventUtc = snapshot.LastEventUtc,
                CompletedUtc = snapshot.CompletedUtc,
                Active = snapshot.Active
            };
        }

        public static int StatePriority(HaloState state)
        {
            return GeneratedHaloSpec.State(state).Priority;
        }

        public static string StateLabel(HaloState state)
        {
            return GeneratedHaloSpec.State(state).Label;
        }

        public void Dispose()
        {
            timer.Dispose();
        }
    }

public sealed class CodexRealtimeActivityReader
    {
        private const int SqliteOpenReadOnly = 0x00000001;
        private const int SqliteRow = 100;
        private readonly JavaScriptSerializer serializer;
        private readonly string database;
        private bool unavailable;

        public CodexRealtimeActivityReader()
        {
            serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = Int32.MaxValue;
            database = Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile), ".codex", "logs_2.sqlite");
        }

        public bool TryReadActive(out HaloState state, out string action)
        {
            bool answerStreaming;
            return TryReadActive(out state, out action, out answerStreaming);
        }

        public bool TryReadActive(out HaloState state, out string action,
            out bool answerStreaming)
        {
            state = HaloState.Working;
            action = String.Empty;
            answerStreaming = false;
            if (unavailable || !File.Exists(database))
            {
                return false;
            }

            IntPtr connection = IntPtr.Zero;
            IntPtr statement = IntPtr.Zero;
            try
            {
                int opened = sqlite3_open_v2(database, out connection,
                    SqliteOpenReadOnly, null);
                if (opened != 0 || connection == IntPtr.Zero)
                {
                    return false;
                }
                sqlite3_busy_timeout(connection, 80);
                long cutoff = DateTimeOffset.UtcNow.AddMinutes(-5).ToUnixTimeSeconds();
                string query = "select feedback_log_body from logs where ts >= " +
                    cutoff.ToString(CultureInfo.InvariantCulture) +
                    " and target='codex_api::sse::responses' and " +
                    "feedback_log_body like 'SSE event: {\"type\":\"response.%' " +
                    "order by id desc limit 96;";
                if (sqlite3_prepare_v2(connection, query, -1, out statement,
                    IntPtr.Zero) != 0 || statement == IntPtr.Zero)
                {
                    return false;
                }

                List<string> rows = new List<string>();
                while (sqlite3_step(statement) == SqliteRow)
                {
                    string value = ReadUtf8Column(statement, 0);
                    if (!String.IsNullOrEmpty(value))
                    {
                        rows.Add(value);
                    }
                }
                return FindActive(rows, out state, out action, out answerStreaming);
            }
            catch (DllNotFoundException)
            {
                unavailable = true;
            }
            catch (EntryPointNotFoundException)
            {
                unavailable = true;
            }
            catch
            {
            }
            finally
            {
                if (statement != IntPtr.Zero)
                {
                    sqlite3_finalize(statement);
                }
                if (connection != IntPtr.Zero)
                {
                    sqlite3_close(connection);
                }
            }
            return false;
        }

        public bool FindActive(IEnumerable<string> newestFirst, out HaloState state,
            out string action)
        {
            bool answerStreaming;
            return FindActive(newestFirst, out state, out action, out answerStreaming);
        }

        public bool FindActive(IEnumerable<string> newestFirst, out HaloState state,
            out string action, out bool answerStreaming)
        {
            state = HaloState.Working;
            action = String.Empty;
            answerStreaming = false;
            HashSet<string> completed = new HashSet<string>(
                StringComparer.OrdinalIgnoreCase);
            foreach (string body in newestFirst)
            {
                string eventType;
                string itemId;
                string itemType;
                string name;
                if (!TryParseToolEvent(body, out eventType, out itemId,
                    out itemType, out name))
                {
                    continue;
                }
                if (eventType == "response.output_text.delta")
                {
                    state = HaloState.Working;
                    action = "Writing answer";
                    answerStreaming = true;
                    return true;
                }
                if (eventType == "response.completed" ||
                    eventType == "response.output_text.done" ||
                    eventType == "response.content_part.done")
                {
                    return false;
                }
                if (eventType == "response.output_item.done")
                {
                    completed.Add(itemId);
                    continue;
                }
                if (eventType != "response.output_item.added" ||
                    completed.Contains(itemId))
                {
                    continue;
                }
                if (String.Equals(name, "request_user_input",
                    StringComparison.OrdinalIgnoreCase))
                {
                    state = HaloState.Attention;
                    action = "Needs you";
                }
                else
                {
                    state = HaloState.Working;
                    action = itemType == "message"
                        ? "Writing answer"
                        : GeneratedHaloSpec.FriendlyAction(
                            String.IsNullOrEmpty(name) ? itemType : name);
                }
                return true;
            }
            return false;
        }

        private bool TryParseToolEvent(string body, out string eventType,
            out string itemId, out string itemType, out string name)
        {
            eventType = String.Empty;
            itemId = String.Empty;
            itemType = String.Empty;
            name = String.Empty;
            try
            {
                int jsonStart = body.IndexOf('{');
                if (jsonStart < 0)
                {
                    return false;
                }
                Dictionary<string, object> root = serializer.DeserializeObject(
                    body.Substring(jsonStart)) as Dictionary<string, object>;
                if (root == null)
                {
                    return false;
                }
                eventType = ReadString(root, "type");
                Dictionary<string, object> item = ReadDictionary(root, "item");
                if (eventType == "response.output_text.delta" ||
                    eventType == "response.output_text.done" ||
                    eventType == "response.content_part.done" ||
                    eventType == "response.completed")
                {
                    return true;
                }
                if (item == null)
                {
                    return false;
                }
                itemId = ReadString(item, "id");
                itemType = ReadString(item, "type").ToLowerInvariant();
                name = ReadString(item, "name");
                return !String.IsNullOrEmpty(itemId) &&
                    (itemType == "function_call" ||
                     itemType == "custom_tool_call" ||
                     itemType == "tool_search_call" ||
                     itemType == "message");
            }
            catch
            {
                return false;
            }
        }

        private static string ReadString(Dictionary<string, object> dictionary,
            string key)
        {
            object value;
            return dictionary != null && dictionary.TryGetValue(key, out value) &&
                value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture)
                : String.Empty;
        }

        private static Dictionary<string, object> ReadDictionary(
            Dictionary<string, object> dictionary, string key)
        {
            object value;
            return dictionary != null && dictionary.TryGetValue(key, out value)
                ? value as Dictionary<string, object>
                : null;
        }

        private static string ReadUtf8Column(IntPtr statement, int column)
        {
            IntPtr pointer = sqlite3_column_text(statement, column);
            int length = sqlite3_column_bytes(statement, column);
            if (pointer == IntPtr.Zero || length <= 0)
            {
                return String.Empty;
            }
            byte[] bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl,
            CharSet = CharSet.Ansi)]
        private static extern int sqlite3_open_v2(string filename,
            out IntPtr database, int flags, string vfs);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl,
            CharSet = CharSet.Ansi)]
        private static extern int sqlite3_prepare_v2(IntPtr database, string sql,
            int byteCount, out IntPtr statement, IntPtr tail);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr database);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_busy_timeout(IntPtr database,
            int milliseconds);
    }

public static class CodexFailureReader
    {
        private const int SqliteOpenReadOnly = 0x00000001;
        private const int SqliteRow = 100;
        private static bool unavailable;

        public static bool TryReadRecent(out string detail, out DateTime eventUtc)
        {
            detail = null;
            eventUtc = DateTime.MinValue;
            string root = Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile), ".codex");
            string database = Path.Combine(root, "logs_2.sqlite");
            if (unavailable || !File.Exists(database))
            {
                return false;
            }
            IntPtr connection = IntPtr.Zero;
            IntPtr statement = IntPtr.Zero;
            try
            {
                int opened = sqlite3_open_v2(database, out connection,
                    SqliteOpenReadOnly, null);
                if (opened != 0 || connection == IntPtr.Zero)
                {
                    return false;
                }
                sqlite3_busy_timeout(connection, 80);
                long cutoff = DateTimeOffset.UtcNow.AddMinutes(-2).ToUnixTimeSeconds();
                string query = "select ts || char(9) || replace(replace(" +
                    "coalesce(feedback_log_body,''),char(10),' '),char(13),' ') from logs " +
                    "where ts >= " + cutoff.ToString(CultureInfo.InvariantCulture) +
                    " and lower(level)='error' and (" +
                    "lower(target) like '%client%' or lower(target) like '%auth%' or " +
                    "lower(target) like '%response%' or lower(target) like '%session%') " +
                    "order by id desc limit 24;";
                if (sqlite3_prepare_v2(connection, query, -1, out statement,
                    IntPtr.Zero) != 0 || statement == IntPtr.Zero)
                {
                    return false;
                }
                while (sqlite3_step(statement) == SqliteRow)
                {
                    string line = ReadUtf8Column(statement, 0);
                    int tab = line.IndexOf('\t');
                    if (tab <= 0) continue;
                    long seconds;
                    if (!long.TryParse(line.Substring(0, tab), out seconds)) continue;
                    string matched = GeneratedHaloSpec.ClassifyFailure(
                        line.Substring(tab + 1));
                    if (matched == null) continue;
                    detail = matched;
                    eventUtc = DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime;
                    return true;
                }
            }
            catch (DllNotFoundException)
            {
                unavailable = true;
            }
            catch (EntryPointNotFoundException)
            {
                unavailable = true;
            }
            catch
            {
            }
            finally
            {
                if (statement != IntPtr.Zero)
                {
                    sqlite3_finalize(statement);
                }
                if (connection != IntPtr.Zero)
                {
                    sqlite3_close(connection);
                }
            }
            return false;
        }

        private static string ReadUtf8Column(IntPtr statement, int column)
        {
            IntPtr pointer = sqlite3_column_text(statement, column);
            int length = sqlite3_column_bytes(statement, column);
            if (pointer == IntPtr.Zero || length <= 0)
            {
                return String.Empty;
            }
            byte[] bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl,
            CharSet = CharSet.Ansi)]
        private static extern int sqlite3_open_v2(string filename,
            out IntPtr database, int flags, string vfs);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl,
            CharSet = CharSet.Ansi)]
        private static extern int sqlite3_prepare_v2(IntPtr database, string sql,
            int byteCount, out IntPtr statement, IntPtr tail);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr database);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_busy_timeout(IntPtr database,
            int milliseconds);

    }

public static class RateLimitReader
    {
        public static bool TryRead(out double primaryUsed, out double secondaryUsed)
        {
            UsageMetrics metrics;
            bool result = TryRead(out metrics);
            primaryUsed = metrics.PrimaryUsedPercent;
            secondaryUsed = metrics.SecondaryUsedPercent;
            return result && metrics.HasPrimary && metrics.HasSecondary;
        }

        public static bool TryRead(out UsageMetrics metrics)
        {
            metrics = new UsageMetrics
            {
                ContextInputTokens = -1
            };
            try
            {
                string codexRoot = Path.Combine(Environment.GetFolderPath(
                    Environment.SpecialFolder.UserProfile), ".codex");
                string[] roots =
                {
                    Path.Combine(codexRoot, "sessions"),
                    Path.Combine(codexRoot, "archived_sessions")
                };
                IEnumerable<string> files = roots.Where(Directory.Exists)
                    .SelectMany(delegate(string root)
                    {
                        return Directory.GetFiles(root, "*.jsonl", SearchOption.AllDirectories);
                    })
                    .OrderByDescending(File.GetLastWriteTimeUtc)
                    .Take(GeneratedHaloSpec.RateLimitRecentFileCount);
                foreach (string path in files)
                {
                    string[] lines = ReadTailLines(path);
                    for (int index = lines.Length - 1; index >= Math.Max(0,
                        lines.Length - GeneratedHaloSpec.RateLimitRecentLineCount);
                        index--)
                    {
                        if (!lines[index].Contains(GeneratedHaloSpec.RateLimitMarker))
                        {
                            continue;
                        }
                        object parsed = new JavaScriptSerializer().DeserializeObject(lines[index]);
                        Dictionary<string, object> rootObject = parsed as Dictionary<string, object>;
                        Dictionary<string, object> payload = Child(rootObject,
                            GeneratedHaloSpec.RatePayloadKey);
                        Dictionary<string, object> info = Child(payload,
                            GeneratedHaloSpec.RateInfoKey);
                        Dictionary<string, object> limits = Child(payload,
                            GeneratedHaloSpec.RateLimitsKey);
                        if (limits == null)
                        {
                            limits = Child(info, GeneratedHaloSpec.RateLimitsKey);
                        }
                        Dictionary<string, object> primary = Child(limits,
                            GeneratedHaloSpec.RatePrimaryKey);
                        Dictionary<string, object> secondary = Child(limits,
                            GeneratedHaloSpec.RateSecondaryKey);
                        if (primary != null)
                        {
                            metrics.PrimaryUsedPercent = Number(primary,
                                GeneratedHaloSpec.RateUsedPercentKey);
                            metrics.PrimaryResetUtc = UnixTime(primary, "resets_at");
                            metrics.HasPrimary = true;
                        }
                        if (secondary != null)
                        {
                            metrics.SecondaryUsedPercent = Number(secondary,
                                GeneratedHaloSpec.RateUsedPercentKey);
                            metrics.SecondaryResetUtc = UnixTime(secondary, "resets_at");
                            metrics.HasSecondary = true;
                        }
                        Dictionary<string, object> lastUsage = Child(info,
                            "last_token_usage");
                        if (lastUsage != null && info != null &&
                            lastUsage.ContainsKey("input_tokens") &&
                            info.ContainsKey("model_context_window"))
                        {
                            metrics.ContextInputTokens = Convert.ToInt64(
                                lastUsage["input_tokens"], CultureInfo.InvariantCulture);
                            metrics.ContextWindowTokens = Convert.ToInt64(
                                info["model_context_window"], CultureInfo.InvariantCulture);
                        }
                        if (metrics.HasPrimary || metrics.HasSecondary ||
                            metrics.HasContext)
                        {
                            return true;
                        }
                    }
                }
            }
            catch
            {
            }
            return false;
        }

        private static double Number(Dictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value)
                ? Convert.ToDouble(value, CultureInfo.InvariantCulture) : 0;
        }

        private static DateTime UnixTime(Dictionary<string, object> source, string key)
        {
            object value;
            long seconds;
            if (source == null || !source.TryGetValue(key, out value) ||
                !Int64.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                    NumberStyles.Integer, CultureInfo.InvariantCulture, out seconds) ||
                seconds <= 0)
            {
                return DateTime.MinValue;
            }
            try
            {
                return DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime;
            }
            catch
            {
                return DateTime.MinValue;
            }
        }

        private static string[] ReadTailLines(string path)
        {
            int tailBytes = GeneratedHaloSpec.RateLimitTailBytes;
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                long start = Math.Max(0, stream.Length - tailBytes);
                stream.Seek(start, SeekOrigin.Begin);
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true,
                    4096, false))
                {
                    string text = reader.ReadToEnd();
                    string[] lines = text.Split(new[] { '\r', '\n' },
                        StringSplitOptions.RemoveEmptyEntries);
                    return start > 0 && lines.Length > 1 ? lines.Skip(1).ToArray() : lines;
                }
            }
        }

        private static Dictionary<string, object> Child(Dictionary<string, object> source,
            string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value)
                ? value as Dictionary<string, object> : null;
        }
    }
}

