using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    /// <summary>
    /// Writes (or updates) Grok Build hook configuration so Agent Halo receives
    /// lifecycle events. Target: %USERPROFILE%\.grok\hooks\agent-halo-status.json
    /// Command format mirrors Claude: "\"exe\" --claude-hook Event" (hook writer
    /// routes via GROK_* env to grok-build-status.jsonl).
    /// </summary>
    public static class GrokHookConfigurator
    {
        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();

        // Grok Build lifecycle set (macOS GrokHookConfigurator) — no Claude-only
        // PostToolBatch / PermissionRequest / PermissionDenied.
        private static readonly HookSpec[] HookSpecs =
        {
            new HookSpec("SessionStart", null),
            new HookSpec("UserPromptSubmit", null),
            new HookSpec("PreToolUse", ".*"),
            new HookSpec("PostToolUse", ".*"),
            new HookSpec("PostToolUseFailure", ".*"),
            new HookSpec("Notification", null),
            new HookSpec("Stop", null),
            new HookSpec("StopFailure", null),
            new HookSpec("SessionEnd", null),
            new HookSpec("PreCompact", ""),
            new HookSpec("PostCompact", "")
        };

        public static void Configure()
        {
            try
            {
                string exe = Process.GetCurrentProcess().MainModule.FileName;
                Configure(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    exe);
            }
            catch (Exception ex)
            {
                SettingsStorage.Log("Grok hook configure failed: " + ex.Message);
            }
        }

        public static void Configure(string home, string executablePath)
        {
            if (String.IsNullOrEmpty(home) || String.IsNullOrEmpty(executablePath))
            {
                return;
            }
            string hooksDir = Path.Combine(home, ".grok", "hooks");
            string hooksPath = Path.Combine(hooksDir, "agent-halo-status.json");

            Dictionary<string, object> hooks = new Dictionary<string, object>();
            foreach (HookSpec spec in HookSpecs)
            {
                string command = Quote(executablePath) + " --claude-hook " + spec.Event;
                hooks[spec.Event] = new object[] { CreateHookEntry(spec, command) };
            }

            if (IsAlreadyConfigured(hooksPath, executablePath))
            {
                return;
            }

            Dictionary<string, object> config = new Dictionary<string, object>();
            config["hooks"] = hooks;
            Directory.CreateDirectory(hooksDir);
            File.WriteAllText(hooksPath,
                PrettyPrintJson(Serializer.Serialize(config)),
                new UTF8Encoding(false));
        }

        private static bool IsAlreadyConfigured(string hooksPath, string executablePath)
        {
            try
            {
                if (!File.Exists(hooksPath))
                {
                    return false;
                }
                Dictionary<string, object> root = Serializer.DeserializeObject(
                    File.ReadAllText(hooksPath, Encoding.UTF8)) as Dictionary<string, object>;
                if (root == null)
                {
                    return false;
                }
                Dictionary<string, object> hooks = GetDictionary(root, "hooks");
                if (hooks == null)
                {
                    return false;
                }
                foreach (HookSpec spec in HookSpecs)
                {
                    string command = Quote(executablePath) + " --claude-hook " +
                        spec.Event;
                    object existing;
                    object[] entries = hooks.TryGetValue(spec.Event, out existing)
                        ? existing as object[] : null;
                    if (entries == null || entries.Length == 0)
                    {
                        return false;
                    }
                    bool found = false;
                    foreach (object item in entries)
                    {
                        Dictionary<string, object> entry =
                            item as Dictionary<string, object>;
                        if (EntryMatches(entry, spec, command))
                        {
                            found = true;
                            break;
                        }
                    }
                    if (!found)
                    {
                        return false;
                    }
                }
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static object CreateHookEntry(HookSpec spec, string command)
        {
            Dictionary<string, object> hook = new Dictionary<string, object>();
            hook["type"] = "command";
            hook["command"] = command;
            Dictionary<string, object> entry = new Dictionary<string, object>();
            if (spec.Matcher != null)
            {
                entry["matcher"] = spec.Matcher;
            }
            entry["hooks"] = new object[] { hook };
            return entry;
        }

        private static bool EntryMatches(Dictionary<string, object> entry,
            HookSpec spec, string command)
        {
            if (entry == null)
            {
                return false;
            }
            if (spec.Matcher != null &&
                !String.Equals(StringValue(entry, "matcher"), spec.Matcher,
                    StringComparison.Ordinal))
            {
                return false;
            }
            return EntryHooks(entry).Any(delegate(Dictionary<string, object> hook)
            {
                string existing = StringValue(hook, "command");
                return String.Equals(existing, command, StringComparison.Ordinal) ||
                    (existing.IndexOf("--claude-hook",
                        StringComparison.OrdinalIgnoreCase) >= 0 &&
                     existing.IndexOf(spec.Event, StringComparison.Ordinal) >= 0);
            });
        }

        private static IEnumerable<Dictionary<string, object>> EntryHooks(
            Dictionary<string, object> entry)
        {
            object value;
            object[] hooks = entry != null && entry.TryGetValue("hooks", out value)
                ? value as object[] : null;
            if (hooks == null)
            {
                yield break;
            }
            foreach (object hook in hooks)
            {
                Dictionary<string, object> dictionary =
                    hook as Dictionary<string, object>;
                if (dictionary != null)
                {
                    yield return dictionary;
                }
            }
        }

        private static Dictionary<string, object> GetDictionary(
            Dictionary<string, object> dictionary, string key)
        {
            object value;
            return dictionary != null && dictionary.TryGetValue(key, out value)
                ? value as Dictionary<string, object> : null;
        }

        private static string StringValue(Dictionary<string, object> dictionary,
            string key)
        {
            object value;
            return dictionary != null && dictionary.TryGetValue(key, out value) &&
                value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture)
                : String.Empty;
        }

        private static string Quote(string path)
        {
            return "\"" + (path ?? String.Empty).Replace("\"", "\\\"") + "\"";
        }

        // JavaScriptSerializer has no indented output — re-emit compact JSON
        // with two-space indentation so ~/.grok/hooks/ stays readable.
        private static string PrettyPrintJson(string compact)
        {
            if (String.IsNullOrWhiteSpace(compact))
            {
                return compact;
            }
            object root;
            try
            {
                root = Serializer.DeserializeObject(compact);
            }
            catch
            {
                return compact;
            }
            StringBuilder builder = new StringBuilder();
            WriteJsonValue(builder, root, 0);
            return builder.ToString();
        }

        private static void WriteJsonValue(StringBuilder builder, object value,
            int depth)
        {
            if (value == null)
            {
                builder.Append("null");
                return;
            }
            Dictionary<string, object> dict = value as Dictionary<string, object>;
            if (dict != null)
            {
                if (dict.Count == 0)
                {
                    builder.Append("{}");
                    return;
                }
                builder.Append('{').Append(Environment.NewLine);
                int index = 0;
                foreach (KeyValuePair<string, object> pair in dict)
                {
                    if (index > 0)
                    {
                        builder.Append(',').Append(Environment.NewLine);
                    }
                    index++;
                    WriteIndent(builder, depth + 1);
                    WriteJsonString(builder, pair.Key);
                    builder.Append(": ");
                    WriteJsonValue(builder, pair.Value, depth + 1);
                }
                builder.Append(Environment.NewLine);
                WriteIndent(builder, depth);
                builder.Append('}');
                return;
            }
            object[] array = value as object[];
            if (array != null)
            {
                if (array.Length == 0)
                {
                    builder.Append("[]");
                    return;
                }
                builder.Append('[').Append(Environment.NewLine);
                for (int i = 0; i < array.Length; i++)
                {
                    if (i > 0)
                    {
                        builder.Append(',').Append(Environment.NewLine);
                    }
                    WriteIndent(builder, depth + 1);
                    WriteJsonValue(builder, array[i], depth + 1);
                }
                builder.Append(Environment.NewLine);
                WriteIndent(builder, depth);
                builder.Append(']');
                return;
            }
            if (value is bool)
            {
                builder.Append((bool)value ? "true" : "false");
                return;
            }
            if (value is string)
            {
                WriteJsonString(builder, (string)value);
                return;
            }
            builder.Append(Serializer.Serialize(value));
        }

        private static void WriteJsonString(StringBuilder builder, string value)
        {
            builder.Append('"');
            foreach (char c in value ?? String.Empty)
            {
                switch (c)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\f': builder.Append("\\f"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (c < 0x20)
                        {
                            builder.Append("\\u")
                                .Append(((int)c).ToString("x4",
                                    CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            builder.Append(c);
                        }
                        break;
                }
            }
            builder.Append('"');
        }

        private static void WriteIndent(StringBuilder builder, int depth)
        {
            for (int i = 0; i < depth; i++)
            {
                builder.Append("  ");
            }
        }

        private sealed class HookSpec
        {
            public readonly string Event;
            public readonly string Matcher;

            public HookSpec(string eventName, string matcher)
            {
                Event = eventName;
                Matcher = matcher;
            }
        }
    }

    public sealed class GrokHookStatusReducer
    {
        private readonly JavaScriptSerializer serializer;
        private DateTime workingVisibleUntilUtc;
        private DateTime thinkingVisibleUntilUtc;
        private string pendingWorkingAction;
        private bool permissionPrompt;
        private bool? wasActiveBeforeCompaction;

        public SessionSnapshot Snapshot { get; private set; }

        public GrokHookStatusReducer(string threadId)
        {
            serializer = new JavaScriptSerializer();
            Snapshot = new SessionSnapshot
            {
                ThreadId = String.IsNullOrEmpty(threadId) ? "grok" : threadId,
                ProjectName = "Grok",
                WorkingDirectory = String.Empty,
                State = HaloState.Idle,
                Action = "Ready",
                LastEventUtc = DateTime.UtcNow,
                Active = false,
                Agent = AgentKind.Grok,
                EvidenceSource = AgentEvidenceSource.GrokHook
            };
        }

        public void Consume(string jsonLine, DateTime nowUtc)
        {
            Dictionary<string, object> root = serializer.DeserializeObject(jsonLine)
                as Dictionary<string, object>;
            if (root == null)
            {
                return;
            }
            DateTime eventUtc = ParseDate(StringValue(root, "timestamp"));
            if (eventUtc == DateTime.MinValue)
            {
                eventUtc = nowUtc;
            }
            Snapshot.LastEventUtc = eventUtc;
            Snapshot.EvidenceSource = AgentEvidenceSource.GrokHook;
            UpdateIdentity(root);

            switch (StringValue(root, "event"))
            {
                case "SessionStart":
                    if (wasActiveBeforeCompaction.HasValue)
                    {
                        permissionPrompt = false;
                        workingVisibleUntilUtc = DateTime.MinValue;
                        thinkingVisibleUntilUtc = DateTime.MinValue;
                        pendingWorkingAction = null;
                        Snapshot.Active = true;
                        Snapshot.State = HaloState.Working;
                        Snapshot.Action = "Compressing context";
                        Snapshot.CompletedUtc = DateTime.MinValue;
                        break;
                    }
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    Snapshot.Active = false;
                    Snapshot.State = HaloState.Idle;
                    Snapshot.Action = "Ready";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
                case "UserPromptSubmit":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = eventUtc.AddSeconds(0.7);
                    pendingWorkingAction = null;
                    Snapshot.Active = true;
                    Snapshot.State = HaloState.Thinking;
                    Snapshot.Action = "Thinking";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
                case "PreToolUse":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    string action = GeneratedHaloSpec.FriendlyAction(
                        NormalizeToolName(StringValue(root, "toolName")));
                    Snapshot.Active = true;
                    if (Snapshot.State == HaloState.Thinking &&
                        eventUtc < thinkingVisibleUntilUtc)
                    {
                        pendingWorkingAction = action;
                        Snapshot.Action = "Thinking";
                    }
                    else
                    {
                        thinkingVisibleUntilUtc = DateTime.MinValue;
                        pendingWorkingAction = null;
                        Snapshot.State = HaloState.Working;
                        Snapshot.Action = action;
                    }
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
                case "PostToolUse":
                case "PostToolBatch":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    Snapshot.Active = true;
                    if (Snapshot.State == HaloState.Thinking &&
                        eventUtc < thinkingVisibleUntilUtc)
                    {
                        pendingWorkingAction = "Reviewing result";
                    }
                    else
                    {
                        thinkingVisibleUntilUtc = DateTime.MinValue;
                        pendingWorkingAction = null;
                        Snapshot.State = HaloState.Working;
                        Snapshot.Action = "Reviewing result";
                    }
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    workingVisibleUntilUtc = MaxUtc(eventUtc, thinkingVisibleUntilUtc)
                        .AddSeconds(0.65);
                    break;
                case "PostToolUseFailure":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    Snapshot.Active = true;
                    if (Snapshot.State == HaloState.Thinking &&
                        eventUtc < thinkingVisibleUntilUtc)
                    {
                        pendingWorkingAction = "Tool failed";
                    }
                    else
                    {
                        thinkingVisibleUntilUtc = DateTime.MinValue;
                        pendingWorkingAction = null;
                        Snapshot.State = HaloState.Working;
                        Snapshot.Action = "Tool failed";
                    }
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    workingVisibleUntilUtc = MaxUtc(eventUtc, thinkingVisibleUntilUtc)
                        .AddSeconds(0.65);
                    break;
                case "Notification":
                    ReduceNotification(root);
                    break;
                case "PermissionRequest":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = true;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    Snapshot.Active = true;
                    Snapshot.State = HaloState.Attention;
                    Snapshot.Action = "Awaiting permission";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
                case "PermissionDenied":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    Snapshot.Active = true;
                    Snapshot.State = HaloState.Attention;
                    Snapshot.Action = "Permission denied";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
                case "Stop":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    Snapshot.Active = false;
                    Snapshot.State = HaloState.Done;
                    Snapshot.Action = "Complete";
                    Snapshot.CompletedUtc = eventUtc;
                    break;
                case "StopFailure":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    Snapshot.Active = false;
                    Snapshot.State = HaloState.Error;
                    Snapshot.Action = "Grok stopped with an error";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
                case "PreCompact":
                    if (!wasActiveBeforeCompaction.HasValue)
                    {
                        wasActiveBeforeCompaction = Snapshot.Active;
                    }
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    Snapshot.Active = true;
                    Snapshot.State = HaloState.Working;
                    Snapshot.Action = "Compressing context";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
                case "PostCompact":
                    bool? shouldResumeActiveTurn = wasActiveBeforeCompaction;
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    if (shouldResumeActiveTurn == true)
                    {
                        Snapshot.Active = true;
                        Snapshot.State = HaloState.Thinking;
                        Snapshot.Action = "Thinking";
                        Snapshot.CompletedUtc = DateTime.MinValue;
                    }
                    else if (shouldResumeActiveTurn == false)
                    {
                        Snapshot.Active = false;
                        Snapshot.State = HaloState.Done;
                        Snapshot.Action = "Context compacted";
                        Snapshot.CompletedUtc = eventUtc;
                    }
                    else
                    {
                        Snapshot.Active = false;
                        Snapshot.State = HaloState.Idle;
                        Snapshot.Action = "Ready";
                        Snapshot.CompletedUtc = DateTime.MinValue;
                    }
                    break;
                case "SessionEnd":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    if (Snapshot.Active)
                    {
                        Snapshot.Active = false;
                        Snapshot.State = HaloState.Idle;
                        Snapshot.Action = "Ready";
                    }
                    break;
            }
        }

        public void ApplyWorkingVisibility(DateTime nowUtc)
        {
            if (!Snapshot.Active)
            {
                return;
            }
            if (pendingWorkingAction != null && nowUtc >= thinkingVisibleUntilUtc)
            {
                string action = pendingWorkingAction;
                pendingWorkingAction = null;
                thinkingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.State = HaloState.Working;
                Snapshot.Action = action;
                return;
            }
            if (Snapshot.State != HaloState.Working)
            {
                return;
            }
            if (workingVisibleUntilUtc != DateTime.MinValue &&
                nowUtc >= workingVisibleUntilUtc)
            {
                workingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.State = HaloState.Thinking;
                Snapshot.Action = "Thinking";
                return;
            }
            // Safety net: stuck PreToolUse without PostToolUse. Permission exempt.
            if (workingVisibleUntilUtc == DateTime.MinValue && !permissionPrompt &&
                (nowUtc - Snapshot.LastEventUtc).TotalSeconds > 180)
            {
                if (wasActiveBeforeCompaction.HasValue)
                {
                    bool shouldResumeActiveTurn = wasActiveBeforeCompaction.Value;
                    wasActiveBeforeCompaction = null;
                    Snapshot.Active = shouldResumeActiveTurn;
                    Snapshot.State = shouldResumeActiveTurn
                        ? HaloState.Thinking : HaloState.Idle;
                    Snapshot.Action = shouldResumeActiveTurn ? "Thinking" : "Ready";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    return;
                }
                Snapshot.State = HaloState.Thinking;
                Snapshot.Action = "Thinking";
            }
        }

        private void ReduceNotification(Dictionary<string, object> root)
        {
            switch (StringValue(root, "notificationType"))
            {
                case "permission_prompt":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = true;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    Snapshot.Active = true;
                    Snapshot.State = HaloState.Attention;
                    Snapshot.Action = "Awaiting permission";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
                case "idle_prompt":
                    wasActiveBeforeCompaction = null;
                    permissionPrompt = false;
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    Snapshot.Active = false;
                    Snapshot.State = HaloState.Idle;
                    Snapshot.Action = "Ready";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
            }
        }

        private void UpdateIdentity(Dictionary<string, object> root)
        {
            string sessionId = StringValue(root, "sessionId");
            if (!String.IsNullOrEmpty(sessionId))
            {
                Snapshot.ThreadId = sessionId;
            }
            string cwd = StringValue(root, "cwd");
            if (!String.IsNullOrEmpty(cwd))
            {
                Snapshot.WorkingDirectory = cwd;
                string project = Path.GetFileName(cwd.TrimEnd(Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar));
                Snapshot.ProjectName = String.IsNullOrEmpty(project)
                    ? "Grok" : project;
            }
        }

        /// <summary>
        /// Normalize Grok Build tool names to shared friendly-action keys.
        /// run_terminal_command / bash → shell_command → "Running command".
        /// </summary>
        private static string NormalizeToolName(string name)
        {
            if (String.Equals(name, "bash", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(name, "run_terminal_command",
                    StringComparison.OrdinalIgnoreCase))
            {
                return "shell_command";
            }
            return name;
        }

        private static DateTime MaxUtc(DateTime a, DateTime b)
        {
            if (a == DateTime.MinValue)
            {
                return b == DateTime.MinValue ? a : b;
            }
            if (b == DateTime.MinValue)
            {
                return a;
            }
            return a.Ticks >= b.Ticks ? a : b;
        }

        private static DateTime ParseDate(string value)
        {
            DateTime parsed;
            if (DateTime.TryParse(value, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out parsed))
            {
                return parsed.ToUniversalTime();
            }
            return DateTime.MinValue;
        }

        private static string StringValue(Dictionary<string, object> dictionary,
            string key)
        {
            object value;
            return dictionary != null && dictionary.TryGetValue(key, out value) &&
                value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture)
                : String.Empty;
        }
    }

    public sealed class GrokHookStatusMonitor
    {
        private readonly string statusPath;
        private readonly Dictionary<string, GrokHookStatusReducer> reducers;
        private long offset;
        private string pending;
        private DateTime lastModifiedUtc;

        public GrokHookStatusMonitor()
            : this(Path.Combine(ClaudeHookStatusWriter.AgentHaloDataDirectory(),
                "grok-build-status.jsonl"))
        {
        }

        public GrokHookStatusMonitor(string path)
        {
            statusPath = path;
            reducers = new Dictionary<string, GrokHookStatusReducer>(
                StringComparer.OrdinalIgnoreCase);
            pending = String.Empty;
        }

        public bool Refresh()
        {
            DateTime now = DateTime.UtcNow;
            bool changed = false;
            FileInfo info = new FileInfo(statusPath);
            if (!info.Exists)
            {
                ApplyAndPrune(now);
                return false;
            }
            if (info.Length < offset ||
                (lastModifiedUtc != DateTime.MinValue &&
                 info.LastWriteTimeUtc != lastModifiedUtc && info.Length <= offset))
            {
                offset = 0;
                pending = String.Empty;
                reducers.Clear();
                changed = true;
            }
            if (info.Length > offset)
            {
                using (FileStream stream = new FileStream(statusPath, FileMode.Open,
                    FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    stream.Seek(offset, SeekOrigin.Begin);
                    byte[] bytes = new byte[(int)(stream.Length - stream.Position)];
                    int read = stream.Read(bytes, 0, bytes.Length);
                    offset = stream.Length;
                    lastModifiedUtc = info.LastWriteTimeUtc;
                    string text = pending + Encoding.UTF8.GetString(bytes, 0, read);
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
                        string line = lines[i].TrimEnd('\r').TrimStart('\ufeff');
                        if (String.IsNullOrWhiteSpace(line))
                        {
                            continue;
                        }
                        string sessionId = SessionIdFromLine(line);
                        GrokHookStatusReducer reducer;
                        if (!reducers.TryGetValue(sessionId, out reducer))
                        {
                            reducer = new GrokHookStatusReducer(sessionId);
                            reducers[sessionId] = reducer;
                        }
                        reducer.Consume(line, now);
                        changed = true;
                    }
                }
            }
            return ApplyAndPrune(now) || changed;
        }

        public List<SessionSnapshot> Snapshots()
        {
            return reducers.Values.Select(delegate(GrokHookStatusReducer reducer)
            {
                return new SessionSnapshot
                {
                    ThreadId = reducer.Snapshot.ThreadId,
                    ProjectName = reducer.Snapshot.ProjectName,
                    WorkingDirectory = reducer.Snapshot.WorkingDirectory,
                    State = reducer.Snapshot.State,
                    Action = reducer.Snapshot.Action,
                    LastEventUtc = reducer.Snapshot.LastEventUtc,
                    CompletedUtc = reducer.Snapshot.CompletedUtc,
                    Active = reducer.Snapshot.Active,
                    Agent = AgentKind.Grok,
                    EvidenceSource = AgentEvidenceSource.GrokHook
                };
            })
            .OrderByDescending(delegate(SessionSnapshot snapshot)
            {
                return snapshot.LastEventUtc;
            })
            .ToList();
        }

        private bool ApplyAndPrune(DateTime now)
        {
            bool changed = false;
            foreach (GrokHookStatusReducer reducer in reducers.Values)
            {
                HaloState previousState = reducer.Snapshot.State;
                string previousAction = reducer.Snapshot.Action;
                reducer.ApplyWorkingVisibility(now);
                if (previousState != reducer.Snapshot.State ||
                    !String.Equals(previousAction, reducer.Snapshot.Action,
                        StringComparison.Ordinal))
                {
                    changed = true;
                }
            }
            DateTime activeCutoff = now.AddMinutes(-10);
            DateTime inactiveCutoff = now.AddMinutes(-5);
            List<string> stale = reducers.Where(delegate(
                KeyValuePair<string, GrokHookStatusReducer> pair)
            {
                DateTime cutoff = pair.Value.Snapshot.Active
                    ? activeCutoff : inactiveCutoff;
                return pair.Value.Snapshot.LastEventUtc < cutoff;
            }).Select(delegate(KeyValuePair<string, GrokHookStatusReducer> pair)
            {
                return pair.Key;
            }).ToList();
            foreach (string key in stale)
            {
                reducers.Remove(key);
                changed = true;
            }
            return changed;
        }

        private static string SessionIdFromLine(string line)
        {
            try
            {
                Dictionary<string, object> root =
                    new JavaScriptSerializer().DeserializeObject(line)
                    as Dictionary<string, object>;
                object value;
                if (root != null && root.TryGetValue("sessionId", out value) &&
                    value != null)
                {
                    string text = Convert.ToString(value, CultureInfo.InvariantCulture);
                    if (!String.IsNullOrEmpty(text))
                    {
                        return text;
                    }
                }
            }
            catch
            {
            }
            return "grok";
        }
    }

    /// <summary>
    /// Parses ~/.grok/active_sessions.json. Presence only — never spawn subprocess
    /// (no Process.Start / tasklist / wmic). Optional PID liveness via OpenProcess.
    /// </summary>
    public static class GrokActiveSessionsReader
    {
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint StillActive = 259;

        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();

        public static bool HasLiveSession(string home)
        {
            try
            {
                List<ActiveSessionRef> sessions = Read(home);
                if (sessions.Count == 0)
                {
                    return false;
                }
                List<int> withPid = sessions
                    .Where(delegate(ActiveSessionRef s) { return s.ProcessId > 0; })
                    .Select(delegate(ActiveSessionRef s) { return s.ProcessId; })
                    .ToList();
                // No pids present → any entry counts as present (older file shapes).
                if (withPid.Count == 0)
                {
                    return true;
                }
                foreach (int pid in withPid)
                {
                    if (IsProcessAlive(pid))
                    {
                        return true;
                    }
                }
                return false;
            }
            catch
            {
                return false;
            }
        }

        private static List<ActiveSessionRef> Read(string home)
        {
            List<ActiveSessionRef> result = new List<ActiveSessionRef>();
            if (String.IsNullOrEmpty(home))
            {
                return result;
            }
            string path = Path.Combine(home, ".grok", "active_sessions.json");
            if (!File.Exists(path))
            {
                return result;
            }
            string raw = File.ReadAllText(path, Encoding.UTF8);
            if (String.IsNullOrWhiteSpace(raw))
            {
                return result;
            }
            object parsed = Serializer.DeserializeObject(raw);
            object[] array = parsed as object[];
            if (array != null)
            {
                foreach (object item in array)
                {
                    ActiveSessionRef entry = ParseEntry(item as Dictionary<string, object>);
                    if (entry != null)
                    {
                        result.Add(entry);
                    }
                }
                return result;
            }
            Dictionary<string, object> root = parsed as Dictionary<string, object>;
            if (root != null)
            {
                foreach (string key in new string[] { "sessions", "active_sessions" })
                {
                    object value;
                    if (!root.TryGetValue(key, out value))
                    {
                        continue;
                    }
                    object[] nested = value as object[];
                    if (nested == null)
                    {
                        continue;
                    }
                    foreach (object item in nested)
                    {
                        ActiveSessionRef entry =
                            ParseEntry(item as Dictionary<string, object>);
                        if (entry != null)
                        {
                            result.Add(entry);
                        }
                    }
                    if (result.Count > 0)
                    {
                        return result;
                    }
                }
            }
            return result;
        }

        private static ActiveSessionRef ParseEntry(Dictionary<string, object> entry)
        {
            if (entry == null)
            {
                return null;
            }
            string sessionId = FirstString(entry, "session_id", "sessionId", "id");
            if (String.IsNullOrEmpty(sessionId))
            {
                return null;
            }
            int pid = 0;
            object pidValue;
            if (entry.TryGetValue("pid", out pidValue) && pidValue != null)
            {
                int parsed;
                if (Int32.TryParse(Convert.ToString(pidValue,
                    CultureInfo.InvariantCulture), NumberStyles.Integer,
                    CultureInfo.InvariantCulture, out parsed) && parsed > 0)
                {
                    pid = parsed;
                }
            }
            return new ActiveSessionRef
            {
                SessionId = sessionId,
                ProcessId = pid
            };
        }

        private static string FirstString(Dictionary<string, object> entry,
            params string[] keys)
        {
            foreach (string key in keys)
            {
                object value;
                if (entry.TryGetValue(key, out value) && value != null)
                {
                    string text = Convert.ToString(value, CultureInfo.InvariantCulture);
                    if (!String.IsNullOrEmpty(text))
                    {
                        return text;
                    }
                }
            }
            return String.Empty;
        }

        /// <summary>
        /// PID liveness via OpenProcess + GetExitCodeProcess. Never Process.Start.
        /// </summary>
        private static bool IsProcessAlive(int pid)
        {
            if (pid <= 0)
            {
                return false;
            }
            IntPtr handle = OpenProcess(ProcessQueryLimitedInformation, false, pid);
            if (handle == IntPtr.Zero)
            {
                return false;
            }
            try
            {
                uint exitCode;
                if (!GetExitCodeProcess(handle, out exitCode))
                {
                    return false;
                }
                return exitCode == StillActive;
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess,
            bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(IntPtr hProcess,
            out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr hObject);

        private sealed class ActiveSessionRef
        {
            public string SessionId;
            public int ProcessId;
        }
    }
}
