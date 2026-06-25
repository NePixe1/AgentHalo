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
public static class ClaudeHookStatusWriter
    {
        private const long RotateTriggerBytes = 3 * 1024 * 1024;
        private const long RotateKeepBytes = 2 * 1024 * 1024;
        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();

        public static int WriteFromStandardInput(string eventName)
        {
            try
            {
                string body = Console.In.ReadToEnd();
                Dictionary<string, object> payload = null;
                if (!String.IsNullOrWhiteSpace(body))
                {
                    payload = Serializer.DeserializeObject(body) as Dictionary<string, object>;
                }
                if (payload == null)
                {
                    payload = new Dictionary<string, object>();
                }

                string resolvedEvent = FirstString(eventName, Value(payload, "hook_event_name"),
                    Value(payload, "event"), Value(payload, "eventName"));
                if (String.IsNullOrWhiteSpace(resolvedEvent))
                {
                    return 0;
                }

                Dictionary<string, object> record = new Dictionary<string, object>();
                record["timestamp"] = FirstString(Value(payload, "timestamp"),
                    DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
                record["event"] = resolvedEvent;
                record["sessionId"] = FirstString(Value(payload, "session_id"),
                    Value(payload, "sessionId"), Value(payload, "conversation_id"),
                    "claude-code");
                record["cwd"] = FirstString(Value(payload, "cwd"),
                    Nested(payload, "workspace", "current_dir"),
                    Nested(payload, "workspace", "cwd"),
                    Environment.CurrentDirectory);
                string toolName = FirstString(Value(payload, "tool_name"),
                    Value(payload, "toolName"), Nested(payload, "tool", "name"));
                string notificationType = resolvedEvent == "Notification"
                    ? FirstString(Value(payload, "type"),
                        Value(payload, "notification_type"),
                        Value(payload, "notificationType"))
                    : String.Empty;
                string errorText = resolvedEvent == "StopFailure" ||
                    resolvedEvent == "PostToolUseFailure"
                    ? FirstString(Value(payload, "error"), Value(payload, "error_text"),
                        Value(payload, "errorText"), Value(payload, "tool_stderr"))
                    : String.Empty;
                string model = FirstString(Value(payload, "model"),
                    Nested(payload, "message", "model"));
                record["toolName"] = String.IsNullOrEmpty(toolName) ? null : toolName;
                record["notificationType"] = String.IsNullOrEmpty(notificationType)
                    ? null : notificationType;
                record["errorText"] = String.IsNullOrEmpty(errorText) ? null : errorText;
                record["model"] = String.IsNullOrEmpty(model) ? null : model;
                record["source"] = "claude-hook";

                string root = AgentHaloDataDirectory();
                Directory.CreateDirectory(root);
                string path = Path.Combine(root, "claude-code-status.jsonl");
                string line = Serializer.Serialize(record) + Environment.NewLine;

                using (Mutex mutex = new Mutex(false,
                    "Local\\AgentHalo-ClaudeCodeStatusLog-7A0CE36F"))
                {
                    bool locked = false;
                    try
                    {
                        locked = mutex.WaitOne(TimeSpan.FromSeconds(2));
                        if (!locked)
                        {
                            return 0;
                        }
                        RotateIfNeeded(path);
                        using (FileStream stream = new FileStream(path, FileMode.Append,
                            FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                        {
                            byte[] bytes = new UTF8Encoding(false).GetBytes(line);
                            stream.Write(bytes, 0, bytes.Length);
                            stream.Flush(true);
                        }
                    }
                    finally
                    {
                        if (locked)
                        {
                            mutex.ReleaseMutex();
                        }
                    }
                }
            }
            catch
            {
                // Claude hooks must never block or break the user's Claude Code turn.
            }
            return 0;
        }

        public static string AgentHaloDataDirectory()
        {
            return Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile), ".agent-halo");
        }

        private static void RotateIfNeeded(string path)
        {
            if (!File.Exists(path))
            {
                return;
            }
            FileInfo info = new FileInfo(path);
            if (info.Length < RotateTriggerBytes)
            {
                return;
            }

            byte[] tail;
            using (FileStream stream = new FileStream(path, FileMode.Open,
                FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                long start = Math.Max(0, stream.Length - RotateKeepBytes);
                stream.Seek(start, SeekOrigin.Begin);
                tail = new byte[stream.Length - stream.Position];
                int read = 0;
                while (read < tail.Length)
                {
                    int count = stream.Read(tail, read, tail.Length - read);
                    if (count <= 0)
                    {
                        break;
                    }
                    read += count;
                }
                if (read < tail.Length)
                {
                    Array.Resize(ref tail, read);
                }
            }

            int firstNewline = 0;
            if (tail.Length == RotateKeepBytes)
            {
                while (firstNewline < tail.Length && tail[firstNewline] != (byte)'\n')
                {
                    firstNewline++;
                }
                if (firstNewline < tail.Length)
                {
                    firstNewline++;
                }
            }
            using (FileStream stream = new FileStream(path, FileMode.Create,
                FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
            {
                stream.Write(tail, firstNewline, tail.Length - firstNewline);
            }
        }

        private static string FirstString(params object[] values)
        {
            foreach (object value in values)
            {
                if (value == null)
                {
                    continue;
                }
                string text = Convert.ToString(value, CultureInfo.InvariantCulture);
                if (!String.IsNullOrEmpty(text))
                {
                    return text;
                }
            }
            return String.Empty;
        }

        private static object Value(Dictionary<string, object> dictionary, string key)
        {
            object value;
            return dictionary != null && dictionary.TryGetValue(key, out value)
                ? value : null;
        }

        private static object Nested(Dictionary<string, object> dictionary,
            string first, string second)
        {
            Dictionary<string, object> child = Value(dictionary, first)
                as Dictionary<string, object>;
            return Value(child, second);
        }
    }

public static class ClaudeHookConfigurator
    {
        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();
        private static readonly HookSpec[] HookSpecs =
        {
            new HookSpec("SessionStart", null),
            new HookSpec("UserPromptSubmit", null),
            new HookSpec("PreToolUse", ".*"),
            new HookSpec("PostToolUse", ".*"),
            new HookSpec("PostToolUseFailure", ".*"),
            new HookSpec("PostToolBatch", null),
            new HookSpec("Notification", null),
            new HookSpec("PermissionRequest", null),
            new HookSpec("PermissionDenied", null),
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
                SettingsStorage.Log("Claude hook configure failed: " + ex.Message);
            }
        }

        public static void Configure(string home, string executablePath)
        {
            RemoveLegacyHookHelper(home);
            string claudeDir = Path.Combine(home, ".claude");
            string settingsPath = Path.Combine(claudeDir, "settings.json");
            Dictionary<string, object> config = ReadSettings(settingsPath);
            Dictionary<string, object> hooks = GetDictionary(config, "hooks");
            if (hooks == null)
            {
                hooks = new Dictionary<string, object>();
            }

            bool changed = false;
            foreach (HookSpec spec in HookSpecs)
            {
                object existing;
                object[] entries = hooks.TryGetValue(spec.Event, out existing)
                    ? existing as object[] : null;
                List<object> list = entries == null
                    ? new List<object>() : entries.ToList();
                string command = Quote(executablePath) + " --claude-hook " + spec.Event;
                bool already = false;
                for (int i = list.Count - 1; i >= 0; i--)
                {
                    Dictionary<string, object> entry =
                        list[i] as Dictionary<string, object>;
                    if (EntryHasAgentHaloHook(entry))
                    {
                        if (EntryMatches(entry, spec, command))
                        {
                            already = true;
                        }
                        else
                        {
                            list.RemoveAt(i);
                            changed = true;
                        }
                    }
                }
                if (!already)
                {
                    list.Add(CreateHookEntry(spec, command));
                    changed = true;
                }
                hooks[spec.Event] = list.ToArray();
            }

            if (!changed && !SettingsJsonNeedsPrettyPrint(settingsPath))
            {
                return;
            }
            config["hooks"] = hooks;
            Directory.CreateDirectory(claudeDir);
            File.WriteAllText(settingsPath,
                PrettyPrintJson(Serializer.Serialize(config)),
                new UTF8Encoding(false));
        }

        // Detects a settings.json that is valid JSON but written as a single
        // unindented line (e.g. produced by older builds, or a hand-rolled
        // compact variant the user swapped in). We re-emit it pretty so users
        // never have to manually format after swapping configs. Already-pretty
        // files return false so we don't touch the timestamp every launch.
        private static bool SettingsJsonNeedsPrettyPrint(string settingsPath)
        {
            string raw;
            try
            {
                raw = File.ReadAllText(settingsPath, Encoding.UTF8);
            }
            catch
            {
                return false;
            }
            if (String.IsNullOrWhiteSpace(raw))
            {
                return false;
            }
            // A pretty-printed JSON document always contains newlines; a compact
            // one does not. Only offer to pretty-print what we can actually parse,
            // so we never corrupt a file we don't understand.
            if (raw.IndexOf('\n') >= 0 || raw.IndexOf('\r') >= 0)
            {
                return false;
            }
            try
            {
                Serializer.DeserializeObject(raw);
            }
            catch
            {
                return false;
            }
            return true;
        }

        // JavaScriptSerializer has no indented output, so we re-emit its compact
        // JSON with two-space indentation. Keeps ~/.claude/settings.json readable
        // for users who maintain and swap several hand-edited variants.
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
            Dictionary<string, object> dict =
                value as Dictionary<string, object>;
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
            // Numbers and anything else: defer to the serializer so int/long/decimal
            // and exotic types are formatted correctly without re-implementing them.
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

        private static void RemoveLegacyHookHelper(string home)
        {
            try
            {
                string legacy = Path.Combine(home, ".agent-halo", "AgentHaloHook.exe");
                if (File.Exists(legacy))
                {
                    File.Delete(legacy);
                }
            }
            catch
            {
            }
        }

        private static Dictionary<string, object> ReadSettings(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    Dictionary<string, object> parsed = Serializer.DeserializeObject(
                        File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
                    if (parsed != null)
                    {
                        return parsed;
                    }
                }
            }
            catch
            {
            }
            return new Dictionary<string, object>();
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

        private static bool EntryHasAgentHaloHook(Dictionary<string, object> entry)
        {
            foreach (Dictionary<string, object> hook in EntryHooks(entry))
            {
                string command = StringValue(hook, "command");
                if (command.IndexOf("--claude-hook", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    command.IndexOf("AgentHaloHook.exe",
                        StringComparison.OrdinalIgnoreCase) >= 0 ||
                    command.IndexOf("claude-code-status-hook",
                        StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }
            }
            return false;
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
                return String.Equals(StringValue(hook, "command"), command,
                    StringComparison.Ordinal);
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
            return "\"" + path.Replace("\"", "\\\"") + "\"";
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

public sealed class ClaudeHookStatusReducer
    {
        private readonly JavaScriptSerializer serializer;
        private DateTime workingVisibleUntilUtc;
        private DateTime thinkingVisibleUntilUtc;
        private string pendingWorkingAction;
        private bool permissionPrompt;
        private bool? wasActiveBeforeCompaction;

        public SessionSnapshot Snapshot { get; private set; }

        public ClaudeHookStatusReducer(string threadId)
        {
            serializer = new JavaScriptSerializer();
            Snapshot = new SessionSnapshot
            {
                ThreadId = String.IsNullOrEmpty(threadId) ? "claude-code" : threadId,
                ProjectName = "Claude Code",
                WorkingDirectory = String.Empty,
                State = HaloState.Idle,
                Action = "Ready",
                LastEventUtc = DateTime.UtcNow,
                Active = false,
                Agent = AgentKind.ClaudeCode
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
                    workingVisibleUntilUtc = Math.Max(eventUtc.Ticks,
                        thinkingVisibleUntilUtc.Ticks) == 0
                        ? eventUtc.AddSeconds(0.65)
                        : new DateTime(Math.Max(eventUtc.Ticks,
                            thinkingVisibleUntilUtc.Ticks), DateTimeKind.Utc)
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
                    workingVisibleUntilUtc = Math.Max(eventUtc.Ticks,
                        thinkingVisibleUntilUtc.Ticks) == 0
                        ? eventUtc.AddSeconds(0.65)
                        : new DateTime(Math.Max(eventUtc.Ticks,
                            thinkingVisibleUntilUtc.Ticks), DateTimeKind.Utc)
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
                    Snapshot.Action = "Claude Code stopped with an error";
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
                    ? "Claude Code" : project;
            }
        }

        private static string NormalizeToolName(string name)
        {
            return String.Equals(name, "bash", StringComparison.OrdinalIgnoreCase)
                ? "shell_command" : name;
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

public sealed class ClaudeHookStatusMonitor
    {
        private readonly string statusPath;
        private readonly Dictionary<string, ClaudeHookStatusReducer> reducers;
        private long offset;
        private string pending;
        private DateTime lastModifiedUtc;

        public ClaudeHookStatusMonitor()
            : this(Path.Combine(ClaudeHookStatusWriter.AgentHaloDataDirectory(),
                "claude-code-status.jsonl"))
        {
        }

        public ClaudeHookStatusMonitor(string path)
        {
            statusPath = path;
            reducers = new Dictionary<string, ClaudeHookStatusReducer>(
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
                        ClaudeHookStatusReducer reducer;
                        if (!reducers.TryGetValue(sessionId, out reducer))
                        {
                            reducer = new ClaudeHookStatusReducer(sessionId);
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
            return reducers.Values.Select(delegate(ClaudeHookStatusReducer reducer)
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
                    Agent = AgentKind.ClaudeCode
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
            foreach (ClaudeHookStatusReducer reducer in reducers.Values)
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
                KeyValuePair<string, ClaudeHookStatusReducer> pair)
            {
                DateTime cutoff = pair.Value.Snapshot.Active
                    ? activeCutoff : inactiveCutoff;
                return pair.Value.Snapshot.LastEventUtc < cutoff;
            }).Select(delegate(KeyValuePair<string, ClaudeHookStatusReducer> pair)
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
            return "claude-code";
        }
    }

public sealed class ClaudeTranscriptSessionReducer
    {
        private readonly JavaScriptSerializer serializer;
        private DateTime workingVisibleUntilUtc;
        private int inFlightTools;
        private bool liveTracking;

        public SessionSnapshot Snapshot { get; private set; }

        public ClaudeTranscriptSessionReducer(string filePath)
            : this(filePath, DateTime.UtcNow, true)
        {
        }

        public ClaudeTranscriptSessionReducer(string filePath, DateTime nowUtc,
            bool live)
        {
            serializer = new JavaScriptSerializer();
            liveTracking = live;
            Snapshot = new SessionSnapshot
            {
                ThreadId = ThreadIdFromPath(filePath),
                ProjectName = "Claude Code",
                WorkingDirectory = String.Empty,
                State = HaloState.Idle,
                Action = "Ready",
                LastEventUtc = nowUtc,
                CompletedUtc = DateTime.MinValue,
                Active = false,
                Agent = AgentKind.ClaudeCode
            };
        }

        public void SetLiveTracking(bool value)
        {
            liveTracking = value;
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
            UpdateIdentity(root);

            switch (StringValue(root, "type"))
            {
                case "user":
                    ReduceUser(root, nowUtc);
                    break;
                case "assistant":
                    ReduceAssistant(root, nowUtc);
                    break;
                case "system":
                    ReduceSystem(root, eventUtc);
                    break;
            }
        }

        public void ApplyWorkingVisibility(DateTime nowUtc)
        {
            if (!Snapshot.Active || Snapshot.State != HaloState.Working)
            {
                return;
            }
            if (inFlightTools == 0 && workingVisibleUntilUtc != DateTime.MinValue &&
                nowUtc >= workingVisibleUntilUtc)
            {
                workingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.State = HaloState.Thinking;
                Snapshot.Action = "Thinking";
                return;
            }
            if (inFlightTools == 0 && workingVisibleUntilUtc == DateTime.MinValue &&
                (nowUtc - Snapshot.LastEventUtc).TotalSeconds > 180)
            {
                Snapshot.State = HaloState.Thinking;
                Snapshot.Action = "Thinking";
            }
        }

        private void ReduceUser(Dictionary<string, object> root, DateTime nowUtc)
        {
            if (IsLocalCommandUserRecord(root))
            {
                return;
            }
            if (ContainsContentType(root, "tool_result"))
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
                        SetWorkingVisibility(0.65, nowUtc);
                        Snapshot.State = HaloState.Working;
                        Snapshot.Action = "Reviewing result";
                    }
                    else
                    {
                        Snapshot.State = HaloState.Thinking;
                        Snapshot.Action = "Thinking";
                    }
                }
                return;
            }

            inFlightTools = 0;
            workingVisibleUntilUtc = DateTime.MinValue;
            Snapshot.Active = true;
            Snapshot.State = HaloState.Thinking;
            Snapshot.Action = "Thinking";
            Snapshot.CompletedUtc = DateTime.MinValue;
        }

        private void ReduceAssistant(Dictionary<string, object> root, DateTime nowUtc)
        {
            string toolName = FirstToolName(root);
            if (String.Equals(toolName, "AskUserQuestion",
                    StringComparison.OrdinalIgnoreCase))
            {
                inFlightTools = 0;
                workingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.Active = true;
                Snapshot.State = HaloState.Attention;
                Snapshot.Action = "Awaiting permission";
                Snapshot.CompletedUtc = DateTime.MinValue;
                return;
            }
            if (!String.IsNullOrEmpty(toolName))
            {
                inFlightTools += Math.Max(1, ToolUseCount(root));
                ExtendWorkingVisibility(1.0, nowUtc);
                Snapshot.Active = true;
                Snapshot.State = HaloState.Working;
                Snapshot.Action = GeneratedHaloSpec.FriendlyAction(
                    NormalizeToolName(toolName));
                Snapshot.CompletedUtc = DateTime.MinValue;
                return;
            }
            if (ContainsContentType(root, "thinking") ||
                ContainsContentType(root, "text"))
            {
                inFlightTools = 0;
                workingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.Active = true;
                Snapshot.State = HaloState.Thinking;
                Snapshot.Action = "Thinking";
                Snapshot.CompletedUtc = DateTime.MinValue;
                return;
            }
            ApplyActiveThinkingOrWorking(nowUtc);
        }

        private void ReduceSystem(Dictionary<string, object> root, DateTime eventUtc)
        {
            string subtype = StringValue(root, "subtype");
            if (subtype == "turn_duration" || subtype == "stop_hook_summary")
            {
                inFlightTools = 0;
                workingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.Active = false;
                Snapshot.State = HaloState.Done;
                Snapshot.Action = "Complete";
                Snapshot.CompletedUtc = eventUtc;
            }
            else if (subtype == "api_error")
            {
                inFlightTools = 0;
                workingVisibleUntilUtc = DateTime.MinValue;
                Snapshot.Active = false;
                Snapshot.State = HaloState.Error;
                Snapshot.Action = "Service unavailable";
                Snapshot.CompletedUtc = DateTime.MinValue;
            }
        }

        private void ApplyActiveThinkingOrWorking(DateTime nowUtc)
        {
            if (!Snapshot.Active)
            {
                return;
            }
            if (inFlightTools > 0)
            {
                Snapshot.State = HaloState.Working;
            }
            else if (workingVisibleUntilUtc != DateTime.MinValue &&
                nowUtc < workingVisibleUntilUtc)
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

        private void ExtendWorkingVisibility(double seconds, DateTime nowUtc)
        {
            if (!liveTracking)
            {
                return;
            }
            DateTime candidate = nowUtc.AddSeconds(seconds);
            if (workingVisibleUntilUtc == DateTime.MinValue ||
                candidate > workingVisibleUntilUtc)
            {
                workingVisibleUntilUtc = candidate;
            }
        }

        private void SetWorkingVisibility(double seconds, DateTime nowUtc)
        {
            if (!liveTracking)
            {
                return;
            }
            workingVisibleUntilUtc = nowUtc.AddSeconds(seconds);
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
                    ? "Claude Code" : project;
            }
        }

        private bool IsLocalCommandUserRecord(Dictionary<string, object> root)
        {
            string content = MessageContentString(root);
            return content.IndexOf("<local-command-",
                       StringComparison.OrdinalIgnoreCase) >= 0 ||
                   content.IndexOf("<command-name>",
                       StringComparison.OrdinalIgnoreCase) >= 0 ||
                   content.IndexOf("<command-message>",
                       StringComparison.OrdinalIgnoreCase) >= 0 ||
                   content.IndexOf("<command-args>",
                       StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private string MessageContentString(Dictionary<string, object> root)
        {
            Dictionary<string, object> message = Child(root, "message");
            object content = Value(message, "content");
            if (content == null)
            {
                return String.Empty;
            }
            if (content is string)
            {
                return (string)content;
            }
            try
            {
                return serializer.Serialize(content);
            }
            catch
            {
                return Convert.ToString(content, CultureInfo.InvariantCulture);
            }
        }

        private static bool ContainsContentType(Dictionary<string, object> root,
            string type)
        {
            foreach (Dictionary<string, object> item in ContentItems(root))
            {
                if (String.Equals(StringValue(item, "type"), type,
                        StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            return false;
        }

        private static string FirstToolName(Dictionary<string, object> root)
        {
            foreach (Dictionary<string, object> item in ContentItems(root))
            {
                if (String.Equals(StringValue(item, "type"), "tool_use",
                        StringComparison.OrdinalIgnoreCase))
                {
                    return StringValue(item, "name");
                }
            }
            return String.Empty;
        }

        private static int ToolUseCount(Dictionary<string, object> root)
        {
            int count = 0;
            foreach (Dictionary<string, object> item in ContentItems(root))
            {
                if (String.Equals(StringValue(item, "type"), "tool_use",
                        StringComparison.OrdinalIgnoreCase))
                {
                    count++;
                }
            }
            return count;
        }

        private static IEnumerable<Dictionary<string, object>> ContentItems(
            Dictionary<string, object> root)
        {
            Dictionary<string, object> message = Child(root, "message");
            object value = Value(message, "content");
            object[] items = value as object[];
            if (items == null)
            {
                yield break;
            }
            foreach (object item in items)
            {
                Dictionary<string, object> dictionary =
                    item as Dictionary<string, object>;
                if (dictionary != null)
                {
                    yield return dictionary;
                }
            }
        }

        private static string NormalizeToolName(string name)
        {
            return String.Equals(name, "bash", StringComparison.OrdinalIgnoreCase)
                ? "shell_command" : name;
        }

        private static Dictionary<string, object> Child(
            Dictionary<string, object> dictionary, string key)
        {
            return Value(dictionary, key) as Dictionary<string, object>;
        }

        private static object Value(Dictionary<string, object> dictionary, string key)
        {
            object value;
            return dictionary != null && dictionary.TryGetValue(key, out value)
                ? value : null;
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

        private static string ThreadIdFromPath(string path)
        {
            string name = Path.GetFileNameWithoutExtension(path);
            Guid parsed;
            if (Guid.TryParse(name, out parsed))
            {
                return name;
            }
            if (!String.IsNullOrEmpty(name) && name.Length >= 36)
            {
                string suffix = name.Substring(name.Length - 36);
                if (Guid.TryParse(suffix, out parsed))
                {
                    return suffix;
                }
            }
            return String.IsNullOrEmpty(name) ? "claude-code" : name;
        }
    }

public sealed class ClaudeTranscriptSessionMonitor
    {
        private const int MaxRecentFiles = 16;
        private const int InitialTailBytes = 393216;
        private readonly string projectsRoot;
        private readonly Dictionary<string, ClaudeTranscriptSessionReducer> reducers;
        private readonly Dictionary<string, long> offsets;
        private readonly Dictionary<string, string> pending;
        private readonly Dictionary<string, DateTime> lastModifiedUtc;
        private DateTime lastDiscoveryUtc;

        public ClaudeTranscriptSessionMonitor()
            : this(Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile), ".claude", "projects"))
        {
        }

        public ClaudeTranscriptSessionMonitor(string root)
        {
            projectsRoot = root;
            reducers = new Dictionary<string, ClaudeTranscriptSessionReducer>(
                StringComparer.OrdinalIgnoreCase);
            offsets = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            pending = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            lastModifiedUtc = new Dictionary<string, DateTime>(
                StringComparer.OrdinalIgnoreCase);
            lastDiscoveryUtc = DateTime.MinValue;
        }

        public bool Refresh()
        {
            DateTime now = DateTime.UtcNow;
            bool changed = false;
            if ((now - lastDiscoveryUtc).TotalSeconds >= 2)
            {
                changed = Discover(now) || changed;
            }
            foreach (string path in reducers.Keys.ToList())
            {
                changed = ReadNewLines(path, now) || changed;
                HaloState previousState = reducers[path].Snapshot.State;
                string previousAction = reducers[path].Snapshot.Action;
                reducers[path].ApplyWorkingVisibility(now);
                if (previousState != reducers[path].Snapshot.State ||
                    !String.Equals(previousAction, reducers[path].Snapshot.Action,
                        StringComparison.Ordinal))
                {
                    changed = true;
                }
            }
            return changed;
        }

        public List<SessionSnapshot> Snapshots()
        {
            return reducers.Values.Select(delegate(
                ClaudeTranscriptSessionReducer reducer)
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
                    Agent = AgentKind.ClaudeCode
                };
            })
            .OrderByDescending(delegate(SessionSnapshot snapshot)
            {
                return snapshot.LastEventUtc;
            })
            .ToList();
        }

        private bool Discover(DateTime now)
        {
            lastDiscoveryUtc = now;
            if (!Directory.Exists(projectsRoot))
            {
                return false;
            }
            List<string> recent = Directory.GetFiles(projectsRoot, "*.jsonl",
                SearchOption.AllDirectories)
                .Where(delegate(string path)
                {
                    return path.IndexOf(Path.DirectorySeparatorChar +
                        "subagents" + Path.DirectorySeparatorChar,
                        StringComparison.OrdinalIgnoreCase) < 0 &&
                        File.GetLastWriteTimeUtc(path) >= now.AddDays(-2);
                })
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .Take(MaxRecentFiles)
                .ToList();
            HashSet<string> keep = new HashSet<string>(recent,
                StringComparer.OrdinalIgnoreCase);
            bool changed = false;
            foreach (string path in recent)
            {
                if (reducers.ContainsKey(path))
                {
                    continue;
                }
                ClaudeTranscriptSessionReducer reducer =
                    new ClaudeTranscriptSessionReducer(path, now, false);
                reducers[path] = reducer;
                ReadInitialTail(path, reducer);
                offsets[path] = File.Exists(path) ? new FileInfo(path).Length : 0;
                lastModifiedUtc[path] = File.Exists(path)
                    ? File.GetLastWriteTimeUtc(path) : DateTime.MinValue;
                reducer.SetLiveTracking(true);
                changed = true;
            }
            foreach (string path in reducers.Keys.ToList())
            {
                if (keep.Contains(path))
                {
                    continue;
                }
                reducers.Remove(path);
                offsets.Remove(path);
                pending.Remove(path);
                lastModifiedUtc.Remove(path);
                changed = true;
            }
            return changed;
        }

        private void ReadInitialTail(string path,
            ClaudeTranscriptSessionReducer reducer)
        {
            if (!File.Exists(path))
            {
                return;
            }
            using (FileStream stream = new FileStream(path, FileMode.Open,
                FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                long start = Math.Max(0, stream.Length - InitialTailBytes);
                stream.Seek(start, SeekOrigin.Begin);
                byte[] bytes = new byte[(int)(stream.Length - stream.Position)];
                int read = stream.Read(bytes, 0, bytes.Length);
                string text = Encoding.UTF8.GetString(bytes, 0, read);
                if (start > 0)
                {
                    int firstNewline = text.IndexOf('\n');
                    if (firstNewline >= 0 && firstNewline + 1 < text.Length)
                    {
                        text = text.Substring(firstNewline + 1);
                    }
                }
                ConsumeLines(path, reducer, text, DateTime.UtcNow);
            }
        }

        private bool ReadNewLines(string path, DateTime now)
        {
            if (!File.Exists(path))
            {
                return false;
            }
            long previous = offsets.ContainsKey(path) ? offsets[path] : 0;
            FileInfo info = new FileInfo(path);
            DateTime mtime = info.LastWriteTimeUtc;
            DateTime previousMtime = lastModifiedUtc.ContainsKey(path)
                ? lastModifiedUtc[path] : DateTime.MinValue;
            if (info.Length < previous ||
                (previousMtime != DateTime.MinValue && mtime != previousMtime &&
                 info.Length <= previous))
            {
                reducers[path] = new ClaudeTranscriptSessionReducer(path, now, true);
                offsets[path] = 0;
                pending.Remove(path);
                previous = 0;
            }
            if (info.Length <= previous)
            {
                lastModifiedUtc[path] = mtime;
                return false;
            }
            using (FileStream stream = new FileStream(path, FileMode.Open,
                FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                stream.Seek(previous, SeekOrigin.Begin);
                byte[] bytes = new byte[(int)(stream.Length - stream.Position)];
                int read = stream.Read(bytes, 0, bytes.Length);
                offsets[path] = stream.Length;
                lastModifiedUtc[path] = mtime;
                string text = Encoding.UTF8.GetString(bytes, 0, read);
                return ConsumeLines(path, reducers[path], text, now);
            }
        }

        private bool ConsumeLines(string path,
            ClaudeTranscriptSessionReducer reducer, string text, DateTime now)
        {
            string prefix;
            if (!pending.TryGetValue(path, out prefix))
            {
                prefix = String.Empty;
            }
            text = prefix + text;
            string[] lines = text.Split('\n');
            int complete = lines.Length;
            if (!text.EndsWith("\n", StringComparison.Ordinal))
            {
                pending[path] = lines[lines.Length - 1];
                complete--;
            }
            else
            {
                pending.Remove(path);
            }
            bool changed = false;
            for (int i = 0; i < complete; i++)
            {
                string line = lines[i].TrimEnd('\r').TrimStart('\ufeff');
                if (String.IsNullOrWhiteSpace(line))
                {
                    continue;
                }
                reducer.Consume(line, now);
                changed = true;
            }
            return changed;
        }
    }

public static class ClaudeStatusSourceMerger
    {
        public static List<SessionSnapshot> Merge(
            List<SessionSnapshot> hookSnapshots,
            List<SessionSnapshot> transcriptSnapshots)
        {
            Dictionary<string, SessionSnapshot> byThread =
                new Dictionary<string, SessionSnapshot>(StringComparer.OrdinalIgnoreCase);
            AddSnapshots(byThread, transcriptSnapshots);
            AddSnapshots(byThread, hookSnapshots);
            return byThread.Values.OrderByDescending(delegate(SessionSnapshot snapshot)
            {
                return snapshot.LastEventUtc;
            }).ToList();
        }

        private static void AddSnapshots(Dictionary<string, SessionSnapshot> byThread,
            List<SessionSnapshot> snapshots)
        {
            foreach (SessionSnapshot snapshot in snapshots)
            {
                SessionSnapshot existing;
                if (!byThread.TryGetValue(snapshot.ThreadId, out existing) ||
                    snapshot.LastEventUtc >= existing.LastEventUtc)
                {
                    byThread[snapshot.ThreadId] = snapshot;
                }
            }
        }
    }

public static class ClaudeLiveSessionReader
    {
        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();

        public static bool HasStandbySession()
        {
            return HasStandbySession(Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile));
        }

        public static bool HasStandbySession(string home)
        {
            try
            {
                string sessionsDir = Path.Combine(home, ".claude", "sessions");
                if (!Directory.Exists(sessionsDir))
                {
                    return false;
                }
                foreach (string path in Directory.GetFiles(sessionsDir, "*.json"))
                {
                    if (IsStandbySession(path))
                    {
                        return true;
                    }
                }
            }
            catch
            {
            }
            return false;
        }

        private static bool IsStandbySession(string path)
        {
            try
            {
                Dictionary<string, object> json = Serializer.DeserializeObject(
                    File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
                if (json == null)
                {
                    return false;
                }
                int pid;
                if (!Int32.TryParse(Convert.ToString(Value(json, "pid"),
                    CultureInfo.InvariantCulture), NumberStyles.Integer,
                    CultureInfo.InvariantCulture, out pid))
                {
                    return false;
                }
                Process.GetProcessById(pid);
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static object Value(Dictionary<string, object> dictionary, string key)
        {
            object value;
            return dictionary != null && dictionary.TryGetValue(key, out value)
                ? value : null;
        }

        private static string StringValue(Dictionary<string, object> dictionary,
            string key)
        {
            object value = Value(dictionary, key);
            return value == null ? String.Empty :
                Convert.ToString(value, CultureInfo.InvariantCulture);
        }
    }

public static class ClaudeCodeMetricsReader
    {
        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();

        public static ClaudeCodeMetrics Read()
        {
            return Read(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        }

        public static ClaudeCodeMetrics Read(string home)
        {
            ClaudeCodeMetrics metrics = new ClaudeCodeMetrics
            {
                IsCustomApi = IsCustomApi(home),
                Model = String.Empty,
                ContextTokens = -1
            };
            ReadTranscriptUsage(home, metrics);
            if (String.IsNullOrWhiteSpace(metrics.Model))
            {
                metrics.Model = FirstNonEmpty(
                    Environment.GetEnvironmentVariable("ANTHROPIC_MODEL"),
                    Environment.GetEnvironmentVariable("CLAUDE_MODEL"),
                    ReadSettingsEnv(home, "ANTHROPIC_MODEL"),
                    ReadSettingsEnv(home, "CLAUDE_MODEL"));
            }
            if (metrics.ContextWindowTokens <= 0)
            {
                metrics.ContextWindowTokens = ReadContextWindow(home);
            }
            return metrics;
        }

        public static bool IsCustomApi(string home)
        {
            string value = FirstNonEmpty(
                Environment.GetEnvironmentVariable("ANTHROPIC_BASE_URL"),
                Environment.GetEnvironmentVariable("ANTHROPIC_API_BASE_URL"),
                Environment.GetEnvironmentVariable("CLAUDE_CODE_API_BASE_URL"),
                ReadSettingsEnv(home, "ANTHROPIC_BASE_URL"),
                ReadSettingsEnv(home, "ANTHROPIC_API_BASE_URL"),
                ReadSettingsEnv(home, "CLAUDE_CODE_API_BASE_URL"));
            if (String.IsNullOrWhiteSpace(value))
            {
                return false;
            }
            return value.IndexOf("api.anthropic.com",
                StringComparison.OrdinalIgnoreCase) < 0 &&
                value.IndexOf("anthropic.com",
                    StringComparison.OrdinalIgnoreCase) < 0;
        }

        private static void ReadTranscriptUsage(string home,
            ClaudeCodeMetrics metrics)
        {
            try
            {
                string projects = Path.Combine(home, ".claude", "projects");
                if (!Directory.Exists(projects))
                {
                    return;
                }
                IEnumerable<string> files = Directory.GetFiles(projects, "*.jsonl",
                    SearchOption.AllDirectories)
                    .Where(delegate(string path)
                    {
                        return path.IndexOf(Path.DirectorySeparatorChar +
                            "subagents" + Path.DirectorySeparatorChar,
                            StringComparison.OrdinalIgnoreCase) < 0;
                    })
                    .OrderByDescending(File.GetLastWriteTimeUtc)
                    .Take(16);
                foreach (string path in files)
                {
                    string[] lines = ReadTailLines(path);
                    for (int i = lines.Length - 1; i >= 0; i--)
                    {
                        if (TryReadUsageLine(lines[i], metrics))
                        {
                            return;
                        }
                    }
                }
            }
            catch
            {
            }
        }

        private static bool TryReadUsageLine(string line,
            ClaudeCodeMetrics metrics)
        {
            try
            {
                Dictionary<string, object> root =
                    Serializer.DeserializeObject(line) as Dictionary<string, object>;
                Dictionary<string, object> message = Child(root, "message");
                string model = FirstNonEmpty(StringValue(root, "model"),
                    StringValue(message, "model"));
                Dictionary<string, object> usage = Child(message, "usage");
                if (usage == null)
                {
                    usage = Child(root, "usage");
                }
                if (String.IsNullOrWhiteSpace(model) && usage == null)
                {
                    return false;
                }
                if (!String.IsNullOrWhiteSpace(model))
                {
                    metrics.Model = model;
                }
                if (usage != null)
                {
                    long input = Number(usage, "input_tokens") +
                        Number(usage, "cache_read_input_tokens") +
                        Number(usage, "cache_creation_input_tokens");
                    long output = Number(usage, "output_tokens");
                    if (input > 0 || output > 0)
                    {
                        metrics.InputTokens = input;
                        metrics.OutputTokens = output;
                        metrics.ContextTokens = input;
                    }
                }
                return metrics.HasModel || metrics.HasTokenUsage;
            }
            catch
            {
                return false;
            }
        }

        private static long ReadContextWindow(string home)
        {
            long value;
            string raw = FirstNonEmpty(
                Environment.GetEnvironmentVariable("CLAUDE_MAX_CONTEXT_WINDOW"),
                ReadSettingsEnv(home, "CLAUDE_MAX_CONTEXT_WINDOW"));
            if (Int64.TryParse(raw, NumberStyles.Integer,
                CultureInfo.InvariantCulture, out value) && value > 0)
            {
                return value;
            }
            return 200000;
        }

        private static string ReadSettingsEnv(string home, string key)
        {
            try
            {
                string path = Path.Combine(home, ".claude", "settings.json");
                if (!File.Exists(path))
                {
                    return String.Empty;
                }
                Dictionary<string, object> root = Serializer.DeserializeObject(
                    File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
                Dictionary<string, object> env = Child(root, "env");
                return StringValue(env, key);
            }
            catch
            {
                return String.Empty;
            }
        }

        private static string[] ReadTailLines(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open,
                FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                long start = Math.Max(0, stream.Length - 256 * 1024);
                stream.Seek(start, SeekOrigin.Begin);
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8,
                    true, 4096, false))
                {
                    string text = reader.ReadToEnd();
                    string[] lines = text.Split(new[] { '\r', '\n' },
                        StringSplitOptions.RemoveEmptyEntries);
                    return start > 0 && lines.Length > 1
                        ? lines.Skip(1).ToArray() : lines;
                }
            }
        }

        private static long Number(Dictionary<string, object> source, string key)
        {
            object value;
            long result;
            return source != null && source.TryGetValue(key, out value) &&
                Int64.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                    NumberStyles.Integer, CultureInfo.InvariantCulture, out result)
                ? result : 0;
        }

        private static Dictionary<string, object> Child(
            Dictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value)
                ? value as Dictionary<string, object> : null;
        }

        private static string StringValue(Dictionary<string, object> source,
            string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value) &&
                value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture)
                : String.Empty;
        }

        private static string FirstNonEmpty(params string[] values)
        {
            foreach (string value in values)
            {
                if (!String.IsNullOrWhiteSpace(value))
                {
                    return value;
                }
            }
            return String.Empty;
        }
    }
}
