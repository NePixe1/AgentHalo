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
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;
using DrawingColor = System.Drawing.Color;
using MediaColor = System.Windows.Media.Color;
using MediaBrush = System.Windows.Media.Brush;
using MediaPen = System.Windows.Media.Pen;
using MediaPoint = System.Windows.Point;

[assembly: System.Reflection.AssemblyTitle("Agent Halo")]
[assembly: System.Reflection.AssemblyDescription("Ambient desktop status light for coding agents")]
[assembly: System.Reflection.AssemblyCompany("Agent Halo")]
[assembly: System.Reflection.AssemblyProduct("Agent Halo")]
[assembly: System.Reflection.AssemblyVersion("0.11.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("0.11.0.0")]

namespace CodexHalo
{
    public enum HaloState
    {
        Idle,
        Thinking,
        Working,
        Done,
        Attention,
        Error
    }

    public enum ErrorPresentation
    {
        Flashing,
        Bright,
        Dim
    }

    public sealed class SessionSnapshot
    {
        public string ThreadId;
        public string ProjectName;
        public string WorkingDirectory;
        public HaloState State;
        public string Action;
        public DateTime LastEventUtc;
        public DateTime CompletedUtc;
        public bool Active;
    }

    public sealed class AggregateSnapshot
    {
        public HaloState State;
        public string Label;
        public string Detail;
        public List<SessionSnapshot> Sessions;
    }

    public sealed class HaloSettings
    {
        public bool HasPosition { get; set; }
        public double Left { get; set; }
        public double Top { get; set; }
        public bool AlwaysOnTop { get; set; }
        public bool Paused { get; set; }
        public string InstalledAt { get; set; }
        public Dictionary<string, string> Acknowledged { get; set; }
        public string AcknowledgedErrorAt { get; set; }
        public int HaloScalePercent { get; set; }

        public HaloSettings()
        {
            AlwaysOnTop = true;
            HaloScalePercent = 100;
            InstalledAt = DateTime.UtcNow.ToString("o");
            Acknowledged = new Dictionary<string, string>();
        }

        public DateTime GetInstalledUtc()
        {
            DateTime parsed;
            if (DateTime.TryParse(InstalledAt, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out parsed))
            {
                return parsed.ToUniversalTime();
            }
            return DateTime.UtcNow;
        }

        public DateTime GetAcknowledgedUtc(string threadId)
        {
            string value;
            DateTime parsed;
            if (Acknowledged != null && Acknowledged.TryGetValue(threadId, out value) &&
                DateTime.TryParse(value, CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out parsed))
            {
                return parsed.ToUniversalTime();
            }
            return DateTime.MinValue;
        }

        public void Acknowledge(string threadId, DateTime completedUtc)
        {
            if (Acknowledged == null)
            {
                Acknowledged = new Dictionary<string, string>();
            }
            Acknowledged[threadId] = completedUtc.ToUniversalTime().ToString("o");
        }

        public DateTime GetAcknowledgedErrorUtc()
        {
            DateTime parsed;
            return DateTime.TryParse(AcknowledgedErrorAt, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out parsed)
                ? parsed.ToUniversalTime() : DateTime.MinValue;
        }
    }

    public static class SettingsStorage
    {
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();

        public static string AppDirectory
        {
            get
            {
                string root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                return Path.Combine(root, "CodexHalo");
            }
        }

        public static string SettingsPath
        {
            get { return Path.Combine(AppDirectory, "settings.json"); }
        }

        public static HaloSettings Load()
        {
            try
            {
                if (File.Exists(SettingsPath))
                {
                    HaloSettings result = Serializer.Deserialize<HaloSettings>(
                        File.ReadAllText(SettingsPath, Encoding.UTF8));
                    if (result != null)
                    {
                        bool repaired = false;
                        if (result.Acknowledged == null)
                        {
                            result.Acknowledged = new Dictionary<string, string>();
                            repaired = true;
                        }
                        if (String.IsNullOrEmpty(result.InstalledAt))
                        {
                            result.InstalledAt = DateTime.UtcNow.ToString("o");
                            repaired = true;
                        }
                        if (result.Paused)
                        {
                            // Pause is a temporary runtime control. Persisting it
                            // makes the next launch look like a broken monitor.
                            result.Paused = false;
                            repaired = true;
                        }
                        if (!HaloWindow.IsValidScalePercent(result.HaloScalePercent))
                        {
                            result.HaloScalePercent = 100;
                            repaired = true;
                        }
                        if (repaired)
                        {
                            Save(result);
                        }
                        return result;
                    }
                }
            }
            catch (Exception ex)
            {
                Log("Settings load failed: " + ex.Message);
            }
            return new HaloSettings();
        }

        public static void Save(HaloSettings settings)
        {
            try
            {
                Directory.CreateDirectory(AppDirectory);
                string temp = SettingsPath + ".tmp";
                bool runtimePaused = settings.Paused;
                settings.Paused = false;
                string json;
                try
                {
                    json = Serializer.Serialize(settings);
                }
                finally
                {
                    settings.Paused = runtimePaused;
                }
                File.WriteAllText(temp, json, Encoding.UTF8);
                if (File.Exists(SettingsPath))
                {
                    File.Delete(SettingsPath);
                }
                File.Move(temp, SettingsPath);
            }
            catch (Exception ex)
            {
                Log("Settings save failed: " + ex.Message);
            }
        }

        public static void Log(string text)
        {
            try
            {
                Directory.CreateDirectory(AppDirectory);
                File.AppendAllText(Path.Combine(AppDirectory, "halo.log"),
                    DateTime.Now.ToString("s") + " " + text + Environment.NewLine);
            }
            catch
            {
            }
        }
    }

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
                    ReduceEvent(payloadType, eventUtc);
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

        private void ReduceEvent(string payloadType, DateTime eventUtc)
        {
            string lower = (payloadType ?? String.Empty).ToLowerInvariant();
            if (lower == "task_started" || lower == "user_message")
            {
                inFlightTools = 0;
                workingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.Active = true;
                Snapshot.State = HaloState.Thinking;
                Snapshot.Action = "Planning";
            }
            else if (lower == "task_complete")
            {
                inFlightTools = 0;
                workingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.Active = false;
                Snapshot.State = HaloState.Done;
                Snapshot.Action = "Complete";
                Snapshot.CompletedUtc = eventUtc == DateTime.MinValue ? DateTime.UtcNow : eventUtc;
            }
            else if (lower == "agent_message" || lower.EndsWith("_end"))
            {
                if (lower.EndsWith("_end") && inFlightTools > 0)
                {
                    inFlightTools--;
                }
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
            else if (lower.Contains("approval") || lower.Contains("request_user") ||
                lower.Contains("needs_input"))
            {
                Snapshot.Active = true;
                Snapshot.State = HaloState.Attention;
                Snapshot.Action = "Needs you";
            }
            else if (lower == "turn_aborted" || lower == "turn_failed" ||
                lower == "task_failed" || lower == "task_cancelled" ||
                lower == "task_interrupted" || lower == "fatal_error")
            {
                Snapshot.Active = false;
                Snapshot.State = HaloState.Error;
                Snapshot.Action = "Interrupted";
            }
            else if (lower.EndsWith("_begin") || lower.EndsWith("_start"))
            {
                Snapshot.Active = true;
                Snapshot.State = HaloState.Working;
                Snapshot.Action = FriendlyAction(lower);
            }
        }

        private void ReduceResponse(string payloadType, Dictionary<string, object> payload, DateTime eventUtc)
        {
            string lower = (payloadType ?? String.Empty).ToLowerInvariant();
            if (lower == "function_call")
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
                    Snapshot.Action = FriendlyAction(name);
                }
            }
            else if (lower == "web_search_call" || lower == "tool_search_call" ||
                lower.EndsWith("_call"))
            {
                inFlightTools++;
                ExtendWorkingVisibility(2.2);
                Snapshot.Active = true;
                Snapshot.State = HaloState.Working;
                Snapshot.Action = FriendlyAction(lower);
            }
            else if (lower == "function_call_output" || lower == "tool_search_output" ||
                lower.EndsWith("_output"))
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

        private static string FriendlyAction(string raw)
        {
            string value = (raw ?? String.Empty).ToLowerInvariant();
            if (value.Contains("shell") || value.Contains("command"))
            {
                return "Running command";
            }
            if (value.Contains("apply_patch") || value.Contains("edit") || value.Contains("write"))
            {
                return "Editing files";
            }
            if (value.Contains("web_search") || value.Contains("search_query"))
            {
                return "Searching";
            }
            if (value.Contains("tool_search"))
            {
                return "Finding a tool";
            }
            if (value.Contains("browser"))
            {
                return "Using browser";
            }
            if (value.Contains("image"))
            {
                return "Working with image";
            }
            if (value.Contains("plan"))
            {
                return "Updating plan";
            }
            return "Executing";
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
        private readonly DispatcherTimer timer;
        private DateTime lastDiscoveryUtc;

        public event EventHandler Changed;

        public CodexSessionMonitor()
        {
            root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".codex", "sessions");
            trackers = new Dictionary<string, SessionTracker>(StringComparer.OrdinalIgnoreCase);
            timer = new DispatcherTimer(DispatcherPriority.Background);
            timer.Interval = TimeSpan.FromMilliseconds(220);
            timer.Tick += OnTick;
        }

        public void Start()
        {
            Discover();
            timer.Start();
        }

        public void Stop()
        {
            timer.Stop();
        }

        private void OnTick(object sender, EventArgs e)
        {
            bool changed = false;
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
            if (changed && Changed != null)
            {
                Changed(this, EventArgs.Empty);
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
            DateTime now = DateTime.UtcNow;
            List<SessionSnapshot> sessions = trackers.Values
                .Select(delegate(SessionTracker tracker) { return tracker.Snapshot; })
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
                : primary.ProjectName + " +" + (sessions.Count - 1).ToString(CultureInfo.InvariantCulture);
            return result;
        }

        public List<SessionSnapshot> GetAllRecent()
        {
            return trackers.Values.Select(delegate(SessionTracker tracker) { return tracker.Snapshot; })
                .Where(delegate(SessionSnapshot snapshot)
                {
                    return snapshot.LastEventUtc >= DateTime.UtcNow.AddHours(-24);
                })
                .OrderBy(delegate(SessionSnapshot snapshot) { return StatePriority(snapshot.State); })
                .ThenByDescending(delegate(SessionSnapshot snapshot) { return snapshot.LastEventUtc; })
                .Take(8)
                .ToList();
        }

        public static int StatePriority(HaloState state)
        {
            switch (state)
            {
                case HaloState.Error: return 0;
                case HaloState.Attention: return 1;
                case HaloState.Working: return 2;
                case HaloState.Thinking: return 3;
                case HaloState.Done: return 4;
                default: return 5;
            }
        }

        public static string StateLabel(HaloState state)
        {
            switch (state)
            {
                case HaloState.Thinking: return "THINKING";
                case HaloState.Working: return "EXECUTING";
                case HaloState.Done: return "COMPLETE";
                case HaloState.Attention: return "NEEDS YOU";
                case HaloState.Error: return "INTERRUPTED";
                default: return "READY";
            }
        }

        public void Dispose()
        {
            timer.Stop();
        }
    }

    public sealed class HaloVisual : FrameworkElement
    {
        private struct VisualSnapshot
        {
            public MediaColor Color;
            public double Powered;
            public double Breath;
            public double Intensity;
            public double BodyWidth;
            public double CoreWhite;
            public double GlowGain;
        }

        private readonly Stopwatch clock;
        private HaloState state;
        private HaloState previousState;
        private DateTime stateChangedUtc;
        private MediaColor transitionFromColor;
        private double transitionStartSeconds;
        private double transitionDuration;
        private VisualSnapshot transitionFromVisual;
        private VisualSnapshot renderedVisual;
        private bool hasRenderedFrame;
        private string label;
        private int count;
        private bool isRendering;
        private double testTime;
        private double testSinceState;
        private bool useTestTime;
        private long frameCount;
        private double lastAnimationSeconds;
        private TimeSpan lastRenderingTime;
        private double frameIntervalSumMs;
        private double frameIntervalMaxMs;
        private long frameIntervalCount;
        private long slowFrameCount;
        private double outerPhase;
        private double innerPhase;
        private double outerVelocity;
        private double gapSeparation;
        private bool gapRepelling;
        private double gapRepulsionElapsed;
        private double gapRepulsionStart;
        private double gapRepulsionDuration;
        private int gapRepulsionCount;
        private double smallGapAnchor;
        private double smallGapDriftElapsed;
        private double smallGapInertiaOffset;
        private double smallGapInertiaVelocity;
        private double energy;
        private bool steadyDone;
        private ErrorPresentation errorPresentation;

        public HaloVisual()
        {
            clock = Stopwatch.StartNew();
            state = HaloState.Idle;
            previousState = HaloState.Idle;
            stateChangedUtc = DateTime.UtcNow;
            transitionFromColor = StateColor(HaloState.Idle);
            transitionStartSeconds = -10;
            transitionDuration = 1;
            renderedVisual.Color = transitionFromColor;
            label = "READY";
            energy = TargetEnergy(HaloState.Idle);
            outerPhase = 97;
            gapSeparation = 150;
            innerPhase = outerPhase + gapSeparation;
            smallGapAnchor = innerPhase;
            SnapsToDevicePixels = false;
            Focusable = false;
            Loaded += OnLoaded;
            Unloaded += OnUnloaded;
        }

        public HaloState State
        {
            get { return state; }
        }

        public double MeasuredFps
        {
            get
            {
                return frameIntervalSumMs <= 0 ? 0 :
                    frameIntervalCount * 1000.0 / frameIntervalSumMs;
            }
        }

        public string PerformanceSummary
        {
            get
            {
                double averageMs = frameIntervalCount <= 0 ? 0 :
                    frameIntervalSumMs / frameIntervalCount;
                return String.Format(CultureInfo.InvariantCulture,
                    "{0:F1} FPS\nAverage frame: {1:F2} ms\nWorst frame: {2:F2} ms\nFrames over 25 ms: {3}",
                    MeasuredFps, averageMs, frameIntervalMaxMs, slowFrameCount);
            }
        }

        public void ResetPerformanceMetrics()
        {
            frameCount = 0;
            frameIntervalSumMs = 0;
            frameIntervalMaxMs = 0;
            frameIntervalCount = 0;
            slowFrameCount = 0;
            lastRenderingTime = TimeSpan.Zero;
        }

        public void SetState(HaloState value, string stateLabel, int sessionCount)
        {
            if (state != value)
            {
                double now = clock.Elapsed.TotalSeconds;
                CaptureTransitionStart(now);
                previousState = state;
                state = value;
                stateChangedUtc = DateTime.UtcNow;
                transitionStartSeconds = now;
                transitionDuration = TransitionDuration(previousState, state);
            }
            label = stateLabel ?? CodexSessionMonitor.StateLabel(value);
            count = sessionCount;
            InvalidateVisual();
        }

        public void SetSteadyDone(bool value)
        {
            if (steadyDone != value)
            {
                double now = clock.Elapsed.TotalSeconds;
                CaptureTransitionStart(now);
                steadyDone = value;
                previousState = state;
                stateChangedUtc = DateTime.UtcNow;
                transitionStartSeconds = now;
                transitionDuration = value ? 1.45 : 1.15;
                InvalidateVisual();
            }
        }

        private void CaptureTransitionStart(double now)
        {
            double localTime = Math.Max(0,
                (DateTime.UtcNow - stateChangedUtc).TotalSeconds);
            transitionFromVisual = hasRenderedFrame ? renderedVisual :
                TargetVisual(state, localTime);
            transitionFromColor = transitionFromVisual.Color;
        }

        public void SetErrorPresentation(ErrorPresentation value)
        {
            if (errorPresentation != value)
            {
                double now = clock.Elapsed.TotalSeconds;
                CaptureTransitionStart(now);
                errorPresentation = value;
                previousState = state;
                stateChangedUtc = DateTime.UtcNow;
                transitionStartSeconds = now;
                transitionDuration = value == ErrorPresentation.Flashing ? 0.82 : 1.24;
                InvalidateVisual();
            }
        }

        public void SetTestTime(double seconds)
        {
            useTestTime = true;
            testTime = seconds;
            testSinceState = seconds;
            previousState = state;
            transitionFromColor = StateColor(state);
            transitionFromVisual = TargetVisual(state, seconds);
            transitionStartSeconds = -10;
            stateChangedUtc = DateTime.UtcNow.AddSeconds(-seconds);
            InvalidateVisual();
        }

        public void SetTestTransition(HaloState from, HaloState to, double progress,
            double absoluteTime)
        {
            useTestTime = true;
            previousState = from;
            state = to;
            transitionFromColor = StateColor(from);
            transitionFromVisual = TargetVisual(from, absoluteTime);
            transitionDuration = TransitionDuration(from, to);
            transitionStartSeconds = absoluteTime - transitionDuration *
                Clamp(progress, 0, 1);
            testTime = absoluteTime;
            testSinceState = transitionDuration * Clamp(progress, 0, 1);
            stateChangedUtc = DateTime.UtcNow.AddSeconds(
                -transitionDuration * Clamp(progress, 0, 1));
            InvalidateVisual();
        }

        public void SetTestSteadyGreenTransition(double progress)
        {
            useTestTime = true;
            previousState = HaloState.Done;
            state = HaloState.Done;
            steadyDone = true;
            transitionFromColor = StateColor(HaloState.Done);
            transitionFromVisual = TargetVisual(HaloState.Done, 0);
            transitionFromVisual.Powered = 0.82;
            transitionFromVisual.Breath = 0.90;
            transitionDuration = 1.45;
            testTime = 4;
            transitionStartSeconds = testTime - transitionDuration *
                Clamp(progress, 0, 1);
            testSinceState = transitionDuration * Clamp(progress, 0, 1);
            stateChangedUtc = DateTime.UtcNow.AddSeconds(-testSinceState);
            InvalidateVisual();
        }

        public void SetTestSteadyGreenToThinking(double progress)
        {
            useTestTime = true;
            previousState = HaloState.Done;
            state = HaloState.Thinking;
            steadyDone = false;
            transitionFromColor = StateColor(HaloState.Done);
            transitionFromVisual = TargetVisual(HaloState.Done, 0);
            transitionFromVisual.Powered = 0;
            transitionFromVisual.Breath = 0.34;
            transitionDuration = TransitionDuration(HaloState.Done,
                HaloState.Thinking);
            testTime = 4;
            transitionStartSeconds = testTime - transitionDuration *
                Clamp(progress, 0, 1);
            testSinceState = transitionDuration * Clamp(progress, 0, 1);
            stateChangedUtc = DateTime.UtcNow.AddSeconds(-testSinceState);
            InvalidateVisual();
        }

        public void SetTestErrorPresentationTransition(ErrorPresentation from,
            ErrorPresentation to, double progress)
        {
            useTestTime = true;
            previousState = HaloState.Error;
            state = HaloState.Error;
            errorPresentation = from;
            transitionFromVisual = TargetVisual(HaloState.Error, 0.18);
            transitionFromColor = StateColor(HaloState.Error);
            errorPresentation = to;
            transitionDuration = to == ErrorPresentation.Flashing ? 0.82 : 1.24;
            testTime = 4;
            transitionStartSeconds = testTime - transitionDuration *
                Clamp(progress, 0, 1);
            testSinceState = transitionDuration * Clamp(progress, 0, 1);
            stateChangedUtc = DateTime.UtcNow.AddSeconds(-testSinceState);
            InvalidateVisual();
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            if (!isRendering)
            {
                CompositionTarget.Rendering += OnRendering;
                isRendering = true;
            }
        }

        private void OnUnloaded(object sender, RoutedEventArgs e)
        {
            if (isRendering)
            {
                CompositionTarget.Rendering -= OnRendering;
                isRendering = false;
            }
        }

        private void OnRendering(object sender, EventArgs e)
        {
            double now = clock.Elapsed.TotalSeconds;
            RenderingEventArgs rendering = e as RenderingEventArgs;
            double animationDelta;
            if (rendering != null && lastRenderingTime != TimeSpan.Zero)
            {
                if (rendering.RenderingTime == lastRenderingTime)
                {
                    return;
                }
                animationDelta = (rendering.RenderingTime - lastRenderingTime).TotalSeconds;
            }
            else
            {
                animationDelta = lastAnimationSeconds <= 0 ? 1.0 / 60.0 :
                    now - lastAnimationSeconds;
            }
            if (rendering != null)
            {
                lastRenderingTime = rendering.RenderingTime;
            }
            lastAnimationSeconds = now;
            animationDelta = Clamp(animationDelta, 0.001, 0.08);
            AdvanceAnimation(animationDelta, now);

            if (frameCount > 0)
            {
                double intervalMs = animationDelta * 1000;
                frameIntervalSumMs += intervalMs;
                frameIntervalCount++;
                frameIntervalMaxMs = Math.Max(frameIntervalMaxMs, intervalMs);
                if (intervalMs > 25)
                {
                    slowFrameCount++;
                }
            }
            frameCount++;
            InvalidateVisual();
        }

        protected override void OnRender(DrawingContext dc)
        {
            base.OnRender(dc);
            double width = ActualWidth;
            double height = ActualHeight;
            if (width <= 0 || height <= 0)
            {
                return;
            }

            double t = useTestTime ? testTime : clock.Elapsed.TotalSeconds;
            double sinceState = useTestTime ? testSinceState :
                Math.Max(0, (DateTime.UtcNow - stateChangedUtc).TotalSeconds);
            double transition = TransitionProgress(t);
            MediaPoint center = new MediaPoint(width / 2.0, height / 2.0);
            double scale = Math.Min(width, height) / 112.0;
            dc.PushTransform(new ScaleTransform(scale, scale, center.X, center.Y));

            MediaColor color = AnimatedColor(t);
            double displayEnergy = useTestTime
                ? Lerp(TargetEnergy(previousState), TargetEnergy(state), transition)
                : energy;
            double displayOuterPhase = outerPhase;
            double displayInnerPhase = innerPhase;
            if (useTestTime)
            {
                TestGapPhases(previousState, state, t, transition,
                    out displayOuterPhase, out displayInnerPhase);
            }

            DrawPureRing(dc, center, color, displayEnergy, displayOuterPhase,
                displayInnerPhase, t, sinceState, transition);
            hasRenderedFrame = true;
            dc.Pop();
        }

        private void DrawPureRing(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double gapA, double gapB, double t, double sinceState,
            double transition)
        {
            double localStateTime = useTestTime && transitionStartSeconds < 0
                ? sinceState : Math.Max(0, sinceState - transitionDuration);
            VisualSnapshot target = TargetVisual(state, localStateTime);
            target.Color = color;
            VisualSnapshot visual = TransitionVisual(transitionFromVisual, target,
                transition);
            double breath = visual.Breath;
            double completionFlash = state == HaloState.Done
                && !steadyDone && transition >= 0.999
                    ? CompletionDoubleFlash(localStateTime) : 0;
            double intensity = Clamp(visual.Intensity + displayEnergy * 0.18 +
                completionFlash * 0.5, 0, 1.32);
            double radius = 35.8 + completionFlash * 0.45;
            double bodyWidth = visual.BodyWidth + completionFlash * 0.65;
            double powered = visual.Powered;
            powered = Clamp(powered + completionFlash * 0.82, 0, 1);
            renderedVisual = visual;
            renderedVisual.Color = color;
            renderedVisual.Powered = powered;
            MediaColor dimColor = AdjustSaturation(color, 0.88);
            MediaColor emissionColor = AdjustSaturation(color,
                0.92 + 0.36 * powered);
            MediaColor glowColor = MixColor(emissionColor,
                MediaColor.FromRgb(242, 248, 249), 0.18 + 0.08 * powered);
            double glowGain = visual.GlowGain;
            DrawDynamicRing(dc, center, radius, gapA, gapB,
                NewPen(WithAlpha(emissionColor,
                    Alpha((12 + 39 * powered) * intensity * glowGain)), 19.5));
            DrawDynamicRing(dc, center, radius, gapA, gapB,
                NewPen(WithAlpha(emissionColor,
                    Alpha((22 + 52 * powered) * intensity * glowGain)), 14.5));
            DrawDynamicRing(dc, center, radius, gapA, gapB,
                NewPen(WithAlpha(emissionColor,
                    Alpha((38 + 70 * powered) * intensity * glowGain)), 11.2));
            DrawDynamicRing(dc, center, radius, gapA, gapB,
                NewPen(WithAlpha(glowColor,
                    Alpha(82 * powered * intensity * glowGain)), 9.8));

            MediaColor darkMaterial = MixColor(dimColor,
                MediaColor.FromRgb(18, 24, 26), 0.46);
            MediaColor litMaterial = MixColor(emissionColor,
                MediaColor.FromRgb(250, 253, 252), 0.56);
            MediaColor poweredMaterial = MixColor(darkMaterial, litMaterial,
                0.24 + 0.76 * powered);
            DrawDynamicRing(dc, center, radius, gapA, gapB,
                NewPen(WithAlpha(darkMaterial, Alpha(242 * intensity)),
                    bodyWidth + 1.15));
            DrawDynamicRing(dc, center, radius, gapA, gapB,
                NewPen(WithAlpha(poweredMaterial,
                    Alpha((182 + 73 * powered) * intensity)), bodyWidth));
            MediaColor poweredCore = MixColor(emissionColor,
                MediaColor.FromRgb(253, 255, 255), visual.CoreWhite);
            DrawDynamicRing(dc, center, radius, gapA, gapB,
                NewPen(WithAlpha(poweredCore,
                    Alpha((5 + 235 * powered) * intensity)),
                    bodyWidth - 2.25));
            DrawDynamicRing(dc, center, radius, gapA, gapB,
                NewPen(WithAlpha(MediaColor.FromRgb(255, 255, 255),
                    Alpha(205 * powered * intensity)), 1.65));
        }

        private VisualSnapshot TargetVisual(HaloState value, double localTime)
        {
            VisualSnapshot result = new VisualSnapshot();
            result.Color = StateColor(value);
            result.Breath = StateBreath(value, localTime);
            result.Powered = TargetPowered(value, localTime);
            result.Intensity = 0.50 + result.Breath * 0.18;
            result.BodyWidth = 8.6;
            result.CoreWhite = CoreWhiteFor(value);
            result.GlowGain = GlowGainFor(value);
            if (value == HaloState.Done && steadyDone)
            {
                result.Powered = 0;
                result.Breath = 0.34;
                result.Intensity = 0.56;
            }
            else if (value == HaloState.Attention)
            {
                double pulse = AttentionPulse(localTime);
                result.Powered = 0.10 + 0.90 * pulse;
                result.Breath = 0.28 + 0.72 * pulse;
                result.Intensity = 0.56 + 0.18 * pulse;
                result.BodyWidth = 8.6 + 0.30 * pulse;
            }
            else if (value == HaloState.Error)
            {
                double pulse = ErrorPulse(localTime, errorPresentation);
                result.Powered = errorPresentation == ErrorPresentation.Bright
                    ? 1.0 : errorPresentation == ErrorPresentation.Dim ? 0 : pulse;
                result.Breath = errorPresentation == ErrorPresentation.Dim ? 0.10 : pulse;
                result.Intensity = errorPresentation == ErrorPresentation.Dim
                    ? 0.52 : 0.62 + 0.12 * pulse;
                result.BodyWidth = 8.6 + 0.25 * pulse;
            }
            return result;
        }

        private static VisualSnapshot TransitionVisual(VisualSnapshot from,
            VisualSnapshot to, double progress)
        {
            VisualSnapshot result = new VisualSnapshot();
            double scalarProgress = SmootherStep(Clamp((progress - 0.34) / 0.66, 0, 1));
            result.Color = to.Color;
            result.Powered = TransitionLight(from.Powered, to.Powered, progress);
            result.Breath = Lerp(from.Breath, to.Breath, scalarProgress);
            result.Intensity = Lerp(from.Intensity, to.Intensity, scalarProgress);
            result.BodyWidth = Lerp(from.BodyWidth, to.BodyWidth, scalarProgress);
            result.CoreWhite = Lerp(from.CoreWhite, to.CoreWhite, scalarProgress);
            result.GlowGain = Lerp(from.GlowGain, to.GlowGain, scalarProgress);
            return result;
        }

        private static double TargetPowered(HaloState value, double localTime)
        {
            if (value == HaloState.Thinking)
            {
                return LivingBreath(localTime, 5.5, 1.0, 0.18, 0.70);
            }
            if (value == HaloState.Working)
            {
                return LivingBreath(localTime, 7.2, 1.0, 0.16, 0.78);
            }
            if (value == HaloState.Done)
            {
                return LivingBreath(localTime, 9.2, 0.84, 0.09, 0.76);
            }
            return 0;
        }

        private static double CoreWhiteFor(HaloState value)
        {
            switch (value)
            {
                case HaloState.Thinking: return 0.90;
                case HaloState.Working: return 0.86;
                case HaloState.Error: return 0.91;
                case HaloState.Done: return 0.84;
                default: return 0.82;
            }
        }

        private static double GlowGainFor(HaloState value)
        {
            switch (value)
            {
                case HaloState.Thinking: return 1.13;
                case HaloState.Working: return 1.07;
                case HaloState.Error: return 1.12;
                default: return 1.0;
            }
        }

        private static void DrawDynamicRing(DrawingContext dc, MediaPoint center,
            double radius, double gapA, double gapB, MediaPen pen)
        {
            // The visible clearances account for the thick rounded arc caps.
            // Both remain unmistakable at 112 px while retaining unequal sizes.
            const double gapASize = 30;
            const double gapBSize = 22;
            double aEnd = gapA + gapASize / 2;
            double bStart = gapB - gapBSize / 2;
            double bEnd = gapB + gapBSize / 2;
            double aStart = gapA - gapASize / 2;
            DrawArc(dc, center, radius, aEnd,
                PositiveModulo(bStart - aEnd, 360), pen);
            DrawArc(dc, center, radius, bEnd,
                PositiveModulo(aStart - bEnd, 360), pen);
        }

        private void AdvanceAnimation(double delta, double now)
        {
            double targetOrbitVelocity = TargetGapVelocityA(state) *
                GapVelocityEnvelopeA(state, now);
            outerVelocity = Damp(outerVelocity, targetOrbitVelocity, delta, 2.1);
            energy = Damp(energy, TargetEnergy(state), delta, 4.2);
            outerPhase += outerVelocity * delta;

            if (gapRepelling)
            {
                gapRepulsionElapsed += delta;
                double progress = Clamp(gapRepulsionElapsed /
                    Math.Max(0.01, gapRepulsionDuration), 0, 1);
                gapSeparation = Lerp(gapRepulsionStart, 150,
                    MagneticRepulsionEase(progress));
                innerPhase = outerPhase + gapSeparation;
                if (progress >= 1)
                {
                    gapRepelling = false;
                    gapSeparation = 150;
                    innerPhase = outerPhase + gapSeparation;
                    smallGapAnchor = innerPhase;
                    smallGapDriftElapsed = 0;
                    smallGapInertiaOffset = 0;
                    smallGapInertiaVelocity =
                        RepulsionExitVelocityFromOrbit(outerVelocity);
                }
            }
            else
            {
                smallGapDriftElapsed += delta;
                smallGapInertiaVelocity *= Math.Exp(
                    -SmallGapInertiaDamping(state) * delta);
                smallGapInertiaOffset += smallGapInertiaVelocity * delta;
                innerPhase = smallGapAnchor +
                    smallGapInertiaOffset +
                    SmallGapDriftOffset(state, smallGapDriftElapsed,
                        gapRepulsionCount);
                gapSeparation = PositiveModulo(innerPhase - outerPhase, 360);
                if (gapSeparation <= 41.5 || gapSeparation > 300)
                {
                    gapSeparation = 40;
                    innerPhase = outerPhase + gapSeparation;
                    gapRepelling = true;
                    gapRepulsionElapsed = 0;
                    gapRepulsionStart = gapSeparation;
                    gapRepulsionDuration =
                        RepulsionDurationFromOrbit(outerVelocity);
                    gapRepulsionCount++;
                    smallGapInertiaOffset = 0;
                    smallGapInertiaVelocity = 0;
                }
            }

            if (outerPhase > 36000)
            {
                outerPhase -= 36000;
                innerPhase -= 36000;
            }
        }

        private void DrawAmbientAura(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double t, double sinceState, double transition)
        {
            double breath = StateBreath(state, t);
            double transitionFlash = Math.Sin(Math.PI * transition);
            double intensity = Clamp(displayEnergy * (0.72 + breath * 0.28) +
                transitionFlash * 0.17, 0, 1.4);

            RadialGradientBrush atmosphere = new RadialGradientBrush();
            atmosphere.Center = new MediaPoint(0.5, 0.5);
            atmosphere.GradientOrigin = new MediaPoint(0.5, 0.5);
            atmosphere.RadiusX = atmosphere.RadiusY = 0.5;
            atmosphere.GradientStops.Add(new GradientStop(
                WithAlpha(color, Alpha(16 * intensity)), 0));
            atmosphere.GradientStops.Add(new GradientStop(
                WithAlpha(color, Alpha(10 * intensity)), 0.42));
            atmosphere.GradientStops.Add(new GradientStop(WithAlpha(color, 0), 1));
            dc.DrawEllipse(atmosphere, null, center, 55, 55);

            MediaPen outerGlow = NewPen(WithAlpha(color, Alpha(12 * intensity)), 13);
            MediaPen middleGlow = NewPen(WithAlpha(color, Alpha(20 * intensity)), 7);
            DrawPrecisionSegments(dc, center, 40.2, 0, outerGlow, 1);
            DrawPrecisionSegments(dc, center, 40.2, 0, middleGlow, 1);

            if (state == HaloState.Done && sinceState < 1.8)
            {
                double progress = Clamp(sinceState / 1.8, 0, 1);
                double eased = EaseOutQuint(progress);
                double radius = 40.5 + eased * 18;
                byte alpha = Alpha(82 * Math.Pow(1 - progress, 2.2));
                dc.DrawEllipse(null, NewPen(WithAlpha(color, alpha),
                    0.8 + (1 - progress) * 0.8), center, radius, radius);
            }
        }

        private void DrawMechanicalBase(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double t)
        {
            dc.DrawEllipse(null, NewPen(MediaColor.FromArgb(50, 104, 128, 145), 0.55),
                center, 45.4, 45.4);
            dc.DrawEllipse(null, NewPen(MediaColor.FromArgb(35, 94, 118, 134), 0.55),
                center, 35.5, 35.5);

            for (int i = 0; i < 12; i++)
            {
                double angle = -90 + i * 30;
                double length = i % 3 == 0 ? 2.2 : 1.15;
                DrawArc(dc, center, 45.4, angle - length / 2, length,
                    NewPen(MediaColor.FromArgb(i % 3 == 0 ? (byte)66 : (byte)36,
                        132, 155, 170), 0.8));
            }

            RadialGradientBrush glass = new RadialGradientBrush();
            glass.GradientOrigin = new MediaPoint(0.37, 0.31);
            glass.Center = new MediaPoint(0.5, 0.5);
            glass.RadiusX = glass.RadiusY = 0.58;
            glass.GradientStops.Add(new GradientStop(MediaColor.FromArgb(232, 28, 36, 46), 0));
            glass.GradientStops.Add(new GradientStop(MediaColor.FromArgb(247, 8, 13, 19), 0.68));
            glass.GradientStops.Add(new GradientStop(MediaColor.FromArgb(252, 2, 5, 9), 1));
            dc.DrawEllipse(glass, NewPen(MediaColor.FromArgb(92, 113, 139, 157), 0.65),
                center, 28.2, 28.2);

            RadialGradientBrush innerEmission = new RadialGradientBrush();
            innerEmission.GradientOrigin = new MediaPoint(0.44, 0.4);
            innerEmission.GradientStops.Add(new GradientStop(WithAlpha(color,
                Alpha(24 * displayEnergy)), 0));
            innerEmission.GradientStops.Add(new GradientStop(WithAlpha(color, 0), 1));
            dc.DrawEllipse(innerEmission, null, center, 23.5, 23.5);

            System.Windows.Media.LinearGradientBrush lens =
                new System.Windows.Media.LinearGradientBrush(
                MediaColor.FromArgb(42, 255, 255, 255),
                MediaColor.FromArgb(0, 255, 255, 255), 22);
            dc.DrawEllipse(lens, null, new MediaPoint(center.X - 7.2, center.Y - 8.4),
                7.8, 2.35);

            DrawArc(dc, center, 30.7, 202, 72,
                NewPen(MediaColor.FromArgb(34, 161, 183, 197), 0.6));
            DrawArc(dc, center, 30.7, 292, 34,
                NewPen(WithAlpha(color, Alpha(42 * displayEnergy)), 0.65));
        }

        private void DrawPrimaryRing(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double t, double transition)
        {
            double breath = StateBreath(state, t);
            double intensity = Clamp(0.35 + displayEnergy * 0.58 + breath * 0.12, 0, 1.2);
            double microDrift = 0.65 * Math.Sin(t * 0.54) +
                0.24 * Math.Sin(t * 1.31);

            DrawPrecisionSegments(dc, center, 40.2, microDrift,
                NewPen(MediaColor.FromArgb(118, 26, 35, 43), 3.6), 1);
            DrawPrecisionSegments(dc, center, 40.2, microDrift,
                NewPen(WithAlpha(color, Alpha(15 * intensity)), 9.5), 1);
            DrawPrecisionSegments(dc, center, 40.2, microDrift,
                NewPen(WithAlpha(color, Alpha(34 * intensity)), 4.8), 1);
            DrawPrecisionSegments(dc, center, 40.2, microDrift,
                NewPen(WithAlpha(color, Alpha(208 * intensity)), 2.05), 1);
            DrawPrecisionSegments(dc, center, 39.85, microDrift,
                NewPen(WithAlpha(MixColor(color, MediaColor.FromRgb(239, 251, 255), 0.42),
                    Alpha(132 * intensity)), 0.62), 1);

            if (transition < 0.999)
            {
                double wave = EaseInOutCubic(transition);
                double angle = -92 + wave * 360;
                DrawEnergyPacket(dc, center,
                    MixColor(color, MediaColor.FromRgb(245, 253, 255), 0.72),
                    angle, 40.2, 22, 0.75 + Math.Sin(Math.PI * transition) * 0.25);
            }
        }

        private void DrawStateLayer(DrawingContext dc, MediaPoint center, HaloState layerState,
            MediaColor color, double outer, double inner, double t, double sinceState,
            double opacity)
        {
            opacity = Clamp(opacity, 0, 1);
            if (opacity < 0.004)
            {
                return;
            }

            if (layerState == HaloState.Idle)
            {
                double angle = outer + 24 * SoftWave(t / 7.2);
                DrawArc(dc, center, 40.2, angle, 30,
                    NewPen(WithAlpha(color, Alpha(80 * opacity)), 1.15));
                return;
            }

            if (layerState == HaloState.Thinking)
            {
                double thinkingPhase = outer + 13 * Math.Sin(t * 1.07) +
                    4.5 * Math.Sin(t * 2.41);
                DrawEnergyPacket(dc, center, color, thinkingPhase, 40.2, 25,
                    opacity * (0.72 + 0.28 * SoftWave(t / 2.25)));
                DrawEnergyPacket(dc, center, color, thinkingPhase + 156, 40.2, 12,
                    opacity * 0.48);
                DrawArc(dc, center, 33.3, inner + 14, 58,
                    NewPen(WithAlpha(color, Alpha(72 * opacity)), 0.9));
                for (int i = 0; i < 3; i++)
                {
                    double nodePulse = SoftWave(t / 1.65 + i * 0.21);
                    double angle = inner * 0.46 + i * 120 + 9 * Math.Sin(t * 0.8 + i);
                    MediaPoint point = PointOnCircle(center, 33.3, angle);
                    double size = 0.85 + nodePulse * 0.7;
                    dc.DrawEllipse(new SolidColorBrush(WithAlpha(color,
                        Alpha((90 + nodePulse * 130) * opacity))), null,
                        point, size, size);
                }
                return;
            }

            if (layerState == HaloState.Working)
            {
                double drive = 0.8 + 0.2 * SoftWave(t / 0.86);
                DrawEnergyPacket(dc, center, color, outer + 10, 40.2, 39,
                    opacity * drive);
                DrawEnergyPacket(dc, center,
                    MixColor(color, MediaColor.FromRgb(235, 252, 255), 0.55),
                    outer + 184, 40.2, 17, opacity * 0.58);
                for (int i = 0; i < 14; i++)
                {
                    double alpha = 28 + 82 * Math.Pow((i + 1) / 14.0, 1.8);
                    DrawArc(dc, center, 33.3, inner + i * 25.7,
                        i % 2 == 0 ? 10 : 6,
                        NewPen(WithAlpha(color, Alpha(alpha * opacity)), 0.85));
                }
                DrawEnergyPacket(dc, center, color, inner + 72, 33.3, 20,
                    opacity * 0.72);
                return;
            }

            if (layerState == HaloState.Done)
            {
                double arrival = EaseOutBack(Clamp(sinceState / 0.92, 0, 1));
                dc.DrawEllipse(null, NewPen(WithAlpha(color,
                    Alpha(105 * opacity * arrival)), 0.8), center,
                    34.8 + arrival * 1.2, 34.8 + arrival * 1.2);
                DrawArc(dc, center, 33.3, -90, 360 * Clamp(arrival, 0, 1),
                    NewPen(WithAlpha(color, Alpha(88 * opacity)), 0.85));
                return;
            }

            if (layerState == HaloState.Attention)
            {
                double pulse = DoublePulse(t, 1.34);
                double radius = 34.8 + EaseOutCubic(pulse) * 3.5;
                DrawArc(dc, center, radius, -68, 52,
                    NewPen(WithAlpha(color, Alpha((58 + pulse * 152) * opacity)), 1.25));
                DrawArc(dc, center, radius, 112, 52,
                    NewPen(WithAlpha(color, Alpha((58 + pulse * 152) * opacity)), 1.25));
                if (pulse > 0.08)
                {
                    dc.DrawEllipse(null, NewPen(WithAlpha(color,
                        Alpha(42 * pulse * opacity)), 0.7), center,
                        31 + pulse * 10, 31 + pulse * 10);
                }
                return;
            }

            double tremor = 1.6 * Math.Sin(t * 13.1) + 0.8 * Math.Sin(t * 23.7);
            double errorPulse = 0.45 + 0.55 * DoublePulse(t, 1.08);
            double[] starts = new double[] { -82, -8, 61, 135, 218 };
            double[] lengths = new double[] { 42, 27, 49, 34, 31 };
            for (int i = 0; i < starts.Length; i++)
            {
                DrawArc(dc, center, 35.3 + (i % 2) * 0.7,
                    starts[i] + tremor * (i % 2 == 0 ? 1 : -1), lengths[i],
                    NewPen(WithAlpha(color,
                        Alpha((72 + errorPulse * 112) * opacity)), 1.2));
            }
        }

        private void DrawCenter(DrawingContext dc, MediaPoint center, MediaColor color,
            double displayEnergy, double t, double sinceState, double transition)
        {
            double coreBreath = 0.65 + 0.35 * StateBreath(state, t);
            dc.DrawEllipse(null, NewPen(WithAlpha(color,
                Alpha(42 * displayEnergy)), 0.65), center, 9.2, 9.2);

            DrawGlyph(dc, center, previousState, transitionFromColor, t, sinceState,
                1 - transition);
            DrawGlyph(dc, center, state, color, t, sinceState, transition);

            double genericCoreOpacity =
                (UsesGenericCore(previousState) ? 1 - transition : 0) +
                (UsesGenericCore(state) ? transition : 0);
            if (genericCoreOpacity > 0.01)
            {
                double radius = 2.0 + 1.05 * coreBreath;
                RadialGradientBrush core = new RadialGradientBrush();
                core.GradientStops.Add(new GradientStop(
                    MediaColor.FromArgb(Alpha(235 * genericCoreOpacity),
                        245, 253, 255), 0));
                core.GradientStops.Add(new GradientStop(
                    WithAlpha(color, Alpha(205 * displayEnergy *
                        genericCoreOpacity)), 0.4));
                core.GradientStops.Add(new GradientStop(WithAlpha(color, 0), 1));
                dc.DrawEllipse(core, null, center, radius + 1.6, radius + 1.6);
            }
        }

        private static void DrawGlyph(DrawingContext dc, MediaPoint center, HaloState glyphState,
            MediaColor color, double t, double sinceState, double opacity)
        {
            opacity = Clamp(opacity, 0, 1);
            if (opacity < 0.01)
            {
                return;
            }

            if (glyphState == HaloState.Done)
            {
                double reveal = EaseOutBack(Clamp(sinceState / 0.72, 0, 1));
                double scale = 0.72 + 0.28 * reveal;
                dc.PushTransform(new ScaleTransform(scale, scale, center.X, center.Y));
                StreamGeometry check = new StreamGeometry();
                using (StreamGeometryContext context = check.Open())
                {
                    context.BeginFigure(new MediaPoint(center.X - 7.3, center.Y + 0.2),
                        false, false);
                    context.LineTo(new MediaPoint(center.X - 2.1, center.Y + 5.3),
                        true, false);
                    context.LineTo(new MediaPoint(center.X + 8.2, center.Y - 7.2),
                        true, false);
                }
                MediaPen checkPen = NewPen(WithAlpha(color,
                    Alpha(228 * opacity * reveal)), 2.15);
                checkPen.LineJoin = PenLineJoin.Round;
                dc.DrawGeometry(null, checkPen, check);
                dc.Pop();
                return;
            }

            if (glyphState == HaloState.Attention || glyphState == HaloState.Error)
            {
                double pulse = glyphState == HaloState.Error
                    ? DoublePulse(t, 1.08) : DoublePulse(t, 1.34);
                SolidColorBrush brush = new SolidColorBrush(WithAlpha(color,
                    Alpha((172 + 60 * pulse) * opacity)));
                dc.DrawRoundedRectangle(brush, null,
                    new Rect(center.X - 1.05, center.Y - 7.2, 2.1, 9.3), 1.1, 1.1);
                dc.DrawEllipse(brush, null, new MediaPoint(center.X, center.Y + 6),
                    1.25, 1.25);
                return;
            }

            if (glyphState == HaloState.Working)
            {
                StreamGeometry diamond = new StreamGeometry();
                using (StreamGeometryContext context = diamond.Open())
                {
                    context.BeginFigure(new MediaPoint(center.X, center.Y - 5.1), false, true);
                    context.LineTo(new MediaPoint(center.X + 5.1, center.Y), true, false);
                    context.LineTo(new MediaPoint(center.X, center.Y + 5.1), true, false);
                    context.LineTo(new MediaPoint(center.X - 5.1, center.Y), true, false);
                }
                dc.DrawGeometry(null, NewPen(WithAlpha(color,
                    Alpha(82 * opacity)), 0.75), diamond);
            }
            else if (glyphState == HaloState.Thinking)
            {
                DrawArc(dc, center, 6.2, 28 + 8 * Math.Sin(t * 0.9), 224,
                    NewPen(WithAlpha(color, Alpha(78 * opacity)), 0.75));
            }
            else
            {
                dc.DrawEllipse(null, NewPen(WithAlpha(color,
                    Alpha(52 * opacity)), 0.65), center, 6.4, 6.4);
            }
        }

        private static void DrawPrecisionSegments(DrawingContext dc, MediaPoint center,
            double radius, double rotation, MediaPen pen, double opacity)
        {
            double[] starts = new double[] { -88, 32, 152 };
            for (int i = 0; i < starts.Length; i++)
            {
                DrawArc(dc, center, radius, starts[i] + rotation, 112, pen);
            }
        }

        private static void DrawEnergyPacket(DrawingContext dc, MediaPoint center,
            MediaColor color, double angle, double radius, double tailLength, double opacity)
        {
            opacity = Clamp(opacity, 0, 1);
            const int pieces = 12;
            for (int i = 0; i < pieces; i++)
            {
                double normalized = (i + 1) / (double)pieces;
                double eased = Math.Pow(normalized, 2.35);
                double segmentAngle = angle - tailLength + normalized * tailLength;
                double alpha = 8 + eased * 184;
                DrawArc(dc, center, radius, segmentAngle, Math.Max(1.1,
                    tailLength / pieces * 0.72),
                    NewPen(WithAlpha(color, Alpha(alpha * opacity)),
                        1.15 + eased * 1.35));
            }
            MediaPoint point = PointOnCircle(center, radius, angle);
            dc.DrawEllipse(new SolidColorBrush(WithAlpha(
                MixColor(color, MediaColor.FromRgb(247, 253, 255), 0.72),
                Alpha(232 * opacity))), null, point, 1.55, 1.55);
        }

        private void DrawCount(DrawingContext dc, MediaPoint center, int value)
        {
            MediaPoint badge = new MediaPoint(center.X + 35, center.Y - 31);
            dc.DrawEllipse(new SolidColorBrush(MediaColor.FromArgb(246, 10, 14, 19)),
                NewPen(MediaColor.FromArgb(160, 121, 147, 166), 0.8), badge, 9, 9);
            string text = value > 9 ? "9+" : value.ToString(CultureInfo.InvariantCulture);
            FormattedText formatted = new FormattedText(text, CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight, new Typeface("Segoe UI Semibold"), 9.5,
                System.Windows.Media.Brushes.White, 1.0);
            dc.DrawText(formatted, new MediaPoint(badge.X - formatted.Width / 2,
                badge.Y - formatted.Height / 2 - 0.5));
        }

        private static void DrawArc(DrawingContext dc, MediaPoint center, double radius,
            double startDegrees, double sweepDegrees, MediaPen pen)
        {
            if (sweepDegrees <= 0.001)
            {
                return;
            }
            if (sweepDegrees >= 359.999)
            {
                dc.DrawEllipse(null, pen, center, radius, radius);
                return;
            }
            MediaPoint start = PointOnCircle(center, radius, startDegrees);
            MediaPoint end = PointOnCircle(center, radius, startDegrees + sweepDegrees);
            StreamGeometry geometry = new StreamGeometry();
            using (StreamGeometryContext context = geometry.Open())
            {
                context.BeginFigure(start, false, false);
                context.ArcTo(end, new System.Windows.Size(radius, radius), 0,
                    sweepDegrees > 180, SweepDirection.Clockwise, true, false);
            }
            geometry.Freeze();
            dc.DrawGeometry(null, pen, geometry);
        }

        private static MediaPoint PointOnCircle(MediaPoint center, double radius, double degrees)
        {
            double radians = degrees * Math.PI / 180.0;
            return new MediaPoint(center.X + Math.Cos(radians) * radius,
                center.Y + Math.Sin(radians) * radius);
        }

        private static MediaPen NewPen(MediaColor color, double width)
        {
            MediaPen pen = new MediaPen(new SolidColorBrush(color), width);
            pen.StartLineCap = PenLineCap.Round;
            pen.EndLineCap = PenLineCap.Round;
            return pen;
        }

        private MediaColor AnimatedColor(double time)
        {
            double progress = TransitionProgress(time);
            double colorProgress = SmootherStep(Clamp((progress - 0.18) / 0.56, 0, 1));
            return MixColor(transitionFromColor, StateColor(state), colorProgress);
        }

        private static double TransitionScalar(double from, double to, double progress)
        {
            double blend = SmootherStep(Clamp((progress - 0.42) / 0.58, 0, 1));
            return Lerp(from, to, blend);
        }

        private static double TransitionLight(double from, double to, double progress)
        {
            const double low = 0.08;
            if (progress < 0.36)
            {
                return Lerp(from, Math.Min(from, low),
                    SmootherStep(progress / 0.36));
            }
            if (progress < 0.58)
            {
                return Math.Min(from, low);
            }
            return Lerp(Math.Min(from, low), to,
                SmootherStep((progress - 0.58) / 0.42));
        }

        private double TransitionProgress(double time)
        {
            if (transitionDuration <= 0)
            {
                return 1;
            }
            return SmootherStep(Clamp((time - transitionStartSeconds) /
                transitionDuration, 0, 1));
        }

        private static double TransitionDuration(HaloState from, HaloState to)
        {
            if (to == HaloState.Error)
            {
                return 0.92;
            }
            if (to == HaloState.Attention)
            {
                return 1.02;
            }
            if (to == HaloState.Done)
            {
                return 1.72;
            }
            if (to == HaloState.Working)
            {
                return 1.48;
            }
            if (to == HaloState.Thinking)
            {
                return 1.68;
            }
            return 1.78;
        }

        private static double TargetGapVelocityA(HaloState value)
        {
            switch (value)
            {
                case HaloState.Thinking: return 78;
                case HaloState.Working: return 106;
                case HaloState.Attention: return 46;
                case HaloState.Error: return 60;
                case HaloState.Done: return 38;
                default: return 27;
            }
        }

        private static double RepulsionDurationFromOrbit(double orbitVelocity)
        {
            double speed = Clamp(Math.Abs(orbitVelocity), 14, 92);
            return Clamp(1.42 * Math.Sqrt(72 / speed), 1.28, 3.05);
        }

        private static double SmallGapDriftOffset(HaloState value, double time,
            int cycle)
        {
            double amplitude = value == HaloState.Working ? 8.5 :
                value == HaloState.Thinking ? 7.0 :
                value == HaloState.Error ? 7.5 :
                value == HaloState.Attention ? 6.5 :
                value == HaloState.Done ? 4.2 : 5.2;
            double period = value == HaloState.Working ? 2.8 :
                value == HaloState.Thinking ? 3.6 :
                value == HaloState.Error ? 2.6 :
                value == HaloState.Attention ? 3.3 :
                value == HaloState.Done ? 5.5 : 4.8;
            double direction = cycle % 2 == 0 ? 1 : -1;
            double primary = Math.Sin(time * Math.PI * 2 / period);
            double secondary = 0.22 * (Math.Sin(time * Math.PI * 2 /
                (period * 0.43) + 0.8) - Math.Sin(0.8));
            return direction * amplitude * (primary + secondary);
        }

        private static double RepulsionExitVelocityFromOrbit(double orbitVelocity)
        {
            return Clamp(Math.Abs(orbitVelocity) * 0.42, 9, 38);
        }

        private static double SmallGapInertiaDamping(HaloState value)
        {
            switch (value)
            {
                case HaloState.Working: return 0.72;
                case HaloState.Thinking: return 0.66;
                case HaloState.Error: return 0.84;
                case HaloState.Attention: return 0.76;
                case HaloState.Done: return 0.58;
                default: return 0.62;
            }
        }

        private static double MagneticRepulsionEase(double value)
        {
            value = Clamp(value, 0, 1);
            double smoothPush = SmootherStep(value);
            double magneticBias = Math.Sin(value * Math.PI) * 0.055;
            return Clamp(smoothPush + magneticBias, 0, 1);
        }

        private static double GapVelocityEnvelopeA(HaloState value, double time)
        {
            double period;
            switch (value)
            {
                case HaloState.Working: period = 2.2; break;
                case HaloState.Thinking: period = 4.2; break;
                case HaloState.Attention: period = 4.1; break;
                case HaloState.Error: period = 1.75; break;
                case HaloState.Done: period = 8.5; break;
                default: period = 7.6; break;
            }
            double primary = SoftWave(time / period);
            double secondary = SoftWave(time / (period * 0.47) + 0.29);
            return 0.18 + 0.92 * Math.Pow(primary, 1.65) + 0.22 * secondary;
        }

        private static void TestGapPhases(HaloState from, HaloState to,
            double time, double transition, out double gapA, out double gapB)
        {
            double velocity = Lerp(TargetGapVelocityA(from),
                TargetGapVelocityA(to), transition);
            double cycleDuration = Lerp(CatchCycleDuration(from),
                CatchCycleDuration(to), transition);
            double cycle = PositiveModulo(time, cycleDuration);
            double cycleStart = time - cycle;
            gapA = TestOrbitPhase(velocity, time);
            double cycleStartA = TestOrbitPhase(velocity, cycleStart);
            double representativeOrbitVelocity = velocity * 0.72;
            double repelDuration =
                RepulsionDurationFromOrbit(representativeOrbitVelocity);
            double repelStart = cycleDuration - repelDuration;
            if (cycle < repelStart)
            {
                HaloState dominant = transition >= 0.5 ? to : from;
                double inertiaVelocity =
                    RepulsionExitVelocityFromOrbit(representativeOrbitVelocity);
                double damping = Lerp(SmallGapInertiaDamping(from),
                    SmallGapInertiaDamping(to), transition);
                double inertiaOffset = inertiaVelocity / damping *
                    (1 - Math.Exp(-damping * cycle));
                double drift = SmallGapDriftOffset(dominant, cycle,
                    (int)Math.Floor(time / cycleDuration));
                gapB = cycleStartA + 150 + inertiaOffset + drift;
            }
            else
            {
                double repelProgress = (cycle - repelStart) / repelDuration;
                double separation = Lerp(40, 150,
                    MagneticRepulsionEase(repelProgress));
                gapB = gapA + separation;
            }
        }

        private static double TestOrbitPhase(double velocity, double time)
        {
            return 97 + velocity * time *
                (0.76 + 0.18 * Math.Sin(time * 0.62)) +
                5 * Math.Sin(time * 0.31);
        }

        private static double CatchCycleDuration(HaloState value)
        {
            switch (value)
            {
                case HaloState.Working: return 2.65;
                case HaloState.Thinking: return 3.8;
                case HaloState.Error: return 3.3;
                case HaloState.Attention: return 4.0;
                case HaloState.Done: return 5.4;
                default: return 5.8;
            }
        }

        public static double DiagnosticGapSeparation(double phase)
        {
            return Lerp(40, 150, MagneticRepulsionEase(Clamp(phase, 0, 1)));
        }

        public static double DiagnosticRepulsionDuration(double orbitVelocity)
        {
            return RepulsionDurationFromOrbit(orbitVelocity);
        }

        public static double DiagnosticBreath(HaloState value, double time)
        {
            return StateBreath(value, time);
        }

        public static double DiagnosticPowered(HaloState value, double time)
        {
            if (value == HaloState.Thinking)
                return LivingBreath(time, 5.5, 1.0, 0.18, 0.70);
            if (value == HaloState.Working)
                return LivingBreath(time, 7.2, 1.0, 0.16, 0.78);
            if (value == HaloState.Done)
                return LivingBreath(time, 9.2, 0.84, 0.09, 0.76);
            return 0;
        }

        public static double DiagnosticAttentionPulse(double time)
        {
            return AttentionPulse(time);
        }

        public static double DiagnosticBrightDuration(HaloState value)
        {
            if (value == HaloState.Thinking) return 5.5 * 0.70;
            if (value == HaloState.Working) return 7.2 * 0.78;
            if (value == HaloState.Done) return 9.2 * 0.76;
            return 0;
        }

        public static double DiagnosticCoreWhite(HaloState value)
        {
            return CoreWhiteFor(value);
        }

        public static double DiagnosticTransitionLight(double from, double to,
            double progress)
        {
            return TransitionLight(from, to, SmootherStep(progress));
        }

        private static double CompletionDoubleFlash(double sinceState)
        {
            double first = Math.Exp(-Math.Pow((sinceState - 0.28) / 0.14, 2));
            double second = Math.Exp(-Math.Pow((sinceState - 0.92) / 0.18, 2));
            return Clamp(first + second * 0.90, 0, 1);
        }

        private static double TargetEnergy(HaloState value)
        {
            switch (value)
            {
                case HaloState.Thinking: return 0.86;
                case HaloState.Working: return 1.0;
                case HaloState.Done: return 0.68;
                case HaloState.Attention: return 0.98;
                case HaloState.Error: return 1.0;
                default: return 0.34;
            }
        }

        private static double StateBreath(HaloState value, double time)
        {
            switch (value)
            {
                case HaloState.Thinking:
                    return LivingBreath(time, 5.5, 1.0, 0.26, 0.70);
                case HaloState.Working:
                    return LivingBreath(time, 7.2, 1.0, 0.22, 0.78);
                case HaloState.Done:
                    return LivingBreath(time, 9.2, 0.92, 0.22, 0.76);
                case HaloState.Attention:
                    return 0.18 + 0.82 * AttentionPulse(time);
                case HaloState.Error:
                    return ErrorPulse(time, ErrorPresentation.Flashing);
                default:
                    return 0.18 + 0.22 * SoftWave(time / 6.8);
            }
        }

        private static bool UsesGenericCore(HaloState value)
        {
            return value == HaloState.Idle || value == HaloState.Thinking ||
                value == HaloState.Working;
        }

        public static MediaColor StateColor(HaloState state)
        {
            switch (state)
            {
                case HaloState.Thinking: return MediaColor.FromRgb(226, 170, 31);
                case HaloState.Working: return MediaColor.FromRgb(52, 158, 199);
                case HaloState.Done: return MediaColor.FromRgb(38, 198, 108);
                case HaloState.Attention: return MediaColor.FromRgb(213, 103, 55);
                case HaloState.Error: return MediaColor.FromRgb(218, 50, 86);
                default: return MediaColor.FromRgb(113, 132, 140);
            }
        }

        private static MediaColor WithAlpha(MediaColor color, byte alpha)
        {
            return MediaColor.FromArgb(alpha, color.R, color.G, color.B);
        }

        private static MediaColor MixColor(MediaColor from, MediaColor to, double amount)
        {
            amount = Clamp(amount, 0, 1);
            double r = LinearToSrgb(Lerp(SrgbToLinear(from.R / 255.0),
                SrgbToLinear(to.R / 255.0), amount));
            double g = LinearToSrgb(Lerp(SrgbToLinear(from.G / 255.0),
                SrgbToLinear(to.G / 255.0), amount));
            double b = LinearToSrgb(Lerp(SrgbToLinear(from.B / 255.0),
                SrgbToLinear(to.B / 255.0), amount));
            return MediaColor.FromRgb(Alpha(r * 255), Alpha(g * 255), Alpha(b * 255));
        }

        private static MediaColor AdjustSaturation(MediaColor color, double multiplier)
        {
            double hue;
            double saturation;
            double lightness;
            RgbToHsl(color, out hue, out saturation, out lightness);
            return HslToRgb(hue, Clamp(saturation * multiplier, 0, 1), lightness);
        }

        private static MediaColor MixEmissionColor(MediaColor from, MediaColor to,
            double amount)
        {
            amount = Clamp(amount, 0, 1);
            double fromHue;
            double fromSaturation;
            double fromLightness;
            double toHue;
            double toSaturation;
            double toLightness;
            RgbToHsl(from, out fromHue, out fromSaturation, out fromLightness);
            RgbToHsl(to, out toHue, out toSaturation, out toLightness);

            if (fromSaturation < 0.04)
            {
                fromHue = toHue;
            }
            if (toSaturation < 0.04)
            {
                toHue = fromHue;
            }
            double hueDelta = toHue - fromHue;
            if (hueDelta > 180)
            {
                hueDelta -= 360;
            }
            else if (hueDelta < -180)
            {
                hueDelta += 360;
            }

            if (Math.Abs(hueDelta) > 100)
            {
                MediaColor bridge = MediaColor.FromRgb(218, 241, 248);
                if (amount < 0.5)
                {
                    return MixColor(from, bridge,
                        EaseInOutCubic(amount * 2));
                }
                return MixColor(bridge, to,
                    EaseInOutCubic((amount - 0.5) * 2));
            }

            double hue = PositiveModulo(fromHue + hueDelta * amount, 360);
            double saturation = Lerp(fromSaturation, toSaturation, amount);
            double lightness = Lerp(fromLightness, toLightness, amount);
            return HslToRgb(hue, saturation, lightness);
        }

        private static void RgbToHsl(MediaColor color, out double hue,
            out double saturation, out double lightness)
        {
            double r = color.R / 255.0;
            double g = color.G / 255.0;
            double b = color.B / 255.0;
            double maximum = Math.Max(r, Math.Max(g, b));
            double minimum = Math.Min(r, Math.Min(g, b));
            double delta = maximum - minimum;
            lightness = (maximum + minimum) / 2;
            if (delta < 0.000001)
            {
                hue = 0;
                saturation = 0;
                return;
            }
            saturation = delta / (1 - Math.Abs(2 * lightness - 1));
            if (maximum == r)
            {
                hue = 60 * PositiveModulo((g - b) / delta, 6);
            }
            else if (maximum == g)
            {
                hue = 60 * (((b - r) / delta) + 2);
            }
            else
            {
                hue = 60 * (((r - g) / delta) + 4);
            }
        }

        private static MediaColor HslToRgb(double hue, double saturation,
            double lightness)
        {
            double chroma = (1 - Math.Abs(2 * lightness - 1)) * saturation;
            double segment = hue / 60;
            double x = chroma * (1 - Math.Abs(PositiveModulo(segment, 2) - 1));
            double r1 = 0;
            double g1 = 0;
            double b1 = 0;
            if (segment < 1)
            {
                r1 = chroma; g1 = x;
            }
            else if (segment < 2)
            {
                r1 = x; g1 = chroma;
            }
            else if (segment < 3)
            {
                g1 = chroma; b1 = x;
            }
            else if (segment < 4)
            {
                g1 = x; b1 = chroma;
            }
            else if (segment < 5)
            {
                r1 = x; b1 = chroma;
            }
            else
            {
                r1 = chroma; b1 = x;
            }
            double match = lightness - chroma / 2;
            return MediaColor.FromRgb(Alpha((r1 + match) * 255),
                Alpha((g1 + match) * 255), Alpha((b1 + match) * 255));
        }

        private static double SrgbToLinear(double value)
        {
            return value <= 0.04045 ? value / 12.92 :
                Math.Pow((value + 0.055) / 1.055, 2.4);
        }

        private static double LinearToSrgb(double value)
        {
            value = Clamp(value, 0, 1);
            return value <= 0.0031308 ? value * 12.92 :
                1.055 * Math.Pow(value, 1.0 / 2.4) - 0.055;
        }

        private static double DoublePulse(double time, double period)
        {
            double cycle = PositiveModulo(time, period) / period;
            double first = Math.Exp(-Math.Pow((cycle - 0.13) / 0.055, 2));
            double second = Math.Exp(-Math.Pow((cycle - 0.31) / 0.07, 2));
            return Clamp(first + second * 0.82, 0, 1);
        }

        private static double AttentionPulse(double time)
        {
            double cycle = PositiveModulo(time, 5.8) / 5.8;
            double first = SmoothPulse(cycle, 0.16, 0.095);
            double second = SmoothPulse(cycle, 0.38, 0.11) * 0.82;
            double livingBase = 0.08 + 0.05 * SoftWave(cycle + 0.18);
            return Clamp(livingBase + first + second, 0, 1);
        }

        private static double ErrorPulse(double time, ErrorPresentation presentation)
        {
            if (presentation == ErrorPresentation.Bright) return 0.92;
            if (presentation == ErrorPresentation.Dim) return 0.04;
            double cycle = PositiveModulo(time, 1.55);
            double first = Math.Exp(-Math.Pow((cycle - 0.12) / 0.055, 2));
            double second = Math.Exp(-Math.Pow((cycle - 0.34) / 0.065, 2));
            return Clamp(first + second, 0, 1);
        }

        private static double ThinkingBreath(double time)
        {
            return LivingBreath(time, 5.5, 1.0, 0.26, 0.70);
        }

        private static double LongBrightBreath(double time, double period)
        {
            return LivingBreath(time, period, 1, 0.16, 0.74);
        }

        private static double LivingBreath(double time, double period,
            double maximum, double minimum, double brightShare)
        {
            double phase = PositiveModulo(time, period) / period;
            double center = brightShare + (1 - brightShare) * 0.46;
            double distance = Math.Abs(phase - center);
            distance = Math.Min(distance, 1 - distance);
            double width = Math.Max(0.075, (1 - brightShare) * 0.46);
            double dip = Math.Exp(-Math.Pow(distance / width, 4));
            double micro = 0.018 * Math.Sin(phase * Math.PI * 2) +
                0.009 * Math.Sin(phase * Math.PI * 4 + 0.8);
            return Clamp(maximum - (maximum - minimum) * dip + micro,
                minimum, maximum);
        }

        private static double SmoothPulse(double phase, double center, double width)
        {
            double distance = Math.Abs(phase - center);
            distance = Math.Min(distance, 1 - distance);
            double normalized = Clamp(1 - distance / width, 0, 1);
            return SmootherStep(normalized);
        }

        private static double SoftWave(double phase)
        {
            double cycle = PositiveModulo(phase, 1);
            double triangle = cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2;
            return SmootherStep(triangle);
        }

        private static double LampBreath(double time, double period)
        {
            double phase = PositiveModulo(time, period) / period;
            return 0.5 - 0.5 * Math.Cos(phase * Math.PI * 2);
        }

        private static double PositiveModulo(double value, double modulus)
        {
            double result = value % modulus;
            return result < 0 ? result + modulus : result;
        }

        private static double Damp(double current, double target, double delta, double response)
        {
            return target + (current - target) * Math.Exp(-response * delta);
        }

        private static double SmootherStep(double value)
        {
            value = Clamp(value, 0, 1);
            return value * value * value * (value * (value * 6 - 15) + 10);
        }

        private static double EaseInOutCubic(double value)
        {
            value = Clamp(value, 0, 1);
            return value < 0.5 ? 4 * value * value * value :
                1 - Math.Pow(-2 * value + 2, 3) / 2;
        }

        private static double EaseOutCubic(double value)
        {
            value = Clamp(value, 0, 1);
            return 1 - Math.Pow(1 - value, 3);
        }

        private static double EaseOutQuint(double value)
        {
            value = Clamp(value, 0, 1);
            return 1 - Math.Pow(1 - value, 5);
        }

        private static double EaseOutBack(double value)
        {
            value = Clamp(value, 0, 1);
            const double c1 = 1.70158;
            const double c3 = c1 + 1;
            return 1 + c3 * Math.Pow(value - 1, 3) +
                c1 * Math.Pow(value - 1, 2);
        }

        private static double Lerp(double from, double to, double amount)
        {
            return from + (to - from) * amount;
        }

        private static double Clamp(double value, double minimum, double maximum)
        {
            return Math.Max(minimum, Math.Min(maximum, value));
        }

        private static byte Alpha(double value)
        {
            return (byte)Math.Max(0, Math.Min(255, Math.Round(value)));
        }
    }

    public static class CodexFailureReader
    {
        public static bool TryReadRecent(out string detail, out DateTime eventUtc)
        {
            detail = null;
            eventUtc = DateTime.MinValue;
            string root = Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile), ".codex");
            string database = Path.Combine(root, "logs_2.sqlite");
            string sqlite = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "sqlite3.exe");
            if (!File.Exists(database) || !File.Exists(sqlite))
            {
                return false;
            }
            try
            {
                long cutoff = DateTimeOffset.UtcNow.AddMinutes(-2).ToUnixTimeSeconds();
                string query = "select ts || char(9) || replace(replace(" +
                    "coalesce(feedback_log_body,''),char(10),' '),char(13),' ') from logs " +
                    "where ts >= " + cutoff.ToString(CultureInfo.InvariantCulture) +
                    " and lower(level)='error' and (" +
                    "lower(target) like '%client%' or lower(target) like '%auth%' or " +
                    "lower(target) like '%response%' or lower(target) like '%session%') " +
                    "order by id desc limit 24;";
                ProcessStartInfo start = new ProcessStartInfo
                {
                    FileName = sqlite,
                    Arguments = "-readonly -batch \"" + database.Replace("\"", "\"\"") +
                        "\" \"" + query.Replace("\"", "\"\"") + "\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (Process process = Process.Start(start))
                {
                    string output = process.StandardOutput.ReadToEnd();
                    process.WaitForExit(1500);
                    foreach (string line in output.Split(new[] { '\r', '\n' },
                        StringSplitOptions.RemoveEmptyEntries))
                    {
                        int tab = line.IndexOf('\t');
                        if (tab <= 0) continue;
                        long seconds;
                        if (!long.TryParse(line.Substring(0, tab), out seconds)) continue;
                        string matched = FailureDetail(line.Substring(tab + 1).ToLowerInvariant());
                        if (matched == null) continue;
                        detail = matched;
                        eventUtc = DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime;
                        return true;
                    }
                }
            }
            catch
            {
            }
            return false;
        }

        private static string FailureDetail(string text)
        {
            if (ContainsAny(text, "authentication failed", "unauthorized", "invalid token",
                "sign in again")) return "认证已失效";
            if (ContainsAny(text, "rate limit reached", "usage limit", "quota exceeded",
                "rate_limit_reached")) return "额度已用尽";
            if (ContainsAny(text, "service unavailable", "server overloaded", "overloaded",
                "bad gateway")) return "服务暂时不可用";
            if (ContainsAny(text, "connection failed", "network error", "connection aborted",
                "request timed out", "connect timeout")) return "连接 Codex 失败";
            return null;
        }

        private static bool ContainsAny(string text, params string[] values)
        {
            return values.Any(delegate(string value)
            {
                return text.IndexOf(value, StringComparison.Ordinal) >= 0;
            });
        }

    }

    public static class RateLimitReader
    {
        public static bool TryRead(out double primaryUsed, out double secondaryUsed)
        {
            primaryUsed = 0;
            secondaryUsed = 0;
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
                    .Take(16);
                foreach (string path in files)
                {
                    string[] lines = ReadTailLines(path);
                    for (int index = lines.Length - 1; index >= Math.Max(0, lines.Length - 300);
                        index--)
                    {
                        if (!lines[index].Contains("\"rate_limits\""))
                        {
                            continue;
                        }
                        object parsed = new JavaScriptSerializer().DeserializeObject(lines[index]);
                        Dictionary<string, object> rootObject = parsed as Dictionary<string, object>;
                        Dictionary<string, object> payload = Child(rootObject, "payload");
                        Dictionary<string, object> info = Child(payload, "info");
                        Dictionary<string, object> limits = Child(payload, "rate_limits");
                        if (limits == null)
                        {
                            limits = Child(info, "rate_limits");
                        }
                        Dictionary<string, object> primary = Child(limits, "primary");
                        Dictionary<string, object> secondary = Child(limits, "secondary");
                        if (primary != null && secondary != null)
                        {
                            primaryUsed = Convert.ToDouble(primary["used_percent"],
                                CultureInfo.InvariantCulture);
                            secondaryUsed = Convert.ToDouble(secondary["used_percent"],
                                CultureInfo.InvariantCulture);
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

        private static string[] ReadTailLines(string path)
        {
            const int tailBytes = 1024 * 1024;
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

    public sealed class DetailsWindow : Window
    {
        private readonly TextBlock headline;
        private readonly TextBlock subtitle;
        private readonly Border shell;
        private readonly TextBlock fiveHourValue;
        private readonly TextBlock weekValue;
        private readonly ProgressBar fiveHourBar;
        private readonly ProgressBar weekBar;
        private readonly DispatcherTimer quotaTimer;

        public DetailsWindow()
        {
            Width = 282;
            SizeToContent = SizeToContent.Height;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = System.Windows.Media.Brushes.Transparent;
            ShowInTaskbar = false;
            ResizeMode = ResizeMode.NoResize;
            Topmost = true;

            shell = new Border();
            shell.CornerRadius = new CornerRadius(18);
            shell.Padding = new Thickness(17, 14, 17, 15);
            shell.Background = new SolidColorBrush(MediaColor.FromArgb(224, 250, 252, 253));
            shell.BorderBrush = new SolidColorBrush(MediaColor.FromArgb(176, 205, 214, 220));
            shell.BorderThickness = new Thickness(1);

            StackPanel content = new StackPanel();
            TextBlock brand = NewText("Agent Halo", 11.5, MediaColor.FromRgb(112, 126, 135),
                FontWeights.SemiBold);
            brand.Margin = new Thickness(0, 0, 0, 8);
            content.Children.Add(brand);

            headline = NewText("READY", 20, MediaColor.FromRgb(40, 52, 60),
                FontWeights.Bold);
            content.Children.Add(headline);
            subtitle = NewText("Codex is standing by", 13,
                MediaColor.FromRgb(103, 117, 126), FontWeights.Normal);
            subtitle.Margin = new Thickness(0, 2, 0, 13);
            content.Children.Add(subtitle);

            Grid fiveHour = CreateQuotaRow("5 小时额度", out fiveHourValue, out fiveHourBar);
            content.Children.Add(fiveHour);
            Grid week = CreateQuotaRow("周额度", out weekValue, out weekBar);
            week.Margin = new Thickness(0, 7, 0, 0);
            content.Children.Add(week);

            shell.Child = content;
            Content = shell;
            quotaTimer = new DispatcherTimer();
            quotaTimer.Interval = TimeSpan.FromSeconds(3);
            quotaTimer.Tick += delegate
            {
                if (IsVisible)
                {
                    RefreshQuota();
                }
            };
            quotaTimer.Start();
        }

        public void UpdateContent(AggregateSnapshot aggregate, List<SessionSnapshot> sessions)
        {
            headline.Text = aggregate.Label;
            MediaColor accent = HaloVisual.StateColor(aggregate.State);
            headline.Foreground = new SolidColorBrush(accent);
            subtitle.Text = FriendlyStatusDetail(aggregate, sessions);
            RefreshQuota();
        }

        private static string FriendlyStatusDetail(AggregateSnapshot aggregate,
            List<SessionSnapshot> sessions)
        {
            SessionSnapshot active = sessions.FirstOrDefault(delegate(SessionSnapshot session)
            {
                return session.Active;
            });
            string action = active == null ? String.Empty : active.Action;
            if (action.IndexOf("command", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "正在执行命令";
            }
            if (action.IndexOf("Editing", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "正在编辑文件";
            }
            if (action.IndexOf("Search", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "正在搜索信息";
            }
            switch (aggregate.State)
            {
                case HaloState.Thinking: return "正在思考与规划";
                case HaloState.Working: return "正在执行任务";
                case HaloState.Done: return "任务已完成";
                case HaloState.Attention: return "等待你的授权或输入";
                case HaloState.Error:
                    return String.IsNullOrEmpty(aggregate.Detail)
                        ? "任务已中断" : aggregate.Detail;
                default: return "Codex 正在待命";
            }
        }

        private void RefreshQuota()
        {
            double primary;
            double secondary;
            if (RateLimitReader.TryRead(out primary, out secondary))
            {
                fiveHourBar.Value = 100 - primary;
                weekBar.Value = 100 - secondary;
                fiveHourValue.Text = String.Format(CultureInfo.InvariantCulture,
                    "剩余 {0:0}%", 100 - primary);
                weekValue.Text = String.Format(CultureInfo.InvariantCulture,
                    "剩余 {0:0}%", 100 - secondary);
            }
            else
            {
                fiveHourValue.Text = "暂无数据";
                weekValue.Text = "暂无数据";
                fiveHourBar.Value = 0;
                weekBar.Value = 0;
            }
        }

        private static Grid CreateQuotaRow(string title, out TextBlock value,
            out ProgressBar bar)
        {
            Grid grid = new Grid();
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid labels = new Grid();
            labels.ColumnDefinitions.Add(new ColumnDefinition());
            labels.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock name = NewText(title, 12, MediaColor.FromRgb(99, 112, 120),
                FontWeights.Medium);
            labels.Children.Add(name);
            value = NewText("暂无数据", 12, MediaColor.FromRgb(48, 60, 68),
                FontWeights.SemiBold);
            Grid.SetColumn(value, 1);
            labels.Children.Add(value);
            grid.Children.Add(labels);
            bar = new ProgressBar
            {
                Height = 5,
                Minimum = 0,
                Maximum = 100,
                Margin = new Thickness(0, 5, 0, 0),
                Foreground = new SolidColorBrush(MediaColor.FromRgb(76, 178, 205)),
                Background = new SolidColorBrush(MediaColor.FromArgb(110, 210, 218, 223)),
                BorderThickness = new Thickness(0)
            };
            Grid.SetRow(bar, 1);
            grid.Children.Add(bar);
            return grid;
        }

        private static TextBlock NewText(string text, double size, MediaColor color,
            FontWeight weight)
        {
            return new TextBlock
            {
                Text = text,
                FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Text, Segoe UI"),
                FontSize = size,
                FontWeight = weight,
                Foreground = new SolidColorBrush(color),
                TextTrimming = TextTrimming.CharacterEllipsis
            };
        }
    }

    public sealed class HaloWindow : Window
    {
        private const double HaloSize = 112;
        private static readonly int[] HaloScalePresets = { 75, 100, 125, 150 };
        private readonly HaloSettings settings;
        private readonly CodexSessionMonitor monitor;
        private readonly HaloVisual visual;
        private readonly DetailsWindow details;
        private readonly Forms.NotifyIcon tray;
        private readonly DispatcherTimer foregroundTimer;
        private readonly DispatcherTimer hoverHideTimer;
        private AggregateSnapshot aggregate;
        private MediaPoint dragStart;
        private MediaPoint windowStart;
        private bool dragging;
        private bool moved;
        private HaloState? demoState;
        private ErrorPresentation? demoErrorPresentation;
        private bool codexWasForeground;
        private DateTime activeErrorUtc;
        private DateTime errorDimmedUtc;
        private ErrorPresentation errorPresentation = ErrorPresentation.Flashing;

        public HaloWindow(HaloSettings appSettings)
        {
            settings = appSettings;
            double initialSize = SizeForScale(settings.HaloScalePercent);
            Width = initialSize;
            Height = initialSize;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = System.Windows.Media.Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            Topmost = settings.AlwaysOnTop;
            Title = "Agent Halo";

            visual = new HaloVisual();
            Grid hitSurface = new Grid();
            hitSurface.Background = new SolidColorBrush(MediaColor.FromArgb(1, 0, 0, 0));
            hitSurface.Children.Add(visual);
            Content = hitSurface;
            details = new DetailsWindow();
            monitor = new CodexSessionMonitor();
            monitor.Changed += delegate { RefreshState(); };
            foregroundTimer = new DispatcherTimer(DispatcherPriority.Background);
            foregroundTimer.Interval = TimeSpan.FromMilliseconds(300);
            foregroundTimer.Tick += OnForegroundTick;
            hoverHideTimer = new DispatcherTimer();
            hoverHideTimer.Interval = TimeSpan.FromMilliseconds(220);
            hoverHideTimer.Tick += delegate
            {
                hoverHideTimer.Stop();
                if (!IsMouseOver && !details.IsMouseOver)
                {
                    details.Hide();
                }
            };
            MouseEnter += delegate
            {
                hoverHideTimer.Stop();
                ShowHoverDetails();
            };
            MouseLeave += delegate
            {
                hoverHideTimer.Stop();
                hoverHideTimer.Start();
            };
            details.MouseEnter += delegate { hoverHideTimer.Stop(); };
            details.MouseLeave += delegate
            {
                hoverHideTimer.Stop();
                hoverHideTimer.Start();
            };

            MouseLeftButtonDown += OnMouseDown;
            MouseMove += OnMouseMove;
            MouseLeftButtonUp += OnMouseUp;
            MouseRightButtonUp += delegate
            {
                if (tray.ContextMenuStrip != null)
                {
                    tray.ContextMenuStrip.Show(Forms.Control.MousePosition);
                }
            };
            MouseDoubleClick += OnDoubleClick;
            SourceInitialized += OnSourceInitialized;
            Loaded += OnLoaded;
            Closing += OnClosing;

            tray = new Forms.NotifyIcon();
            tray.Text = "Agent Halo";
            tray.Icon = CreateTrayIcon(DrawingColor.FromArgb(43, 200, 255));
            tray.Visible = true;
            tray.DoubleClick += delegate
            {
                Dispatcher.BeginInvoke(new Action(ToggleDetails));
            };
            BuildTrayMenu();
        }

        public static bool IsValidScalePercent(int value)
        {
            return HaloScalePresets.Contains(value);
        }

        private static double SizeForScale(int percent)
        {
            return HaloSize * percent / 100.0;
        }

        public static double DiagnosticSizeForScale(int percent)
        {
            return SizeForScale(IsValidScalePercent(percent) ? percent : 100);
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            RestorePosition();
            monitor.Start();
            RefreshState();
            codexWasForeground = IsCodexForeground();
            foregroundTimer.Start();
        }

        private void OnForegroundTick(object sender, EventArgs e)
        {
            bool codexIsForeground = IsCodexForeground();
            if (codexIsForeground && !codexWasForeground && !demoState.HasValue &&
                aggregate != null && aggregate.State == HaloState.Done)
            {
                AcknowledgeCompleted();
            }
            if (aggregate != null && aggregate.State == HaloState.Error)
            {
                if (codexIsForeground)
                {
                    errorPresentation = ErrorPresentation.Bright;
                }
                else if (codexWasForeground)
                {
                    errorPresentation = ErrorPresentation.Dim;
                    errorDimmedUtc = DateTime.UtcNow;
                }
            }
            if (codexIsForeground != codexWasForeground ||
                errorPresentation == ErrorPresentation.Dim)
            {
                RefreshState();
            }
            codexWasForeground = codexIsForeground;
        }

        private static bool IsCodexForeground()
        {
            try
            {
                IntPtr handle = GetForegroundWindow();
                if (handle == IntPtr.Zero)
                {
                    return false;
                }
                uint processId;
                GetWindowThreadProcessId(handle, out processId);
                Process process = Process.GetProcessById((int)processId);
                return process.ProcessName.IndexOf("codex",
                           StringComparison.OrdinalIgnoreCase) >= 0 ||
                       process.MainWindowTitle.IndexOf("codex",
                           StringComparison.OrdinalIgnoreCase) >= 0;
            }
            catch
            {
                return false;
            }
        }

        private void OnSourceInitialized(object sender, EventArgs e)
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            int style = GetWindowLong(handle, -20);
            SetWindowLong(handle, -20, style | 0x00000080);
        }

        private void RestorePosition()
        {
            Rect area = GetWorkAreaDip();
            if (settings.HasPosition)
            {
                Left = Math.Max(area.Left - Width + 24, Math.Min(settings.Left, area.Right - 24));
                Top = Math.Max(area.Top - Height + 24, Math.Min(settings.Top, area.Bottom - 24));
            }
            else
            {
                Left = area.Right - Width - 28;
                Top = area.Top + 110;
            }
        }

        private void RefreshState()
        {
            aggregate = monitor.GetAggregate(settings);
            bool codexRunning = IsCodexRunning();
            string appFailure;
            DateTime appFailureUtc;
            if (codexRunning && aggregate.State == HaloState.Idle &&
                CodexFailureReader.TryReadRecent(out appFailure, out appFailureUtc) &&
                appFailureUtc > settings.GetAcknowledgedErrorUtc())
            {
                aggregate.State = HaloState.Error;
                aggregate.Label = CodexSessionMonitor.StateLabel(HaloState.Error);
                aggregate.Detail = appFailure;
                aggregate.Sessions.Add(new SessionSnapshot
                {
                    ThreadId = "codex-app",
                    ProjectName = "Codex",
                    State = HaloState.Error,
                    Action = appFailure,
                    LastEventUtc = appFailureUtc,
                    Active = false
                });
            }
            if (aggregate.State == HaloState.Error)
            {
                DateTime previousErrorUtc = activeErrorUtc;
                SessionSnapshot latestError = aggregate.Sessions
                    .Where(delegate(SessionSnapshot session)
                    {
                        return session.State == HaloState.Error;
                    })
                    .OrderByDescending(delegate(SessionSnapshot session)
                    {
                        return session.LastEventUtc;
                    }).FirstOrDefault();
                activeErrorUtc = latestError == null ? DateTime.UtcNow : latestError.LastEventUtc;
                if (activeErrorUtc <= settings.GetAcknowledgedErrorUtc())
                {
                    aggregate.State = HaloState.Idle;
                }
                else if (activeErrorUtc > previousErrorUtc)
                {
                    errorPresentation = IsCodexForeground()
                        ? ErrorPresentation.Bright : ErrorPresentation.Flashing;
                }
                else if (IsCodexForeground())
                {
                    errorPresentation = ErrorPresentation.Bright;
                }
                else if (errorPresentation != ErrorPresentation.Dim)
                {
                    errorPresentation = ErrorPresentation.Flashing;
                }
            }
            if (errorPresentation == ErrorPresentation.Dim &&
                DateTime.UtcNow - errorDimmedUtc >= TimeSpan.FromMinutes(1))
            {
                settings.AcknowledgedErrorAt = activeErrorUtc.ToString("o");
                SettingsStorage.Save(settings);
                errorPresentation = ErrorPresentation.Flashing;
                aggregate.State = HaloState.Idle;
            }
            if (demoState.HasValue)
            {
                aggregate.State = demoState.Value;
                aggregate.Label = CodexSessionMonitor.StateLabel(demoState.Value);
                aggregate.Detail = "Preview mode";
            }
            int count = aggregate.Sessions == null ? 0 : aggregate.Sessions.Count;
            bool showGreenStandby = !demoState.HasValue && codexRunning &&
                aggregate.State == HaloState.Idle;
            visual.SetSteadyDone(showGreenStandby);
            visual.SetErrorPresentation(demoErrorPresentation ?? errorPresentation);
            visual.SetState(showGreenStandby ? HaloState.Done : aggregate.State,
                showGreenStandby ? "待命" : aggregate.Label, count);
            tray.Text = ("Agent Halo · " + aggregate.Label).Substring(0,
                Math.Min(63, ("Agent Halo · " + aggregate.Label).Length));
            AggregateSnapshot displayAggregate = aggregate;
            if (showGreenStandby)
            {
                displayAggregate = new AggregateSnapshot
                {
                    State = HaloState.Done,
                    Label = "STANDBY",
                    Detail = "Codex 正在待命",
                    Sessions = aggregate.Sessions
                };
            }
            details.UpdateContent(displayAggregate, monitor.GetAllRecent());
        }

        private void OnMouseDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton != MouseButton.Left)
            {
                return;
            }
            dragStart = GetCursorDip();
            windowStart = new MediaPoint(Left, Top);
            dragging = true;
            moved = false;
            CaptureMouse();
        }

        private void OnMouseMove(object sender, MouseEventArgs e)
        {
            if (!dragging || e.LeftButton != MouseButtonState.Pressed)
            {
                return;
            }
            MediaPoint current = GetCursorDip();
            double dx = current.X - dragStart.X;
            double dy = current.Y - dragStart.Y;
            if (Math.Abs(dx) + Math.Abs(dy) > 4)
            {
                moved = true;
            }
            Left = windowStart.X + dx;
            Top = windowStart.Y + dy;
            if (details.IsVisible)
            {
                PositionDetails();
            }
        }

        private void OnMouseUp(object sender, MouseButtonEventArgs e)
        {
            if (!dragging)
            {
                return;
            }
            dragging = false;
            ReleaseMouseCapture();
            if (moved)
            {
                SnapToEdges();
                SavePosition();
            }
            else
            {
                if (aggregate != null && aggregate.State == HaloState.Done && !demoState.HasValue)
                {
                    AcknowledgeCompleted();
                }
                else
                {
                    ToggleDetails();
                }
            }
        }

        private void OnDoubleClick(object sender, MouseButtonEventArgs e)
        {
            BringCodexForward();
            e.Handled = true;
        }

        private void ToggleDetails()
        {
            if (details.IsVisible)
            {
                details.Hide();
            }
            else
            {
                details.Topmost = Topmost;
                details.UpdateContent(aggregate, monitor.GetAllRecent());
                PositionDetails();
                details.Show();
                details.Activate();
                Dispatcher.BeginInvoke(DispatcherPriority.Loaded,
                    new Action(PositionDetails));
            }
        }

        private void ShowHoverDetails()
        {
            if (aggregate == null)
            {
                return;
            }
            details.Topmost = Topmost;
            details.UpdateContent(aggregate, monitor.GetAllRecent());
            PositionDetails();
            if (!details.IsVisible)
            {
                details.Show();
            }
        }

        private void PositionDetails()
        {
            Rect area = GetWorkAreaDip();
            double gap = 10;
            double proposedLeft = Left - details.Width - gap;
            if (proposedLeft < area.Left + 8)
            {
                proposedLeft = Left + Width + gap;
            }
            details.Left = Math.Max(area.Left + 8,
                Math.Min(proposedLeft, area.Right - details.Width - 8));
            details.Top = Math.Max(area.Top + 8,
                Math.Min(Top + Height / 2 - details.ActualHeight / 2,
                    area.Bottom - Math.Max(details.ActualHeight, 230) - 8));
        }

        private void SnapToEdges()
        {
            Rect area = GetWorkAreaDip();
            const double threshold = 26;
            if (Math.Abs(Left - area.Left) < threshold)
            {
                Left = area.Left + 8;
            }
            if (Math.Abs((Left + Width) - area.Right) < threshold)
            {
                Left = area.Right - Width - 8;
            }
            if (Math.Abs(Top - area.Top) < threshold)
            {
                Top = area.Top + 8;
            }
            if (Math.Abs((Top + Height) - area.Bottom) < threshold)
            {
                Top = area.Bottom - Height - 8;
            }
        }

        private MediaPoint GetCursorDip()
        {
            System.Drawing.Point cursor = Forms.Control.MousePosition;
            PresentationSource source = PresentationSource.FromVisual(this);
            if (source != null && source.CompositionTarget != null)
            {
                System.Windows.Media.Matrix fromDevice =
                    source.CompositionTarget.TransformFromDevice;
                return fromDevice.Transform(new MediaPoint(cursor.X, cursor.Y));
            }
            return new MediaPoint(cursor.X, cursor.Y);
        }

        private Rect GetWorkAreaDip()
        {
            PresentationSource source = PresentationSource.FromVisual(this);
            if (source == null || source.CompositionTarget == null)
            {
                return SystemParameters.WorkArea;
            }

            System.Windows.Media.Matrix toDevice =
                source.CompositionTarget.TransformToDevice;
            System.Windows.Media.Matrix fromDevice =
                source.CompositionTarget.TransformFromDevice;
            MediaPoint centerDip = new MediaPoint(
                Double.IsNaN(Left) ? SystemParameters.WorkArea.Right - 60 : Left + Width / 2,
                Double.IsNaN(Top) ? SystemParameters.WorkArea.Top + 160 : Top + Height / 2);
            MediaPoint centerDevice = toDevice.Transform(centerDip);
            Forms.Screen screen = Forms.Screen.FromPoint(new System.Drawing.Point(
                (int)Math.Round(centerDevice.X), (int)Math.Round(centerDevice.Y)));
            System.Drawing.Rectangle work = screen.WorkingArea;
            MediaPoint topLeft = fromDevice.Transform(new MediaPoint(work.Left, work.Top));
            MediaPoint bottomRight = fromDevice.Transform(new MediaPoint(work.Right, work.Bottom));
            return new Rect(topLeft, bottomRight);
        }

        private Rect GetPrimaryWorkAreaDip()
        {
            Forms.Screen primary = Forms.Screen.PrimaryScreen;
            if (primary == null)
            {
                return SystemParameters.WorkArea;
            }
            PresentationSource source = PresentationSource.FromVisual(this);
            if (source == null || source.CompositionTarget == null)
            {
                return SystemParameters.WorkArea;
            }
            System.Windows.Media.Matrix fromDevice =
                source.CompositionTarget.TransformFromDevice;
            System.Drawing.Rectangle work = primary.WorkingArea;
            MediaPoint topLeft = fromDevice.Transform(
                new MediaPoint(work.Left, work.Top));
            MediaPoint bottomRight = fromDevice.Transform(
                new MediaPoint(work.Right, work.Bottom));
            return new Rect(topLeft, bottomRight);
        }

        private void EscapeOffscreen()
        {
            Rect area = GetPrimaryWorkAreaDip();
            Left = area.Right - Width - 28;
            Top = area.Top + 28;
            SavePosition();
            Topmost = settings.AlwaysOnTop;
            Activate();
        }

        private void SavePosition()
        {
            settings.HasPosition = true;
            settings.Left = Left;
            settings.Top = Top;
            SettingsStorage.Save(settings);
        }

        private void ApplyHaloScale(int percent)
        {
            if (!IsValidScalePercent(percent))
            {
                percent = 100;
            }
            double centerX = Double.IsNaN(Left) ? 0 : Left + Width / 2;
            double centerY = Double.IsNaN(Top) ? 0 : Top + Height / 2;
            double size = SizeForScale(percent);
            Width = size;
            Height = size;
            if (!Double.IsNaN(Left) && !Double.IsNaN(Top))
            {
                Left = centerX - size / 2;
                Top = centerY - size / 2;
                Rect area = GetWorkAreaDip();
                Left = Math.Max(area.Left + 8,
                    Math.Min(Left, area.Right - Width - 8));
                Top = Math.Max(area.Top + 8,
                    Math.Min(Top, area.Bottom - Height - 8));
            }
            settings.HaloScalePercent = percent;
            SavePosition();
            PositionDetails();
        }

        private void AcknowledgeCompleted()
        {
            if (aggregate == null || aggregate.Sessions == null)
            {
                return;
            }
            foreach (SessionSnapshot session in aggregate.Sessions)
            {
                if (session.State == HaloState.Done)
                {
                    settings.Acknowledge(session.ThreadId, session.CompletedUtc);
                }
            }
            SettingsStorage.Save(settings);
            RefreshState();
        }

        private static bool IsCodexRunning()
        {
            try
            {
                return Process.GetProcesses().Any(delegate(Process process)
                {
                    try
                    {
                        return process.ProcessName.IndexOf("codex",
                            StringComparison.OrdinalIgnoreCase) >= 0;
                    }
                    catch
                    {
                        return false;
                    }
                });
            }
            catch
            {
                return false;
            }
        }

        private void BuildTrayMenu()
        {
            Forms.ContextMenuStrip menu = new Forms.ContextMenuStrip();
            menu.RenderMode = Forms.ToolStripRenderMode.System;
            menu.Items.Add("确认已完成任务", null, delegate
            {
                Dispatcher.BeginInvoke(new Action(AcknowledgeCompleted));
            });
            menu.Items.Add(new Forms.ToolStripSeparator());

            Forms.ToolStripMenuItem topmost = new Forms.ToolStripMenuItem("始终置顶");
            topmost.Checked = settings.AlwaysOnTop;
            topmost.CheckOnClick = true;
            topmost.CheckedChanged += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    settings.AlwaysOnTop = topmost.Checked;
                    Topmost = settings.AlwaysOnTop;
                    details.Topmost = Topmost;
                    SettingsStorage.Save(settings);
                }));
            };
            menu.Items.Add(topmost);

            Forms.ToolStripMenuItem startup = new Forms.ToolStripMenuItem("开机自动启动");
            startup.Checked = StartupManager.IsEnabled();
            startup.CheckOnClick = true;
            startup.CheckedChanged += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    StartupManager.SetEnabled(startup.Checked);
                }));
            };
            menu.Items.Add(startup);

            Forms.ToolStripMenuItem pause = new Forms.ToolStripMenuItem("暂停状态监听");
            pause.Checked = settings.Paused;
            pause.CheckOnClick = true;
            pause.CheckedChanged += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    settings.Paused = pause.Checked;
                    RefreshState();
                }));
            };
            menu.Items.Add(pause);

            menu.Items.Add("脱离卡死（移到主屏右上角）", null, delegate
            {
                Dispatcher.BeginInvoke(new Action(EscapeOffscreen));
            });

            Forms.ToolStripMenuItem sizeMenu =
                new Forms.ToolStripMenuItem("光环大小");
            foreach (int percent in HaloScalePresets)
            {
                int selectedPercent = percent;
                Forms.ToolStripMenuItem sizeItem = new Forms.ToolStripMenuItem(
                    percent.ToString(CultureInfo.InvariantCulture) + "%");
                sizeItem.Checked = settings.HaloScalePercent == percent;
                sizeItem.Click += delegate
                {
                    Dispatcher.BeginInvoke(new Action(delegate
                    {
                        ApplyHaloScale(selectedPercent);
                        foreach (Forms.ToolStripItem child in sizeMenu.DropDownItems)
                        {
                            Forms.ToolStripMenuItem candidate =
                                child as Forms.ToolStripMenuItem;
                            if (candidate != null)
                            {
                                candidate.Checked = candidate == sizeItem;
                            }
                        }
                    }));
                };
                sizeMenu.DropDownItems.Add(sizeItem);
            }
            menu.Items.Add(sizeMenu);

            Forms.ToolStripMenuItem preview = new Forms.ToolStripMenuItem("预览状态");
            AddPreviewItem(preview, "实时状态", null);
            AddPreviewItem(preview, "思考中", HaloState.Thinking);
            AddPreviewItem(preview, "执行中", HaloState.Working);
            AddPreviewItem(preview, "已完成", HaloState.Done);
            AddPreviewItem(preview, "等待授权（双脉冲）", HaloState.Attention);
            AddPreviewItem(preview, "故障（爆闪）", HaloState.Error,
                ErrorPresentation.Flashing);
            AddPreviewItem(preview, "故障（常亮）", HaloState.Error,
                ErrorPresentation.Bright);
            AddPreviewItem(preview, "故障（暗红）", HaloState.Error,
                ErrorPresentation.Dim);
            AddPreviewItem(preview, "待机", HaloState.Idle);
            menu.Items.Add(preview);

            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("切换到 Codex", null, delegate
            {
                Dispatcher.BeginInvoke(new Action(BringCodexForward));
            });
            menu.Items.Add("退出 Agent Halo", null, delegate
            {
                Dispatcher.BeginInvoke(new Action(Close));
            });
            tray.ContextMenuStrip = menu;
        }

        private void AddPreviewItem(Forms.ToolStripMenuItem parent, string title,
            HaloState? preview)
        {
            AddPreviewItem(parent, title, preview, null);
        }

        private void AddPreviewItem(Forms.ToolStripMenuItem parent, string title,
            HaloState? preview, ErrorPresentation? presentation)
        {
            Forms.ToolStripMenuItem item = new Forms.ToolStripMenuItem(title);
            item.Click += delegate
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    demoState = preview;
                    demoErrorPresentation = presentation;
                    RefreshState();
                }));
            };
            parent.DropDownItems.Add(item);
        }

        private void BringCodexForward()
        {
            try
            {
                Process current = Process.GetCurrentProcess();
                Process candidate = Process.GetProcesses().FirstOrDefault(delegate(Process process)
                {
                    try
                    {
                        return process.Id != current.Id && process.MainWindowHandle != IntPtr.Zero &&
                            (process.ProcessName.IndexOf("codex", StringComparison.OrdinalIgnoreCase) >= 0 ||
                             process.MainWindowTitle.IndexOf("codex", StringComparison.OrdinalIgnoreCase) >= 0);
                    }
                    catch
                    {
                        return false;
                    }
                });
                if (candidate != null)
                {
                    ShowWindow(candidate.MainWindowHandle, 9);
                    SetForegroundWindow(candidate.MainWindowHandle);
                }
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Bring Codex forward failed: " + ex.Message);
            }
        }

        private void OnClosing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            foregroundTimer.Stop();
            hoverHideTimer.Stop();
            SavePosition();
            details.Close();
            monitor.Dispose();
            tray.Visible = false;
            tray.Dispose();
        }

        private static System.Drawing.Icon CreateTrayIcon(DrawingColor color)
        {
            using (Bitmap bitmap = new Bitmap(32, 32))
            using (Graphics graphics = Graphics.FromImage(bitmap))
            using (System.Drawing.Pen glow = new System.Drawing.Pen(
                DrawingColor.FromArgb(80, color), 7))
            using (System.Drawing.Pen ring = new System.Drawing.Pen(color, 3))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.Clear(DrawingColor.Transparent);
                graphics.DrawArc(glow, 5, 5, 22, 22, -52, 140);
                graphics.DrawArc(glow, 5, 5, 22, 22, 106, 194);
                graphics.DrawArc(ring, 5, 5, 22, 22, -52, 140);
                graphics.DrawArc(ring, 5, 5, 22, 22, 106, 194);
                IntPtr handle = bitmap.GetHicon();
                try
                {
                    return (System.Drawing.Icon)System.Drawing.Icon.FromHandle(handle).Clone();
                }
                finally
                {
                    DestroyIcon(handle);
                }
            }
        }

        [DllImport("user32.dll")]
        private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd,
            out uint processId);

        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr handle);
    }

    public static class StartupManager
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string ValueName = "CodexHalo";

        public static bool IsEnabled()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKey, false))
                {
                    return key != null && key.GetValue(ValueName) != null;
                }
            }
            catch
            {
                return false;
            }
        }

        public static void SetEnabled(bool enabled)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (enabled)
                    {
                        string path = Process.GetCurrentProcess().MainModule.FileName;
                        key.SetValue(ValueName, "\"" + path + "\"");
                    }
                    else
                    {
                        key.DeleteValue(ValueName, false);
                    }
                }
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Startup setting failed: " + ex.Message);
            }
        }
    }

    public static class Diagnostics
    {
        public static int RunSelfTest(string outputPath)
        {
            try
            {
                string temp = Path.Combine(Path.GetTempPath(), "codex-halo-selftest-" +
                    Guid.NewGuid().ToString("N") + ".jsonl");
                string id = Guid.NewGuid().ToString();
                string now = DateTime.UtcNow.ToString("o");
                List<string> lines = new List<string>();
                lines.Add("{\"timestamp\":\"" + now + "\",\"type\":\"session_meta\",\"payload\":{\"id\":\"" +
                    id + "\",\"cwd\":\"C:\\\\work\\\\halo\"}}");
                lines.Add("{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}");
                lines.Add("{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"shell_command\"}}");
                File.WriteAllLines(temp, lines.ToArray(), Encoding.UTF8);
                SessionTracker tracker = new SessionTracker(temp);
                Assert(tracker.Snapshot.ProjectName == "halo", "project metadata");
                Assert(tracker.Snapshot.State == HaloState.Working, "function call -> working");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working,
                    "reasoning cannot override in-flight tool");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working,
                    "tool output keeps working visible");
                System.Threading.Thread.Sleep(1900);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Thinking,
                    "working visibility expires to thinking");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"tool_failed\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Thinking,
                    "recoverable tool failure does not become fatal error");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"approval_requested\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention,
                    "approval request -> attention");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_failed\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Error,
                    "terminal turn failure -> error");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Done, "task complete -> done");
                Assert(!tracker.Snapshot.Active, "task complete deactivates session");
                Assert(Math.Abs(HaloVisual.DiagnosticGapSeparation(0) - 40) < 0.001,
                    "magnetic repulsion starts at minimum separation");
                Assert(Math.Abs(HaloVisual.DiagnosticGapSeparation(1) - 150) < 0.001,
                    "magnetic repulsion ends at maximum separation");
                Assert(HaloVisual.DiagnosticRepulsionDuration(28) >
                    HaloVisual.DiagnosticRepulsionDuration(80),
                    "slow orbit uses slower magnetic repulsion");
                Assert(HaloVisual.DiagnosticBreath(HaloState.Thinking, 1.0) >
                    HaloVisual.DiagnosticBreath(HaloState.Thinking, 4.6),
                    "thinking uses long bright and short dim cadence");
                Assert(HaloVisual.DiagnosticBreath(HaloState.Done, 2.0) >
                    HaloVisual.DiagnosticBreath(HaloState.Done, 8.0),
                    "done uses long bright and short dim cadence");
                Assert(HaloVisual.DiagnosticPowered(HaloState.Thinking, 1.0) > 0.85,
                    "thinking has a bright sustained plateau");
                Assert(HaloVisual.DiagnosticPowered(HaloState.Working, 0.8) > 0.88,
                    "working uses a bright sustained plateau");
                Assert(HaloVisual.DiagnosticPowered(HaloState.Working, 6.35) < 0.35,
                    "working includes a shorter dim interval");
                Assert(HaloVisual.DiagnosticTransitionLight(0.9, 0.8, 0.48) < 0.12,
                    "state transition changes color while the ring is dim");
                Assert(HaloVisual.DiagnosticTransitionLight(0.9, 0.0, 0.99) < 0.01,
                    "steady green transition finishes without glow");
                Assert(HaloVisual.DiagnosticAttentionPulse(0.93) > 0.88,
                    "attention first pulse is clearly visible");
                Assert(HaloVisual.DiagnosticAttentionPulse(2.20) > 0.70,
                    "attention second pulse is visible and softer");
                Assert(HaloVisual.DiagnosticAttentionPulse(4.5) < 0.20,
                    "attention leaves a quiet living interval");
                Assert(HaloVisual.DiagnosticPowered(HaloState.Thinking, 0.8) > 0.97,
                    "thinking reaches the full bright tier");
                Assert(HaloVisual.DiagnosticPowered(HaloState.Working, 0.8) > 0.97,
                    "working reaches the full bright tier");
                Assert(HaloVisual.DiagnosticBrightDuration(HaloState.Thinking) <
                    HaloVisual.DiagnosticBrightDuration(HaloState.Working),
                    "thinking bright duration is shorter than working");
                Assert(HaloVisual.DiagnosticCoreWhite(HaloState.Thinking) >
                    HaloVisual.DiagnosticCoreWhite(HaloState.Done),
                    "yellow receives perceptual white-core compensation");
                Assert(Math.Abs(HaloWindow.DiagnosticSizeForScale(75) - 84) < 0.001,
                    "75 percent halo size");
                Assert(Math.Abs(HaloWindow.DiagnosticSizeForScale(100) - 112) < 0.001,
                    "100 percent halo size");
                Assert(Math.Abs(HaloWindow.DiagnosticSizeForScale(125) - 140) < 0.001,
                    "125 percent halo size");
                Assert(Math.Abs(HaloWindow.DiagnosticSizeForScale(150) - 168) < 0.001,
                    "150 percent halo size");
                Assert(Math.Abs(HaloWindow.DiagnosticSizeForScale(99) - 112) < 0.001,
                    "invalid halo size falls back to 100 percent");
                File.Delete(temp);
                File.WriteAllText(outputPath,
                    "PASS\nCodex lifecycle reducer, incremental reader, and gap bounds passed.\n",
                    Encoding.UTF8);
                return 0;
            }
            catch (Exception ex)
            {
                File.WriteAllText(outputPath, "FAIL\n" + ex.ToString(), Encoding.UTF8);
                return 1;
            }
        }

        public static int WriteLiveSnapshot(string outputPath)
        {
            try
            {
                HaloSettings settings = SettingsStorage.Load();
                using (CodexSessionMonitor monitor = new CodexSessionMonitor())
                {
                    monitor.Start();
                    AggregateSnapshot aggregate = monitor.GetAggregate(settings);
                    StringBuilder report = new StringBuilder();
                    report.AppendLine(aggregate.Label);
                    report.AppendLine(aggregate.Detail);
                    report.AppendLine("Sessions: " + aggregate.Sessions.Count.ToString(
                        CultureInfo.InvariantCulture));
                    foreach (SessionSnapshot session in aggregate.Sessions)
                    {
                        report.AppendLine(String.Format(CultureInfo.InvariantCulture,
                            "{0} | {1} | {2}", session.ProjectName,
                            CodexSessionMonitor.StateLabel(session.State), session.Action));
                    }
                    File.WriteAllText(outputPath, report.ToString(), Encoding.UTF8);
                }
                return 0;
            }
            catch (Exception ex)
            {
                File.WriteAllText(outputPath, "FAIL\n" + ex.ToString(), Encoding.UTF8);
                return 1;
            }
        }

        private static void Assert(bool condition, string name)
        {
            if (!condition)
            {
                throw new InvalidOperationException("Assertion failed: " + name);
            }
        }

        public static int RenderStates(string outputDirectory)
        {
            try
            {
                Directory.CreateDirectory(outputDirectory);
                HaloState[] states = new HaloState[]
                {
                    HaloState.Idle,
                    HaloState.Thinking,
                    HaloState.Working,
                    HaloState.Done,
                    HaloState.Attention,
                    HaloState.Error
                };
                foreach (HaloState state in states)
                {
                    Grid stage = new Grid();
                    stage.Width = 160;
                    stage.Height = 160;
                    stage.Background = System.Windows.Media.Brushes.Transparent;
                    HaloVisual visual = new HaloVisual();
                    visual.Width = 132;
                    visual.Height = 132;
                    visual.HorizontalAlignment = HorizontalAlignment.Center;
                    visual.VerticalAlignment = VerticalAlignment.Center;
                    visual.SetState(state, CodexSessionMonitor.StateLabel(state), state == HaloState.Working ? 3 : 1);
                    visual.SetTestTime(PreviewTimeForState(state));
                    stage.Children.Add(visual);
                    stage.Measure(new System.Windows.Size(160, 160));
                    stage.Arrange(new Rect(0, 0, 160, 160));
                    stage.UpdateLayout();

                    RenderTargetBitmap bitmap = new RenderTargetBitmap(320, 320, 192, 192,
                        PixelFormats.Pbgra32);
                    bitmap.Render(stage);
                    PngBitmapEncoder encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    string path = Path.Combine(outputDirectory,
                        state.ToString().ToLowerInvariant() + ".png");
                    using (FileStream stream = File.Create(path))
                    {
                        encoder.Save(stream);
                    }
                }
                RenderPanelPreview(outputDirectory);
                RenderRingBackdropPreview(outputDirectory);
                RenderPeakBrightnessComparison(outputDirectory);
                RenderSizePresetComparison(outputDirectory);
                RenderGapMotionStrip(outputDirectory, HaloState.Idle,
                    "motion-idle.png");
                RenderGapMotionStrip(outputDirectory, HaloState.Working,
                    "motion-working.png");
                RenderGapMotionStrip(outputDirectory, HaloState.Done,
                    "motion-done.png");
                RenderGlowPulseStrip(outputDirectory, HaloState.Thinking,
                    "glow-thinking.png", 5.5);
                RenderGlowPulseStrip(outputDirectory, HaloState.Working,
                    "glow-working.png", 7.2);
                RenderGlowPulseStrip(outputDirectory, HaloState.Attention,
                    "glow-attention-double-pulse.png", 5.8);
                RenderTransitionStrip(outputDirectory, HaloState.Thinking,
                    HaloState.Working, "transition-thinking-working.png");
                RenderTransitionStrip(outputDirectory, HaloState.Working,
                    HaloState.Done, "transition-working-done.png");
                RenderTransitionStrip(outputDirectory, HaloState.Error,
                    HaloState.Thinking, "transition-error-thinking.png");
                RenderSteadyGreenToThinkingStrip(outputDirectory);
                RenderSteadyGreenTransitionStrip(outputDirectory);
                RenderErrorPresentationStrip(outputDirectory,
                    ErrorPresentation.Flashing, ErrorPresentation.Bright,
                    "transition-error-flashing-bright.png");
                RenderErrorPresentationStrip(outputDirectory,
                    ErrorPresentation.Bright, ErrorPresentation.Dim,
                    "transition-error-bright-dim.png");
                RenderErrorPresentationStrip(outputDirectory,
                    ErrorPresentation.Dim, ErrorPresentation.Flashing,
                    "transition-error-dim-flashing.png");
                RenderCompletionFlashStrip(outputDirectory);
                return 0;
            }
            catch (Exception ex)
            {
                File.WriteAllText(Path.Combine(outputDirectory, "render-error.txt"),
                    ex.ToString(), Encoding.UTF8);
                return 1;
            }
        }

        private static void RenderPanelPreview(string outputDirectory)
        {
            DateTime now = DateTime.UtcNow;
            List<SessionSnapshot> sessions = new List<SessionSnapshot>();
            sessions.Add(new SessionSnapshot
            {
                ThreadId = "preview-working",
                ProjectName = "pet-pet",
                WorkingDirectory = @"C:\work\pet-pet",
                State = HaloState.Working,
                Action = "Editing files",
                Active = true,
                LastEventUtc = now
            });
            sessions.Add(new SessionSnapshot
            {
                ThreadId = "preview-thinking",
                ProjectName = "portfolio",
                WorkingDirectory = @"C:\work\portfolio",
                State = HaloState.Thinking,
                Action = "Reviewing result",
                Active = true,
                LastEventUtc = now.AddSeconds(-12)
            });
            sessions.Add(new SessionSnapshot
            {
                ThreadId = "preview-done",
                ProjectName = "api-server",
                WorkingDirectory = @"C:\work\api-server",
                State = HaloState.Done,
                Action = "Complete",
                Active = false,
                LastEventUtc = now.AddMinutes(-4),
                CompletedUtc = now.AddMinutes(-4)
            });
            AggregateSnapshot aggregate = new AggregateSnapshot
            {
                State = HaloState.Working,
                Label = "EXECUTING",
                Detail = "pet-pet +2",
                Sessions = sessions
            };

            DetailsWindow panel = new DetailsWindow();
            panel.UpdateContent(aggregate, sessions);
            FrameworkElement panelContent = panel.Content as FrameworkElement;
            panel.Content = null;

            Grid stage = new Grid();
            stage.Width = 380;
            stage.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));
            panelContent.Width = 324;
            panelContent.Margin = new Thickness(28);
            stage.Children.Add(panelContent);
            stage.Measure(new System.Windows.Size(380, 1000));
            double height = Math.Ceiling(stage.DesiredSize.Height);
            stage.Height = height;
            stage.Arrange(new Rect(0, 0, 380, height));
            stage.UpdateLayout();

            RenderTargetBitmap bitmap = new RenderTargetBitmap(760, (int)(height * 2),
                192, 192, PixelFormats.Pbgra32);
            bitmap.Render(stage);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory, "panel.png")))
            {
                encoder.Save(stream);
            }
            panel.Close();
        }

        private static void RenderGapMotionStrip(string outputDirectory,
            HaloState state, string fileName)
        {
            double[] times;
            if (state == HaloState.Idle)
            {
                times = new double[] { 0, 1.4, 2.8, 3.7, 4.4, 5.1, 5.8 };
            }
            else if (state == HaloState.Done)
            {
                times = new double[] { 0, 1.1, 2.2, 3.0, 3.8, 4.6, 5.4 };
            }
            else
            {
                times = new double[] { 0, 0.55, 1.1, 1.5, 1.9, 2.25, 2.65 };
            }
            const double cellSize = 150;
            Grid strip = new Grid();
            strip.Width = cellSize * times.Length;
            strip.Height = cellSize;
            strip.Background = new SolidColorBrush(MediaColor.FromRgb(21, 24, 28));
            for (int i = 0; i < times.Length; i++)
            {
                strip.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(cellSize)
                });
                HaloVisual visual = new HaloVisual();
                visual.Width = 126;
                visual.Height = 126;
                visual.HorizontalAlignment = HorizontalAlignment.Center;
                visual.VerticalAlignment = VerticalAlignment.Center;
                visual.SetState(state, CodexSessionMonitor.StateLabel(state), 1);
                visual.SetTestTime(times[i]);
                Grid.SetColumn(visual, i);
                strip.Children.Add(visual);
            }

            strip.Measure(new System.Windows.Size(strip.Width, strip.Height));
            strip.Arrange(new Rect(0, 0, strip.Width, strip.Height));
            strip.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                (int)(strip.Width * 2), (int)(strip.Height * 2), 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(strip);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory, fileName)))
            {
                encoder.Save(stream);
            }
        }

        private static void RenderGlowPulseStrip(string outputDirectory,
            HaloState state, string fileName, double period)
        {
            const int frameCount = 9;
            const double cellSize = 140;
            Grid strip = new Grid();
            strip.Width = cellSize * frameCount;
            strip.Height = cellSize;
            strip.Background = new SolidColorBrush(MediaColor.FromRgb(15, 18, 22));
            for (int i = 0; i < frameCount; i++)
            {
                strip.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(cellSize)
                });
                HaloVisual visual = new HaloVisual();
                visual.Width = 122;
                visual.Height = 122;
                visual.HorizontalAlignment = HorizontalAlignment.Center;
                visual.VerticalAlignment = VerticalAlignment.Center;
                visual.SetState(state, CodexSessionMonitor.StateLabel(state), 1);
                visual.SetTestTime(period * i / (frameCount - 1.0));
                Grid.SetColumn(visual, i);
                strip.Children.Add(visual);
            }

            strip.Measure(new System.Windows.Size(strip.Width, strip.Height));
            strip.Arrange(new Rect(0, 0, strip.Width, strip.Height));
            strip.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                (int)(strip.Width * 2), (int)(strip.Height * 2), 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(strip);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                fileName)))
            {
                encoder.Save(stream);
            }
        }

        private static double PreviewTimeForState(HaloState state)
        {
            if (state == HaloState.Done)
            {
                return 0.55;
            }
            if (state == HaloState.Thinking)
            {
                return 2.6;
            }
            if (state == HaloState.Working)
            {
                return 1.6;
            }
            return 2.4;
        }

        private static void RenderRingBackdropPreview(string outputDirectory)
        {
            HaloState[] states = new HaloState[]
            {
                HaloState.Thinking,
                HaloState.Working,
                HaloState.Done,
                HaloState.Error
            };
            Grid stage = new Grid();
            stage.Width = 640;
            stage.Height = 320;
            stage.RowDefinitions.Add(new RowDefinition { Height = new GridLength(160) });
            stage.RowDefinitions.Add(new RowDefinition { Height = new GridLength(160) });
            for (int i = 0; i < states.Length; i++)
            {
                stage.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(160) });
            }

            for (int row = 0; row < 2; row++)
            {
                for (int i = 0; i < states.Length; i++)
                {
                    Border cell = new Border();
                    cell.Background = new SolidColorBrush(row == 0
                        ? MediaColor.FromRgb(21, 24, 28)
                        : MediaColor.FromRgb(226, 230, 232));
                    HaloVisual visual = new HaloVisual();
                    visual.Width = 132;
                    visual.Height = 132;
                    visual.HorizontalAlignment = HorizontalAlignment.Center;
                    visual.VerticalAlignment = VerticalAlignment.Center;
                    visual.SetState(states[i], CodexSessionMonitor.StateLabel(states[i]), 1);
                    visual.SetTestTime(PreviewTimeForState(states[i]));
                    cell.Child = visual;
                    Grid.SetRow(cell, row);
                    Grid.SetColumn(cell, i);
                    stage.Children.Add(cell);
                }
            }

            stage.Measure(new System.Windows.Size(stage.Width, stage.Height));
            stage.Arrange(new Rect(0, 0, stage.Width, stage.Height));
            stage.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(1280, 640, 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(stage);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(
                Path.Combine(outputDirectory, "ring-backdrops.png")))
            {
                encoder.Save(stream);
            }
        }

        private static void RenderPeakBrightnessComparison(string outputDirectory)
        {
            HaloState[] states =
            {
                HaloState.Thinking, HaloState.Working, HaloState.Done, HaloState.Error
            };
            const double cellSize = 170;
            Grid strip = new Grid();
            strip.Width = cellSize * states.Length;
            strip.Height = cellSize;
            strip.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));
            for (int i = 0; i < states.Length; i++)
            {
                strip.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(cellSize)
                });
                HaloVisual visual = new HaloVisual();
                visual.Width = 136;
                visual.Height = 136;
                visual.HorizontalAlignment = HorizontalAlignment.Center;
                visual.VerticalAlignment = VerticalAlignment.Center;
                visual.SetState(states[i], CodexSessionMonitor.StateLabel(states[i]), 1);
                if (states[i] == HaloState.Error)
                {
                    visual.SetErrorPresentation(ErrorPresentation.Bright);
                }
                visual.SetTestTime(0.8);
                Grid.SetColumn(visual, i);
                strip.Children.Add(visual);
            }
            strip.Measure(new System.Windows.Size(strip.Width, strip.Height));
            strip.Arrange(new Rect(0, 0, strip.Width, strip.Height));
            strip.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                (int)(strip.Width * 2), (int)(strip.Height * 2), 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(strip);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                "peak-brightness-comparison.png")))
            {
                encoder.Save(stream);
            }
        }

        private static void RenderSizePresetComparison(string outputDirectory)
        {
            int[] percents = { 75, 100, 125, 150 };
            const double cellSize = 190;
            Grid strip = new Grid();
            strip.Width = cellSize * percents.Length;
            strip.Height = cellSize;
            strip.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));
            for (int i = 0; i < percents.Length; i++)
            {
                strip.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(cellSize)
                });
                HaloVisual visual = new HaloVisual();
                double size = HaloWindow.DiagnosticSizeForScale(percents[i]);
                visual.Width = size;
                visual.Height = size;
                visual.HorizontalAlignment = HorizontalAlignment.Center;
                visual.VerticalAlignment = VerticalAlignment.Center;
                visual.SetState(HaloState.Working, "EXECUTING", 1);
                visual.SetTestTime(0.8);
                Grid.SetColumn(visual, i);
                strip.Children.Add(visual);
            }
            strip.Measure(new System.Windows.Size(strip.Width, strip.Height));
            strip.Arrange(new Rect(0, 0, strip.Width, strip.Height));
            strip.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                (int)(strip.Width * 2), (int)(strip.Height * 2), 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(strip);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                "size-presets.png")))
            {
                encoder.Save(stream);
            }
        }

        private static void RenderTransitionStrip(string outputDirectory,
            HaloState from, HaloState to, string fileName)
        {
            const int frameCount = 7;
            const double cellSize = 150;
            Grid strip = new Grid();
            strip.Width = cellSize * frameCount;
            strip.Height = cellSize;
            strip.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));

            for (int i = 0; i < frameCount; i++)
            {
                strip.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(cellSize)
                });
                HaloVisual visual = new HaloVisual();
                visual.Width = 126;
                visual.Height = 126;
                visual.HorizontalAlignment = HorizontalAlignment.Center;
                visual.VerticalAlignment = VerticalAlignment.Center;
                double progress = i / (double)(frameCount - 1);
                visual.SetTestTransition(from, to, progress, 2.4 + i * 0.13);
                Grid.SetColumn(visual, i);
                strip.Children.Add(visual);
            }

            strip.Measure(new System.Windows.Size(strip.Width, strip.Height));
            strip.Arrange(new Rect(0, 0, strip.Width, strip.Height));
            strip.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                (int)(strip.Width * 2), (int)(strip.Height * 2), 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(strip);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory, fileName)))
            {
                encoder.Save(stream);
            }
        }

        private static void RenderSteadyGreenTransitionStrip(string outputDirectory)
        {
            const int frameCount = 9;
            const double cellSize = 150;
            Grid strip = new Grid();
            strip.Width = cellSize * frameCount;
            strip.Height = cellSize;
            strip.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));
            for (int i = 0; i < frameCount; i++)
            {
                strip.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(cellSize)
                });
                HaloVisual visual = new HaloVisual();
                visual.Width = 126;
                visual.Height = 126;
                visual.HorizontalAlignment = HorizontalAlignment.Center;
                visual.VerticalAlignment = VerticalAlignment.Center;
                visual.SetTestSteadyGreenTransition(i / (double)(frameCount - 1));
                Grid.SetColumn(visual, i);
                strip.Children.Add(visual);
            }
            strip.Measure(new System.Windows.Size(strip.Width, strip.Height));
            strip.Arrange(new Rect(0, 0, strip.Width, strip.Height));
            strip.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                (int)(strip.Width * 2), (int)(strip.Height * 2), 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(strip);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                "transition-done-standby.png")))
            {
                encoder.Save(stream);
            }
        }

        private static void RenderSteadyGreenToThinkingStrip(string outputDirectory)
        {
            const int frameCount = 9;
            const double cellSize = 150;
            Grid strip = new Grid();
            strip.Width = cellSize * frameCount;
            strip.Height = cellSize;
            strip.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));
            for (int i = 0; i < frameCount; i++)
            {
                strip.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(cellSize)
                });
                HaloVisual visual = new HaloVisual();
                visual.Width = 126;
                visual.Height = 126;
                visual.HorizontalAlignment = HorizontalAlignment.Center;
                visual.VerticalAlignment = VerticalAlignment.Center;
                visual.SetTestSteadyGreenToThinking(i / (double)(frameCount - 1));
                Grid.SetColumn(visual, i);
                strip.Children.Add(visual);
            }
            strip.Measure(new System.Windows.Size(strip.Width, strip.Height));
            strip.Arrange(new Rect(0, 0, strip.Width, strip.Height));
            strip.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                (int)(strip.Width * 2), (int)(strip.Height * 2), 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(strip);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                "transition-standby-thinking.png")))
            {
                encoder.Save(stream);
            }
        }

        private static void RenderErrorPresentationStrip(string outputDirectory,
            ErrorPresentation from, ErrorPresentation to, string fileName)
        {
            const int frameCount = 9;
            const double cellSize = 150;
            Grid strip = new Grid();
            strip.Width = cellSize * frameCount;
            strip.Height = cellSize;
            strip.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));
            for (int i = 0; i < frameCount; i++)
            {
                strip.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(cellSize)
                });
                HaloVisual visual = new HaloVisual();
                visual.Width = 126;
                visual.Height = 126;
                visual.HorizontalAlignment = HorizontalAlignment.Center;
                visual.VerticalAlignment = VerticalAlignment.Center;
                visual.SetTestErrorPresentationTransition(from, to,
                    i / (double)(frameCount - 1));
                Grid.SetColumn(visual, i);
                strip.Children.Add(visual);
            }
            strip.Measure(new System.Windows.Size(strip.Width, strip.Height));
            strip.Arrange(new Rect(0, 0, strip.Width, strip.Height));
            strip.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                (int)(strip.Width * 2), (int)(strip.Height * 2), 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(strip);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                fileName)))
            {
                encoder.Save(stream);
            }
        }

        private static void RenderCompletionFlashStrip(string outputDirectory)
        {
            double[] times = new double[] { 0, 0.12, 0.18, 0.31, 0.49, 0.56, 0.78, 1.2 };
            const double cellSize = 150;
            Grid strip = new Grid();
            strip.Width = cellSize * times.Length;
            strip.Height = cellSize;
            strip.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));
            for (int i = 0; i < times.Length; i++)
            {
                strip.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(cellSize)
                });
                HaloVisual visual = new HaloVisual();
                visual.Width = 126;
                visual.Height = 126;
                visual.HorizontalAlignment = HorizontalAlignment.Center;
                visual.VerticalAlignment = VerticalAlignment.Center;
                visual.SetState(HaloState.Done,
                    CodexSessionMonitor.StateLabel(HaloState.Done), 1);
                visual.SetTestTime(times[i]);
                Grid.SetColumn(visual, i);
                strip.Children.Add(visual);
            }

            strip.Measure(new System.Windows.Size(strip.Width, strip.Height));
            strip.Arrange(new Rect(0, 0, strip.Width, strip.Height));
            strip.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                (int)(strip.Width * 2), (int)(strip.Height * 2), 192, 192,
                PixelFormats.Pbgra32);
            bitmap.Render(strip);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                "completion-double-flash.png")))
            {
                encoder.Save(stream);
            }
        }

        public static void RunBenchmark(string outputPath)
        {
            Window window = new Window();
            window.Width = 112;
            window.Height = 112;
            window.WindowStyle = WindowStyle.None;
            window.AllowsTransparency = true;
            window.Background = System.Windows.Media.Brushes.Transparent;
            window.ShowInTaskbar = false;
            window.Left = SystemParameters.WorkArea.Left + 20;
            window.Top = SystemParameters.WorkArea.Top + 20;
            HaloVisual visual = new HaloVisual();
            visual.SetState(HaloState.Working, "EXECUTING", 1);
            window.Content = visual;
            window.Show();

            DispatcherTimer measurement = new DispatcherTimer();
            measurement.Interval = TimeSpan.FromSeconds(4);
            measurement.Tick += delegate
            {
                measurement.Stop();
                File.WriteAllText(outputPath,
                    visual.PerformanceSummary, Encoding.UTF8);
                window.Close();
                Application.Current.Shutdown();
            };

            DispatcherTimer warmup = new DispatcherTimer();
            warmup.Interval = TimeSpan.FromSeconds(1);
            warmup.Tick += delegate
            {
                warmup.Stop();
                visual.ResetPerformanceMetrics();
                measurement.Start();
            };
            warmup.Start();
        }
    }

    public static class Program
    {
        private static Mutex mutex;

        [STAThread]
        public static int Main()
        {
            string[] args = Environment.GetCommandLineArgs();
            if (args.Length >= 3 && args[1] == "--self-test")
            {
                return Diagnostics.RunSelfTest(args[2]);
            }
            if (args.Length >= 3 && args[1] == "--snapshot")
            {
                return Diagnostics.WriteLiveSnapshot(args[2]);
            }

            Application app = new Application();
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            app.DispatcherUnhandledException += delegate(object sender,
                DispatcherUnhandledExceptionEventArgs e)
            {
                SettingsStorage.Log("Unhandled UI error: " + e.Exception);
                e.Handled = true;
            };

            if (args.Length >= 3 && args[1] == "--render-states")
            {
                int result = Diagnostics.RenderStates(args[2]);
                app.Shutdown(result);
                return result;
            }
            if (args.Length >= 3 && args[1] == "--benchmark")
            {
                Diagnostics.RunBenchmark(args[2]);
                app.Run();
                return 0;
            }

            bool created;
            mutex = new Mutex(true, "Local\\CodexHalo-9A542DB9-A944-4B38-AED0-84BE7419D0BB",
                out created);
            if (!created)
            {
                return 0;
            }

            HaloWindow window = new HaloWindow(SettingsStorage.Load());
            app.ShutdownMode = ShutdownMode.OnMainWindowClose;
            app.MainWindow = window;
            window.Show();
            app.Run();
            GC.KeepAlive(mutex);
            return 0;
        }
    }
}
