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
    /// routes via GROK_* env to logs/grok-status.jsonl).
    /// </summary>
    public static class GrokHookConfigurator
    {
        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();

        // Grok Build lifecycle set (macOS GrokHookConfigurator) — no Claude-only
        // PostToolBatch / PermissionRequest. PermissionDenied and StopCancelled
        // are first-class Grok events as of 1.0.4.
        private static readonly HookSpec[] HookSpecs =
        {
            new HookSpec("SessionStart", null),
            new HookSpec("UserPromptSubmit", null),
            new HookSpec("PreToolUse", ".*"),
            new HookSpec("PostToolUse", ".*"),
            new HookSpec("PostToolUseFailure", ".*"),
            new HookSpec("PermissionDenied", null),
            new HookSpec("Notification", null),
            new HookSpec("Stop", null),
            new HookSpec("StopFailure", null),
            new HookSpec("StopCancelled", null),
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

        internal static bool IsConfiguredForTest(
            string hooksPath, string executablePath)
        {
            return IsAlreadyConfigured(hooksPath, executablePath);
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
        /// <summary>
        /// Fast path Auto resolutions (read/grep) complete well under this.
        /// Shell Auto often sits in the 1.5–3 s band; those are gated by
        /// permissionMode instead of this threshold alone.
        /// </summary>
        public const int AutoResolveWaitMsThreshold = 300;
        /// <summary>
        /// Hold before painting attention when mode is unknown/default so
        /// same-poll auto resolve never flashes purple.
        /// </summary>
        public const double PendingPermissionAttentionDelaySeconds = 0.25;

        private readonly JavaScriptSerializer serializer;
        private DateTime workingVisibleUntilUtc;
        private DateTime thinkingVisibleUntilUtc;
        private string pendingWorkingAction;
        /// <summary>
        /// Genuine user-permission hold — must not auto-fade via stuck-tool net.
        /// </summary>
        private bool permissionPrompt;
        private bool? wasActiveBeforeCompaction;
        /// <summary>
        /// First observation time of an unresolved permission_requested.
        /// Delay clock uses observation time so late polls do not instantly purple.
        /// </summary>
        private DateTime pendingPermissionRequestedAtUtc = DateTime.MinValue;
        /// <summary>
        /// Last known Grok permissionMode from hooks (default / auto / plan /
        /// bypassPermissions). Auto and bypass never need a purple NEEDS YOU ring.
        /// </summary>
        private string permissionMode;
        /// <summary>
        /// State/action to restore after a human permission allow. Grok's real
        /// order is PreToolUse → permission_requested → permission_resolved →
        /// PostToolUse; there is no second PreToolUse after approve, so we must
        /// not drop back to Thinking while the tool is still running.
        /// </summary>
        private bool hasPrePermissionResume;
        private HaloState prePermissionResumeState;
        private string prePermissionResumeAction;
        /// <summary>
        /// Newest main-session promptId from a turn-scoped hook. Drops a late
        /// StopCancelled that belongs to an already-replaced turn.
        /// </summary>
        private string currentPromptId = String.Empty;
        private readonly HashSet<string> knownPromptIds =
            new HashSet<string>(StringComparer.Ordinal);

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
            DateTime previousLastEventUtc = Snapshot.LastEventUtc;
            Snapshot.LastEventUtc = eventUtc;
            Snapshot.EvidenceSource = AgentEvidenceSource.GrokHook;
            UpdateIdentity(root);
            UpdatePermissionMode(root);

            string eventName = StringValue(root, "event");
            if (String.Equals(eventName, "UserPromptSubmit", StringComparison.Ordinal))
            {
                if (!HasSubagentType(root))
                {
                    SetCurrentPromptId(FirstField(root, "promptId", "prompt_id"));
                }
            }
            else if (EstablishesCurrentPrompt(eventName))
            {
                AdoptCurrentPromptId(root);
            }

            switch (eventName)
            {
                case "SessionStart":
                    currentPromptId = String.Empty;
                    knownPromptIds.Clear();
                    if (wasActiveBeforeCompaction.HasValue)
                    {
                        ClearPermissionHold();
                        workingVisibleUntilUtc = DateTime.MinValue;
                        thinkingVisibleUntilUtc = DateTime.MinValue;
                        pendingWorkingAction = null;
                        Snapshot.Active = true;
                        Snapshot.State = HaloState.Working;
                        Snapshot.Action = "Compressing context";
                        Snapshot.CompletedUtc = DateTime.MinValue;
                        break;
                    }
                    ClearPermissionHold();
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
                    ClearPermissionHold();
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
                    ClearPermissionHold();
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
                    ClearPermissionHold();
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
                    ClearPermissionHold();
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
                    ReduceNotification(root, eventUtc, nowUtc);
                    break;
                case "PermissionRequest":
                    // Grok does not emit this today; keep parity with Claude path
                    // under the same Auto-safe rules as permission_prompt.
                    ApplyPermissionPromptHook(eventUtc, nowUtc);
                    break;
                case "PermissionDenied":
                    if (HasSubagentType(root))
                    {
                        Snapshot.LastEventUtc = previousLastEventUtc;
                        break;
                    }
                    wasActiveBeforeCompaction = null;
                    pendingPermissionRequestedAtUtc = DateTime.MinValue;
                    permissionPrompt = true;
                    ClearPrePermissionResume();
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
                    ClearPermissionHold();
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
                    ClearPermissionHold();
                    workingVisibleUntilUtc = DateTime.MinValue;
                    thinkingVisibleUntilUtc = DateTime.MinValue;
                    pendingWorkingAction = null;
                    Snapshot.Active = false;
                    Snapshot.State = HaloState.Error;
                    Snapshot.Action = "Grok stopped with an error";
                    Snapshot.CompletedUtc = DateTime.MinValue;
                    break;
                case "StopCancelled":
                    if (!ApplyStopCancelled(root, eventUtc))
                    {
                        Snapshot.LastEventUtc = previousLastEventUtc;
                    }
                    break;
                case "PreCompact":
                    if (!wasActiveBeforeCompaction.HasValue)
                    {
                        wasActiveBeforeCompaction = Snapshot.Active;
                    }
                    ClearPermissionHold();
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
                    ClearPermissionHold();
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
                    ClearPermissionHold();
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

        /// <summary>
        /// First-class Grok 1.0.4+ hook for a turn that ended without completing.
        /// Returns false when ignored (nested subagent, or a stale promptId).
        /// events.jsonl turn_ended cancelled remains the fallback for older Grok.
        /// </summary>
        public bool ApplyStopCancelled(Dictionary<string, object> root, DateTime eventUtc)
        {
            if (HasSubagentType(root))
            {
                return false;
            }
            string incomingPromptId = FirstField(root, "promptId", "prompt_id");
            if (ShouldIgnoreStopCancelled(incomingPromptId))
            {
                return false;
            }
            if (!String.IsNullOrEmpty(incomingPromptId))
            {
                SetCurrentPromptId(incomingPromptId);
            }
            string reason = FirstField(root, "reason");
            reason = reason == null ? String.Empty : reason.ToLowerInvariant();
            if (reason == "permission_rejected")
            {
                ApplyInterruptedTurn(eventUtc, "Permission denied", true, true);
            }
            else if (reason == "permission_cancelled")
            {
                ApplyInterruptedTurn(eventUtc, "Ready", false, true);
            }
            else if (reason == "max_turns" || reason == "no_progress")
            {
                ApplyInterruptedTurn(eventUtc, "Grok stopped with an error", true, true);
            }
            else
            {
                ApplyInterruptedTurn(eventUtc, "Interrupted", true, true);
            }
            return true;
        }

        private bool ShouldIgnoreStopCancelled(string incomingPromptId)
        {
            if (!String.IsNullOrEmpty(incomingPromptId) &&
                !String.IsNullOrEmpty(currentPromptId) &&
                !String.Equals(incomingPromptId, currentPromptId,
                    StringComparison.Ordinal))
            {
                // A known mismatch belongs to an older turn. An unseen ID is a
                // valid activity-less bash/builtin turn and must be settled.
                return knownPromptIds.Contains(incomingPromptId);
            }
            if (String.IsNullOrEmpty(incomingPromptId) &&
                !String.IsNullOrEmpty(currentPromptId) &&
                IsInFlight())
            {
                return true;
            }
            return false;
        }

        private bool IsInFlight()
        {
            return Snapshot.Active ||
                Snapshot.State == HaloState.Thinking ||
                Snapshot.State == HaloState.Working ||
                Snapshot.State == HaloState.Attention;
        }

        /// <summary>
        /// Turn-scoped activity can occur without UserPromptSubmit (notably bash
        /// mode). Track its promptId without letting nested subagents replace the
        /// parent turn identity.
        /// </summary>
        private void AdoptCurrentPromptId(Dictionary<string, object> root)
        {
            if (HasSubagentType(root))
            {
                return;
            }
            string promptId = FirstField(root, "promptId", "prompt_id");
            if (!String.IsNullOrEmpty(promptId))
            {
                SetCurrentPromptId(promptId);
            }
        }

        private void SetCurrentPromptId(string promptId)
        {
            currentPromptId = promptId ?? String.Empty;
            if (!String.IsNullOrEmpty(currentPromptId))
            {
                knownPromptIds.Add(currentPromptId);
            }
        }

        private static bool EstablishesCurrentPrompt(string eventName)
        {
            return eventName == "PreToolUse" ||
                eventName == "PostToolUse" ||
                eventName == "PostToolBatch" ||
                eventName == "PostToolUseFailure" ||
                eventName == "Notification" ||
                eventName == "PermissionRequest" ||
                eventName == "PermissionDenied" ||
                eventName == "Stop" ||
                eventName == "StopFailure" ||
                eventName == "PreCompact" ||
                eventName == "PostCompact";
        }

        /// <summary>
        /// Fallback for pre-1.0.4 Grok, which skipped Stop / StopFailure on
        /// Esc / Ctrl+C. Session events.jsonl records turn_ended with outcome
        /// "cancelled" — map that to the same fault ring Codex uses.
        /// Steer / Sent now also emits cancelled (often trigger send_now); those
        /// must not paint red — call ApplySteerCancel instead.
        /// </summary>
        public void ApplyTurnCancelled(DateTime eventUtc)
        {
            ApplyInterruptedTurn(eventUtc, "Interrupted", true);
        }

        /// <summary>
        /// Soft end for steer / cancel-then-send: clear the in-flight turn without
        /// the red fault ring. Subsequent UserPromptSubmit re-activates thinking.
        /// </summary>
        public void ApplySteerCancel(DateTime eventUtc)
        {
            ApplyInterruptedTurn(eventUtc, "Ready", false);
        }

        /// <summary>
        /// Non-cancel terminal failures observed in events.jsonl when hooks did
        /// not emit StopFailure.
        /// </summary>
        public void ApplyTurnFailed(DateTime eventUtc)
        {
            ApplyInterruptedTurn(eventUtc, "Grok stopped with an error", true);
        }

        private void ApplyInterruptedTurn(DateTime eventUtc, string action, bool asError)
        {
            ApplyInterruptedTurn(eventUtc, action, asError, false);
        }

        private void ApplyInterruptedTurn(
            DateTime eventUtc, string action, bool asError, bool refineTerminal)
        {
            bool sameTurnTerminal = refineTerminal &&
                (Snapshot.State == HaloState.Done || Snapshot.State == HaloState.Error);
            if (!IsInFlight() && !sameTurnTerminal)
            {
                return;
            }
            wasActiveBeforeCompaction = null;
            ClearPermissionHold();
            workingVisibleUntilUtc = DateTime.MinValue;
            thinkingVisibleUntilUtc = DateTime.MinValue;
            pendingWorkingAction = null;
            Snapshot.Active = false;
            Snapshot.State = asError ? HaloState.Error : HaloState.Idle;
            Snapshot.Action = action;
            Snapshot.LastEventUtc = eventUtc == DateTime.MinValue
                ? DateTime.UtcNow : eventUtc;
            Snapshot.CompletedUtc = DateTime.MinValue;
        }

        public void ApplyWorkingVisibility(DateTime nowUtc)
        {
            // Pending human permission → attention after delay (Strategy C).
            ApplyPermissionVisibility(nowUtc);

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

        private void ReduceNotification(Dictionary<string, object> root,
            DateTime eventUtc, DateTime nowUtc)
        {
            switch (StringValue(root, "notificationType"))
            {
                case "permission_prompt":
                    ApplyPermissionPromptHook(eventUtc, nowUtc);
                    break;
                case "idle_prompt":
                    wasActiveBeforeCompaction = null;
                    ClearPermissionHold();
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

        // Strategy A: hook permission_prompt — never paint attention immediately.
        // Auto/bypass suppress entirely; otherwise arm Strategy C delayed pending.
        private void ApplyPermissionPromptHook(DateTime eventUtc, DateTime observedAtUtc)
        {
            wasActiveBeforeCompaction = null;
            if (SuppressesPermissionAttention)
            {
                pendingPermissionRequestedAtUtc = DateTime.MinValue;
                return;
            }
            ArmPendingPermission(eventUtc, observedAtUtc);
        }

        /// <summary>
        /// Strategy C: begin a permission decision without painting attention yet.
        /// Grok emits PreToolUse before the permission UI, so state is often already
        /// Working — still arm the timer in ask modes.
        /// </summary>
        public void ApplyPermissionRequested(DateTime eventUtc, DateTime observedAtUtc)
        {
            if (SuppressesPermissionAttention)
            {
                pendingPermissionRequestedAtUtc = DateTime.MinValue;
                if (eventUtc > Snapshot.LastEventUtc)
                {
                    Snapshot.LastEventUtc = eventUtc;
                }
                return;
            }
            ArmPendingPermission(eventUtc, observedAtUtc);
        }

        public void ApplyPermissionResolved(string decision, int waitMs, DateTime eventUtc)
        {
            pendingPermissionRequestedAtUtc = DateTime.MinValue;
            if (eventUtc > Snapshot.LastEventUtc)
            {
                Snapshot.LastEventUtc = eventUtc;
            }

            bool denied = IsDeniedDecision(decision);
            bool auto = waitMs < AutoResolveWaitMsThreshold || SuppressesPermissionAttention;

            if (auto && !denied)
            {
                // Drop false attention; restore working when PreToolUse already
                // started the tool (Grok does not re-emit PreToolUse after allow).
                permissionPrompt = false;
                if (Snapshot.State == HaloState.Attention)
                {
                    RestoreAfterPermissionAllow();
                }
                else
                {
                    ClearPrePermissionResume();
                }
                return;
            }

            if (denied)
            {
                permissionPrompt = true;
                ClearPrePermissionResume();
                workingVisibleUntilUtc = DateTime.MinValue;
                thinkingVisibleUntilUtc = DateTime.MinValue;
                pendingWorkingAction = null;
                Snapshot.Active = true;
                Snapshot.State = HaloState.Attention;
                Snapshot.Action = "Permission denied";
                Snapshot.CompletedUtc = DateTime.MinValue;
                return;
            }

            // Human allow: tool continues without a second PreToolUse. Restore
            // pre-hold working state/action when we had one.
            if (Snapshot.State == HaloState.Attention || permissionPrompt)
            {
                permissionPrompt = false;
                Snapshot.Active = true;
                if (Snapshot.State == HaloState.Attention)
                {
                    RestoreAfterPermissionAllow();
                }
                else
                {
                    ClearPrePermissionResume();
                }
                Snapshot.CompletedUtc = DateTime.MinValue;
            }
        }

        public void ApplyPermissionUpdate(GrokPermissionUpdate update, DateTime nowUtc)
        {
            if (update == null)
            {
                return;
            }
            if (update.Kind == GrokPermissionUpdateKind.Requested)
            {
                ApplyPermissionRequested(update.AtUtc, nowUtc);
            }
            else
            {
                ApplyPermissionResolved(update.Decision, update.WaitMs, update.AtUtc);
            }
        }

        /// <summary>
        /// Promote still-pending permission_requested to NEEDS YOU after delay.
        /// Applies even when state is Working (PreToolUse before human prompt).
        /// Suppressed entirely while permissionMode is auto/bypass.
        /// </summary>
        public void ApplyPermissionVisibility(DateTime nowUtc)
        {
            if (pendingPermissionRequestedAtUtc == DateTime.MinValue)
            {
                return;
            }
            if (SuppressesPermissionAttention)
            {
                pendingPermissionRequestedAtUtc = DateTime.MinValue;
                return;
            }
            if ((nowUtc - pendingPermissionRequestedAtUtc).TotalSeconds <
                PendingPermissionAttentionDelaySeconds)
            {
                return;
            }
            pendingPermissionRequestedAtUtc = DateTime.MinValue;
            // Capture resume target before overwriting with NEEDS YOU. Real Grok
            // order is PreToolUse (working) → wait → allow → tool runs → PostToolUse.
            CapturePrePermissionResume();
            permissionPrompt = true;
            workingVisibleUntilUtc = DateTime.MinValue;
            thinkingVisibleUntilUtc = DateTime.MinValue;
            pendingWorkingAction = null;
            Snapshot.Active = true;
            Snapshot.State = HaloState.Attention;
            Snapshot.Action = "Awaiting permission";
            Snapshot.CompletedUtc = DateTime.MinValue;
            if (nowUtc > Snapshot.LastEventUtc)
            {
                Snapshot.LastEventUtc = nowUtc;
            }
        }

        private void ArmPendingPermission(DateTime eventUtc, DateTime observedAtUtc)
        {
            if (pendingPermissionRequestedAtUtc == DateTime.MinValue)
            {
                pendingPermissionRequestedAtUtc = observedAtUtc;
            }
            if (eventUtc > Snapshot.LastEventUtc)
            {
                Snapshot.LastEventUtc = eventUtc;
            }
            if (!Snapshot.Active &&
                (Snapshot.State == HaloState.Idle || Snapshot.State == HaloState.Done))
            {
                Snapshot.Active = true;
            }
        }

        /// <summary>
        /// Remember state/action so human allow can resume tool execution UI.
        /// </summary>
        private void CapturePrePermissionResume()
        {
            if (hasPrePermissionResume)
            {
                return;
            }
            if (Snapshot.State == HaloState.Working)
            {
                hasPrePermissionResume = true;
                prePermissionResumeState = HaloState.Working;
                prePermissionResumeAction = Snapshot.Action;
                return;
            }
            if (!String.IsNullOrEmpty(pendingWorkingAction))
            {
                // PreToolUse during thinking min-hold: tool action is deferred.
                hasPrePermissionResume = true;
                prePermissionResumeState = HaloState.Working;
                prePermissionResumeAction = pendingWorkingAction;
                return;
            }
            if (Snapshot.State == HaloState.Thinking)
            {
                hasPrePermissionResume = true;
                prePermissionResumeState = HaloState.Thinking;
                prePermissionResumeAction = Snapshot.Action;
                return;
            }
            hasPrePermissionResume = true;
            prePermissionResumeState = HaloState.Thinking;
            prePermissionResumeAction = "Thinking";
        }

        /// <summary>
        /// After allow: restore working tool UI when we had one; otherwise Thinking.
        /// </summary>
        private void RestoreAfterPermissionAllow()
        {
            Snapshot.Active = true;
            if (hasPrePermissionResume)
            {
                Snapshot.State = prePermissionResumeState;
                Snapshot.Action = prePermissionResumeAction;
                ClearPrePermissionResume();
                return;
            }
            Snapshot.State = HaloState.Thinking;
            Snapshot.Action = "Thinking";
        }

        private void ClearPrePermissionResume()
        {
            hasPrePermissionResume = false;
            prePermissionResumeState = HaloState.Idle;
            prePermissionResumeAction = null;
        }

        private void ClearPermissionHold()
        {
            permissionPrompt = false;
            pendingPermissionRequestedAtUtc = DateTime.MinValue;
            ClearPrePermissionResume();
        }

        private bool SuppressesPermissionAttention
        {
            get { return IsAutoLikePermissionMode(permissionMode); }
        }

        private void UpdatePermissionMode(Dictionary<string, object> root)
        {
            string mode = StringValue(root, "permissionMode");
            if (!String.IsNullOrEmpty(mode))
            {
                permissionMode = mode;
            }
        }

        public static bool IsAutoLikePermissionMode(string mode)
        {
            if (String.IsNullOrEmpty(mode))
            {
                return false;
            }
            switch (mode.Trim().ToLowerInvariant())
            {
                case "auto":
                case "bypasspermissions":
                case "bypass_permissions":
                case "always-approve":
                case "always_approve":
                case "yolo":
                case "dontask":
                case "dont_ask":
                    return true;
                default:
                    return false;
            }
        }

        private static bool IsDeniedDecision(string decision)
        {
            if (String.IsNullOrEmpty(decision))
            {
                return false;
            }
            string lower = decision.ToLowerInvariant();
            return lower.IndexOf("reject", StringComparison.Ordinal) >= 0 ||
                lower.IndexOf("deny", StringComparison.Ordinal) >= 0 ||
                String.Equals(lower, "denied", StringComparison.Ordinal);
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

        private static string FirstField(Dictionary<string, object> dictionary,
            params string[] keys)
        {
            if (keys == null)
            {
                return String.Empty;
            }
            for (int i = 0; i < keys.Length; i++)
            {
                string value = StringValue(dictionary, keys[i]);
                if (!String.IsNullOrEmpty(value))
                {
                    return value;
                }
            }
            return String.Empty;
        }

        private static bool HasSubagentType(Dictionary<string, object> root)
        {
            return !String.IsNullOrEmpty(
                FirstField(root, "subagentType", "subagent_type"));
        }
    }

    public sealed class GrokHookStatusMonitor
    {
        private readonly string statusPath;
        private readonly string sessionsRoot;
        private readonly Dictionary<string, GrokHookStatusReducer> reducers;
        private readonly GrokSessionTurnEventsReader turnEventsReader;
        private readonly Dictionary<string, GrokSessionTurnState> turnStates;
        private long offset;
        private string pending;
        private DateTime lastModifiedUtc;

        public GrokHookStatusMonitor()
            : this(AgentHaloPaths.GrokStatusLog(),
                GrokSessionContextReader.DefaultSessionsRoot())
        {
        }

        public GrokHookStatusMonitor(string path)
            : this(path, GrokSessionContextReader.DefaultSessionsRoot())
        {
        }

        public GrokHookStatusMonitor(string path, string sessionsRoot)
        {
            statusPath = path;
            this.sessionsRoot = String.IsNullOrEmpty(sessionsRoot)
                ? GrokSessionContextReader.DefaultSessionsRoot()
                : sessionsRoot;
            reducers = new Dictionary<string, GrokHookStatusReducer>(
                StringComparer.OrdinalIgnoreCase);
            turnEventsReader = new GrokSessionTurnEventsReader();
            turnStates = new Dictionary<string, GrokSessionTurnState>(
                StringComparer.OrdinalIgnoreCase);
            pending = String.Empty;
        }

        public bool Refresh()
        {
            DateTime now = DateTime.UtcNow;
            bool hooksChanged = RefreshHooks(now);
            bool turnChanged = ApplySessionTurnEvents(now);
            return ApplyAndPrune(now) || hooksChanged || turnChanged;
        }

        private bool RefreshHooks(DateTime now)
        {
            bool changed = false;
            FileInfo info = new FileInfo(statusPath);
            if (!info.Exists)
            {
                return false;
            }
            if (info.Length < offset ||
                (lastModifiedUtc != DateTime.MinValue &&
                 info.LastWriteTimeUtc != lastModifiedUtc && info.Length <= offset))
            {
                offset = 0;
                pending = String.Empty;
                reducers.Clear();
                turnEventsReader.Reset();
                turnStates.Clear();
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
            return changed;
        }

        /// <summary>
        /// Poll session events.jsonl for:
        /// - Esc cancel / failed turn_ended (fallback when StopCancelled is absent)
        /// - Steer supersede (send_now / cancel_then_send / newer turn_started)
        /// - permission_requested / permission_resolved (Strategy C: Auto vs human)
        /// </summary>
        private bool ApplySessionTurnEvents(DateTime now)
        {
            bool changed = false;
            foreach (KeyValuePair<string, GrokHookStatusReducer> pair in reducers)
            {
                GrokHookStatusReducer reducer = pair.Value;
                SessionSnapshot snapshot = reducer.Snapshot;
                bool needsWatch = snapshot.Active ||
                    snapshot.State == HaloState.Thinking ||
                    snapshot.State == HaloState.Working ||
                    snapshot.State == HaloState.Attention;
                if (!needsWatch)
                {
                    continue;
                }
                string eventsPath = EventsPathFor(snapshot);
                if (String.IsNullOrEmpty(eventsPath))
                {
                    continue;
                }
                GrokSessionEventsDelta delta = turnEventsReader.Poll(eventsPath);
                GrokSessionTurnState previousTurn;
                bool hadPrevious = turnStates.TryGetValue(pair.Key, out previousTurn);
                GrokSessionTurnState nextTurn = turnEventsReader.TurnState(eventsPath);
                turnStates[pair.Key] = nextTurn;
                if (!hadPrevious || previousTurn == null ||
                    previousTurn.LastStartedAtUtc != nextTurn.LastStartedAtUtc ||
                    previousTurn.LastEndedAtUtc != nextTurn.LastEndedAtUtc)
                {
                    changed = true;
                }
                if (delta == null || delta.IsEmpty)
                {
                    continue;
                }

                HaloState beforeState = reducer.Snapshot.State;
                string beforeAction = reducer.Snapshot.Action;
                bool beforeActive = reducer.Snapshot.Active;

                if (delta.PermissionUpdates != null)
                {
                    for (int i = 0; i < delta.PermissionUpdates.Count; i++)
                    {
                        reducer.ApplyPermissionUpdate(delta.PermissionUpdates[i], now);
                    }
                }

                GrokSessionTurnEnd turnEnd = delta.TurnEnd;
                if (turnEnd != null &&
                    (turnEnd.Outcome == GrokSessionTurnEndOutcome.Cancelled ||
                     turnEnd.Outcome == GrokSessionTurnEndOutcome.Failed))
                {
                    SessionSnapshot latest = reducer.Snapshot;
                    // Steer (Sent now) writes UserPromptSubmit within a few ms of
                    // turn_ended cancelled. Any newer hook means the session already
                    // moved on — never let a stale cancel paint red over thinking.
                    if (turnEnd.EndedAtUtc <= latest.LastEventUtc)
                    {
                        // superseded
                    }
                    else if (delta.TurnStart != null &&
                        delta.TurnStart.StartedAtUtc >= turnEnd.EndedAtUtc)
                    {
                        if (turnEnd.Outcome == GrokSessionTurnEndOutcome.Cancelled)
                        {
                            reducer.ApplySteerCancel(turnEnd.EndedAtUtc);
                        }
                    }
                    else if (turnEnd.Outcome == GrokSessionTurnEndOutcome.Cancelled)
                    {
                        if (turnEnd.IsSteerLikeCancel)
                        {
                            reducer.ApplySteerCancel(turnEnd.EndedAtUtc);
                        }
                        else
                        {
                            reducer.ApplyTurnCancelled(turnEnd.EndedAtUtc);
                        }
                    }
                    else
                    {
                        reducer.ApplyTurnFailed(turnEnd.EndedAtUtc);
                    }
                }

                if (beforeState != reducer.Snapshot.State ||
                    beforeActive != reducer.Snapshot.Active ||
                    !String.Equals(beforeAction, reducer.Snapshot.Action,
                        StringComparison.Ordinal))
                {
                    changed = true;
                }
            }
            return changed;
        }

        private string EventsPathFor(SessionSnapshot snapshot)
        {
            string cwd = snapshot == null ? null : snapshot.WorkingDirectory;
            string sessionId = snapshot == null ? null : snapshot.ThreadId;
            if (String.IsNullOrEmpty(sessionId))
            {
                return null;
            }
            string directory = ResolveSessionDirectory(sessionId, cwd);
            if (String.IsNullOrEmpty(directory))
            {
                return null;
            }
            return Path.Combine(directory, "events.jsonl");
        }

        private string ResolveSessionDirectory(string sessionId, string cwd)
        {
            if (!String.IsNullOrEmpty(cwd))
            {
                string encoded = GrokSessionContextReader.EncodeWorkspaceDirectory(cwd);
                string candidate = Path.Combine(sessionsRoot, encoded, sessionId);
                if (IsSessionDirectory(candidate))
                {
                    return candidate;
                }
            }
            if (!Directory.Exists(sessionsRoot))
            {
                return null;
            }
            try
            {
                foreach (string workspace in Directory.GetDirectories(sessionsRoot))
                {
                    string candidate = Path.Combine(workspace, sessionId);
                    if (IsSessionDirectory(candidate))
                    {
                        return candidate;
                    }
                }
            }
            catch
            {
            }
            return null;
        }

        private static bool IsSessionDirectory(string path)
        {
            if (String.IsNullOrEmpty(path) || !Directory.Exists(path))
            {
                return false;
            }
            string[] markers = new string[]
            {
                "events.jsonl", "signals.json", "updates.jsonl",
                "summary.json", "chat_history.jsonl"
            };
            for (int i = 0; i < markers.Length; i++)
            {
                if (File.Exists(Path.Combine(path, markers[i])))
                {
                    return true;
                }
            }
            return false;
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

        public Dictionary<string, GrokSessionTurnState> TurnStates()
        {
            Dictionary<string, GrokSessionTurnState> result =
                new Dictionary<string, GrokSessionTurnState>(
                    StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, GrokSessionTurnState> pair in turnStates)
            {
                result[pair.Key] = pair.Value == null
                    ? new GrokSessionTurnState()
                    : new GrokSessionTurnState
                    {
                        LastStartedAtUtc = pair.Value.LastStartedAtUtc,
                        LastEndedAtUtc = pair.Value.LastEndedAtUtc
                    };
            }
            return result;
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
            List<string> stale = reducers.Where(delegate(
                KeyValuePair<string, GrokHookStatusReducer> pair)
            {
                return ShouldPruneSnapshot(pair.Value.Snapshot, now);
            }).Select(delegate(KeyValuePair<string, GrokHookStatusReducer> pair)
            {
                return pair.Key;
            }).ToList();
            foreach (string key in stale)
            {
                reducers.Remove(key);
                turnStates.Remove(key);
                changed = true;
            }
            return changed;
        }

        /// <summary>
        /// Age-based prune. Attention (NEEDS YOU / awaiting permission) is never
        /// pruned by lastEvent age — humans may leave a prompt open indefinitely
        /// with no hooks until they act.
        /// </summary>
        internal static bool ShouldPruneSnapshot(
            SessionSnapshot snapshot, DateTime now)
        {
            if (snapshot == null)
            {
                return true;
            }
            // Keep purple NEEDS YOU across long human delays (showers, etc.).
            if (snapshot.State == HaloState.Attention)
            {
                return false;
            }
            if (snapshot.State == HaloState.Error)
            {
                return snapshot.LastEventUtc < now.AddHours(-1);
            }
            DateTime cutoff = snapshot.Active
                ? now.AddMinutes(-10)
                : now.AddMinutes(-5);
            return snapshot.LastEventUtc < cutoff;
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
    /// Terminal outcomes from Grok session events.jsonl (turn_ended).
    /// Esc / Ctrl+C cancel skips Stop hooks; the durable signal is
    /// turn_ended with outcome "cancelled".
    /// </summary>
    public enum GrokSessionTurnEndOutcome
    {
        Completed,
        Cancelled,
        Failed,
        Other
    }

    public sealed class GrokSessionTurnEnd
    {
        public DateTime EndedAtUtc;
        public GrokSessionTurnEndOutcome Outcome;
        /// <summary>cancellation_category (e.g. mid_turn_abort, permission_rejected).</summary>
        public string CancellationCategory = String.Empty;
        /// <summary>cancellation_context.trigger (e.g. esc, send_now).</summary>
        public string CancellationTrigger = String.Empty;

        /// <summary>
        /// Steer / Sent now aborts only to start another turn immediately.
        /// Those must not paint the red fault ring.
        /// </summary>
        public bool IsSteerLikeCancel
        {
            get
            {
                if (Outcome != GrokSessionTurnEndOutcome.Cancelled)
                {
                    return false;
                }
                string trigger = CancellationTrigger == null
                    ? String.Empty
                    : CancellationTrigger.Trim().ToLowerInvariant();
                return trigger == "send_now" ||
                    trigger == "steer" ||
                    trigger == "redirect" ||
                    trigger == "queued_send";
            }
        }
    }

    /// <summary>
    /// A turn_started line from session events.jsonl. Steer redirects use
    /// redirect_kind cancel_then_send / queued_after_cancel.
    /// </summary>
    public sealed class GrokSessionTurnStart
    {
        public DateTime StartedAtUtc;
        public string RedirectKind = String.Empty;

        public bool IsSteerRedirect
        {
            get
            {
                string kind = RedirectKind == null
                    ? String.Empty
                    : RedirectKind.Trim().ToLowerInvariant();
                return kind == "cancel_then_send" || kind == "queued_after_cancel";
            }
        }
    }

    /// <summary>
    /// Latest durable turn boundaries for one Grok session. active_sessions.json
    /// can omit a still-running conversation when one process owns several tabs.
    /// </summary>
    public sealed class GrokSessionTurnState
    {
        public DateTime LastStartedAtUtc = DateTime.MinValue;
        public DateTime LastEndedAtUtc = DateTime.MinValue;

        public bool IsOpen
        {
            get
            {
                return LastStartedAtUtc != DateTime.MinValue &&
                    (LastEndedAtUtc == DateTime.MinValue ||
                     LastStartedAtUtc >= LastEndedAtUtc);
            }
        }
    }

    public enum GrokPermissionUpdateKind
    {
        Requested,
        Resolved
    }

    /// <summary>
    /// Permission lifecycle lines from Grok session events.jsonl.
    /// Auto still emits permission_requested/resolved; real waits have multi-second wait_ms.
    /// </summary>
    public sealed class GrokPermissionUpdate
    {
        public DateTime AtUtc;
        public GrokPermissionUpdateKind Kind;
        public string ToolName;
        public string Decision;
        public int WaitMs;
    }

    /// <summary>
    /// One poll of a session events.jsonl tail.
    /// </summary>
    public sealed class GrokSessionEventsDelta
    {
        public GrokSessionTurnEnd TurnEnd;
        public GrokSessionTurnStart TurnStart;
        public List<GrokPermissionUpdate> PermissionUpdates =
            new List<GrokPermissionUpdate>();

        public bool IsEmpty
        {
            get
            {
                return TurnEnd == null &&
                    TurnStart == null &&
                    (PermissionUpdates == null || PermissionUpdates.Count == 0);
            }
        }
    }

    /// <summary>
    /// Incrementally tails events.jsonl for turn ends and permission lifecycle.
    /// Stateful per session path so the (often multi-hundred-KB) phase stream is
    /// not fully re-read every poll. First attach walks backward from EOF until
    /// the latest turn_started so a long phase_changed burst cannot hide the
    /// current turn boundary.
    /// </summary>
    public sealed class GrokSessionTurnEventsReader
    {
        private const int FirstAttachChunkBytes = 64 * 1024;

        private sealed class TailState
        {
            public long Offset;
            public string Pending = String.Empty;
            public DateTime LastModifiedUtc = DateTime.MinValue;
            public bool SawFile;
            public DateTime LastStartedAtUtc = DateTime.MinValue;
            public DateTime LastEndedAtUtc = DateTime.MinValue;
        }

        private readonly Dictionary<string, TailState> tails =
            new Dictionary<string, TailState>(StringComparer.OrdinalIgnoreCase);
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();

        public void Reset()
        {
            tails.Clear();
        }

        public GrokSessionEventsDelta Poll(string eventsPath)
        {
            if (String.IsNullOrEmpty(eventsPath) || !File.Exists(eventsPath))
            {
                if (!String.IsNullOrEmpty(eventsPath))
                {
                    tails.Remove(eventsPath);
                }
                return new GrokSessionEventsDelta();
            }

            TailState state;
            if (!tails.TryGetValue(eventsPath, out state) || state == null)
            {
                state = new TailState();
                tails[eventsPath] = state;
            }

            FileInfo info;
            try
            {
                info = new FileInfo(eventsPath);
            }
            catch
            {
                return new GrokSessionEventsDelta();
            }
            long size = info.Length;
            DateTime mtime = info.LastWriteTimeUtc;
            if (size <= 0)
            {
                tails[eventsPath] = new TailState();
                return new GrokSessionEventsDelta();
            }

            bool mtimeChanged = state.LastModifiedUtc != DateTime.MinValue &&
                mtime != state.LastModifiedUtc;
            bool truncated = size < state.Offset ||
                (mtimeChanged && size <= state.Offset);
            if (truncated)
            {
                state = new TailState();
                tails[eventsPath] = state;
            }

            bool isFirstAttach = !state.SawFile;
            state.SawFile = true;
            state.LastModifiedUtc = mtime;

            if (isFirstAttach)
            {
                List<string> firstLines =
                    CollectFirstAttachRelevantLines(eventsPath, size);
                state.Offset = size;
                state.Pending = String.Empty;
                return ParseTurnEventLines(firstLines, 0, firstLines.Count, state);
            }
            if (size <= state.Offset)
            {
                return new GrokSessionEventsDelta();
            }

            try
            {
                using (FileStream stream = new FileStream(eventsPath, FileMode.Open,
                    FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    stream.Seek(state.Offset, SeekOrigin.Begin);
                    byte[] bytes = new byte[(int)(stream.Length - stream.Position)];
                    int read = stream.Read(bytes, 0, bytes.Length);
                    state.Offset = size;
                    string chunk = Encoding.UTF8.GetString(bytes, 0, read);
                    string text = state.Pending + chunk;
                    string[] lines = text.Split('\n');
                    int complete = lines.Length;
                    if (!text.EndsWith("\n", StringComparison.Ordinal))
                    {
                        state.Pending = lines[lines.Length - 1];
                        complete--;
                    }
                    else
                    {
                        state.Pending = String.Empty;
                    }
                    return ParseTurnEventLines(lines, 0, complete, state);
                }
            }
            catch
            {
                return new GrokSessionEventsDelta();
            }
        }

        private List<string> CollectFirstAttachRelevantLines(string eventsPath, long size)
        {
            List<string> collected = new List<string>();
            if (size <= 0 || String.IsNullOrEmpty(eventsPath) || !File.Exists(eventsPath))
            {
                return collected;
            }
            try
            {
                using (FileStream stream = new FileStream(eventsPath, FileMode.Open,
                    FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    long pos = size;
                    string suffix = String.Empty;
                    bool foundStart = false;
                    byte[] buffer = new byte[FirstAttachChunkBytes];
                    while (pos > 0 && !foundStart)
                    {
                        long chunkStart = pos > FirstAttachChunkBytes
                            ? pos - FirstAttachChunkBytes
                            : 0;
                        int toRead = (int)(pos - chunkStart);
                        stream.Seek(chunkStart, SeekOrigin.Begin);
                        int read = stream.Read(buffer, 0, toRead);
                        string chunk = Encoding.UTF8.GetString(buffer, 0, read);
                        string text = chunk + suffix;
                        string completeText;
                        if (chunkStart > 0)
                        {
                            int newline = text.IndexOf('\n');
                            if (newline >= 0)
                            {
                                suffix = text.Substring(0, newline + 1);
                                completeText = text.Substring(newline + 1);
                            }
                            else
                            {
                                suffix = text;
                                completeText = String.Empty;
                            }
                        }
                        else
                        {
                            suffix = String.Empty;
                            completeText = text;
                        }
                        string[] lines = completeText.Split('\n');
                        int complete = lines.Length;
                        if (pos == size &&
                            !text.EndsWith("\n", StringComparison.Ordinal) &&
                            complete > 0)
                        {
                            complete--;
                        }
                        List<string> kept = new List<string>();
                        bool chunkHasStart = false;
                        for (int i = 0; i < complete; i++)
                        {
                            string trimmed = lines[i].TrimEnd('\r').TrimStart('\ufeff');
                            if (String.IsNullOrWhiteSpace(trimmed) ||
                                !IsRelevantTurnEventLine(trimmed))
                            {
                                continue;
                            }
                            kept.Add(trimmed);
                            if (trimmed.IndexOf("turn_started",
                                StringComparison.Ordinal) >= 0)
                            {
                                chunkHasStart = true;
                            }
                        }
                        collected.InsertRange(0, kept);
                        foundStart = chunkHasStart;
                        pos = chunkStart;
                    }
                }
            }
            catch
            {
            }
            return collected;
        }

        private static bool IsRelevantTurnEventLine(string line)
        {
            return line.IndexOf("turn_started", StringComparison.Ordinal) >= 0 ||
                line.IndexOf("turn_ended", StringComparison.Ordinal) >= 0 ||
                line.IndexOf("permission_requested", StringComparison.Ordinal) >= 0 ||
                line.IndexOf("permission_resolved", StringComparison.Ordinal) >= 0;
        }

        private GrokSessionEventsDelta ParseTurnEventLines(
            IList<string> lines, int startIndex, int complete, TailState state)
        {
            GrokSessionTurnEnd latest = null;
            GrokSessionTurnStart latestStart = null;
            DateTime lastStartedAt = DateTime.MinValue;
            List<GrokPermissionUpdate> permissions =
                new List<GrokPermissionUpdate>();
            for (int i = startIndex; i < complete; i++)
            {
                string line = lines[i].TrimEnd('\r').TrimStart('\ufeff');
                if (String.IsNullOrWhiteSpace(line))
                {
                    continue;
                }
                Dictionary<string, object> root = null;
                try
                {
                    root = serializer.DeserializeObject(line)
                        as Dictionary<string, object>;
                }
                catch
                {
                    continue;
                }
                if (root == null)
                {
                    continue;
                }
                string type = StringValue(root, "type");
                DateTime at = ParseDate(StringValue(root, "ts"));
                if (at == DateTime.MinValue)
                {
                    at = ParseDate(StringValue(root, "timestamp"));
                }
                if (at == DateTime.MinValue)
                {
                    at = DateTime.UtcNow;
                }
                if (String.Equals(type, "turn_started",
                    StringComparison.OrdinalIgnoreCase))
                {
                    lastStartedAt = at;
                    if (state.LastStartedAtUtc == DateTime.MinValue ||
                        at > state.LastStartedAtUtc)
                    {
                        state.LastStartedAtUtc = at;
                    }
                    string redirectKind = StringValue(root, "redirect_kind");
                    // Only surface starts with a steer redirect_kind —
                    // ordinary starts would make IsEmpty false every turn.
                    if (!String.IsNullOrEmpty(redirectKind))
                    {
                        latestStart = new GrokSessionTurnStart
                        {
                            StartedAtUtc = at,
                            RedirectKind = redirectKind
                        };
                    }
                    // Steer writes turn_ended cancelled then turn_started
                    // in the same tail chunk — newer start supersedes end.
                    if (latest != null && at >= latest.EndedAtUtc)
                    {
                        latest = null;
                    }
                    continue;
                }
                if (String.Equals(type, "permission_requested",
                    StringComparison.OrdinalIgnoreCase))
                {
                    permissions.Add(new GrokPermissionUpdate
                    {
                        AtUtc = at,
                        Kind = GrokPermissionUpdateKind.Requested,
                        ToolName = StringValue(root, "tool_name")
                    });
                    continue;
                }
                if (String.Equals(type, "permission_resolved",
                    StringComparison.OrdinalIgnoreCase))
                {
                    permissions.Add(new GrokPermissionUpdate
                    {
                        AtUtc = at,
                        Kind = GrokPermissionUpdateKind.Resolved,
                        ToolName = StringValue(root, "tool_name"),
                        Decision = StringValue(root, "decision"),
                        WaitMs = IntValue(root, "wait_ms")
                    });
                    continue;
                }
                if (!String.Equals(type, "turn_ended",
                    StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                GrokSessionTurnEndOutcome outcome =
                    ParseOutcome(StringValue(root, "outcome"));
                if (state.LastEndedAtUtc == DateTime.MinValue ||
                    at > state.LastEndedAtUtc)
                {
                    state.LastEndedAtUtc = at;
                }
                if (lastStartedAt != DateTime.MinValue && lastStartedAt > at)
                {
                    continue;
                }
                latest = new GrokSessionTurnEnd
                {
                    EndedAtUtc = at,
                    Outcome = outcome,
                    CancellationCategory =
                        StringValue(root, "cancellation_category"),
                    CancellationTrigger =
                        NestedStringValue(root, "cancellation_context", "trigger")
                };
            }
            return new GrokSessionEventsDelta
            {
                TurnEnd = latest,
                TurnStart = latestStart,
                PermissionUpdates = permissions
            };
        }

        public GrokSessionTurnState TurnState(string eventsPath)
        {
            TailState state;
            if (String.IsNullOrEmpty(eventsPath) ||
                !tails.TryGetValue(eventsPath, out state) || state == null)
            {
                return new GrokSessionTurnState();
            }
            return new GrokSessionTurnState
            {
                LastStartedAtUtc = state.LastStartedAtUtc,
                LastEndedAtUtc = state.LastEndedAtUtc
            };
        }

        private static int IntValue(Dictionary<string, object> dictionary, string key)
        {
            object value;
            if (dictionary == null || !dictionary.TryGetValue(key, out value) ||
                value == null)
            {
                return 0;
            }
            try
            {
                if (value is int)
                {
                    return (int)value;
                }
                if (value is long)
                {
                    return (int)(long)value;
                }
                if (value is double)
                {
                    return (int)(double)value;
                }
                if (value is decimal)
                {
                    return (int)(decimal)value;
                }
                int parsed;
                if (Int32.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                    NumberStyles.Any, CultureInfo.InvariantCulture, out parsed))
                {
                    return parsed;
                }
            }
            catch
            {
            }
            return 0;
        }

        public static GrokSessionTurnEndOutcome ParseOutcome(string raw)
        {
            if (String.IsNullOrEmpty(raw))
            {
                return GrokSessionTurnEndOutcome.Other;
            }
            switch (raw.Trim().ToLowerInvariant())
            {
                case "completed":
                case "complete":
                case "success":
                case "ok":
                    return GrokSessionTurnEndOutcome.Completed;
                case "cancelled":
                case "canceled":
                case "interrupted":
                case "aborted":
                    return GrokSessionTurnEndOutcome.Cancelled;
                case "error":
                case "failed":
                case "failure":
                    return GrokSessionTurnEndOutcome.Failed;
                default:
                    return GrokSessionTurnEndOutcome.Other;
            }
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

        private static string NestedStringValue(
            Dictionary<string, object> dictionary,
            string parentKey,
            string childKey)
        {
            object parent;
            if (dictionary == null ||
                !dictionary.TryGetValue(parentKey, out parent) ||
                parent == null)
            {
                return String.Empty;
            }
            Dictionary<string, object> nested =
                parent as Dictionary<string, object>;
            if (nested == null)
            {
                // JavaScriptSerializer may yield Dictionary<string, object> via
                // nested objects; also accept IDictionary-like forms.
                System.Collections.IDictionary idict =
                    parent as System.Collections.IDictionary;
                if (idict == null || !idict.Contains(childKey) ||
                    idict[childKey] == null)
                {
                    return String.Empty;
                }
                return Convert.ToString(idict[childKey], CultureInfo.InvariantCulture)
                    ?? String.Empty;
            }
            return StringValue(nested, childKey);
        }
    }

    public sealed class GrokActiveSessionRef
    {
        public string SessionId;
        public string WorkingDirectory;
        public int ProcessId;
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
            return LiveSessions(home).Count > 0;
        }

        public static HashSet<string> LiveSessionIds(string home)
        {
            HashSet<string> result = new HashSet<string>(
                StringComparer.OrdinalIgnoreCase);
            foreach (GrokActiveSessionRef session in LiveSessions(home))
            {
                result.Add(session.SessionId);
            }
            return result;
        }

        public static List<GrokActiveSessionRef> LiveSessions(string home)
        {
            try
            {
                List<GrokActiveSessionRef> sessions = Read(home);
                if (sessions.Count == 0)
                {
                    return sessions;
                }
                List<GrokActiveSessionRef> withPid = sessions
                    .Where(delegate(GrokActiveSessionRef s)
                    {
                        return s.ProcessId > 0;
                    }).ToList();
                // No pids present → every entry counts (older file shapes).
                if (withPid.Count == 0)
                {
                    return sessions;
                }
                return withPid.Where(delegate(GrokActiveSessionRef session)
                {
                    return IsProcessAlive(session.ProcessId);
                }).ToList();
            }
            catch
            {
                return new List<GrokActiveSessionRef>();
            }
        }

        private static List<GrokActiveSessionRef> Read(string home)
        {
            List<GrokActiveSessionRef> result = new List<GrokActiveSessionRef>();
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
                    GrokActiveSessionRef entry = ParseEntry(
                        item as Dictionary<string, object>);
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
                        GrokActiveSessionRef entry =
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

        private static GrokActiveSessionRef ParseEntry(
            Dictionary<string, object> entry)
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
            return new GrokActiveSessionRef
            {
                SessionId = sessionId,
                WorkingDirectory = FirstString(entry, "cwd",
                    "working_directory", "workingDirectory"),
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

    }

    /// <summary>
    /// Live Grok Build session context occupancy from the session store.
    /// End-of-turn occupancy lives in
    /// %USERPROFILE%\.grok\sessions\&lt;percent-encoded-cwd&gt;\&lt;sessionId&gt;\signals.json.
    /// During a long turn those fields freeze, so the reader also tails
    /// updates.jsonl for streaming params._meta.totalTokens.
    /// </summary>
    public sealed class GrokSessionContextSnapshot
    {
        public string SessionId;
        public double ContextUsedPercent;
        public long? ContextTokensUsed;
        public long? ContextWindowTokens;
        public string ModelName;
        public string ProjectName;
        public string SessionTitle;
        public string WorkingDirectory;
    }

    public sealed class GrokSessionContextReader
    {
        /// <summary>
        /// How much of the (often multi-MB) updates.jsonl to scan for the latest
        /// totalTokens. Large enough for a long tool/thought burst, small enough
        /// for the details refresh path.
        /// </summary>
        private const int UpdatesTailByteLimit = 256 * 1024;

        /// <summary>
        /// Grok Build commonly reports a 500k window in signals.json. Used when a
        /// brand-new session has live totalTokens but no end-of-turn signals yet
        /// (parity with macOS GrokSessionContextReader.defaultContextWindowTokens).
        /// </summary>
        public const long DefaultContextWindowTokens = 500000L;

        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();

        private readonly string sessionsRoot;

        public GrokSessionContextReader()
            : this(DefaultSessionsRoot())
        {
        }

        public GrokSessionContextReader(string sessionsRoot)
        {
            this.sessionsRoot = sessionsRoot ?? String.Empty;
        }

        public static string DefaultSessionsRoot()
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".grok", "sessions");
        }

        /// <summary>
        /// Grok stores workspace folders as fully percent-encoded absolute paths
        /// (every / becomes %2F), matching Python urllib.parse.quote(path, safe="")
        /// and macOS CharacterSet unreserved (alphanumerics + -._~).
        /// Uri.EscapeDataString is the .NET equivalent.
        /// </summary>
        public static string EncodeWorkspaceDirectory(string cwd)
        {
            if (String.IsNullOrEmpty(cwd))
            {
                return cwd ?? String.Empty;
            }
            return Uri.EscapeDataString(cwd);
        }

        /// <summary>
        /// Read context occupancy for an exact session id.
        /// When <paramref name="cwd"/> is present, resolves the percent-encoded
        /// session directory without scanning.
        /// </summary>
        public GrokSessionContextSnapshot Read(string sessionId, string cwd)
        {
            if (String.IsNullOrEmpty(sessionId))
            {
                return null;
            }
            string sessionDirectory = ResolveSessionDirectory(sessionId, cwd);
            if (String.IsNullOrEmpty(sessionDirectory))
            {
                return null;
            }
            return ReadFromSessionDirectory(sessionId, sessionDirectory);
        }

        private GrokSessionContextSnapshot ReadFromSessionDirectory(
            string sessionId, string sessionDirectory)
        {
            // signals.json is end-of-turn only. New sessions and long mid-turn
            // windows may have only streaming updates.jsonl totalTokens — still
            // enough to drive the context pill (macOS parity).
            Dictionary<string, object> signalsRoot =
                LoadJsonObject(Path.Combine(sessionDirectory, "signals.json"));
            long? liveTokens = LatestLiveContextTokens(sessionDirectory);

            long? tokensUsed = signalsRoot == null
                ? null : AsInt64(Get(signalsRoot, "contextTokensUsed"));
            long? windowTokens = signalsRoot == null
                ? null : AsInt64(Get(signalsRoot, "contextWindowTokens"));
            double? percent = signalsRoot == null
                ? null : ContextUsedPercent(signalsRoot);
            string modelName = signalsRoot == null
                ? null : AsString(Get(signalsRoot, "primaryModelId"));

            if (liveTokens.HasValue && liveTokens.Value >= 0)
            {
                tokensUsed = liveTokens;
                long window = (windowTokens.HasValue && windowTokens.Value > 0)
                    ? windowTokens.Value
                    : DefaultContextWindowTokens;
                windowTokens = window;
                percent = Math.Min(100, Math.Max(0,
                    liveTokens.Value * 100.0 / window));
            }

            if (!percent.HasValue)
            {
                return null;
            }

            string sessionTitle = null;
            string workingDirectory = null;
            string projectName = null;

            Dictionary<string, object> summary =
                LoadJsonObject(Path.Combine(sessionDirectory, "summary.json"));
            if (summary != null)
            {
                if (String.IsNullOrEmpty(modelName))
                {
                    modelName = AsString(Get(summary, "current_model_id"));
                }
                sessionTitle = FirstNonEmpty(
                    AsString(Get(summary, "generated_title")),
                    AsString(Get(summary, "session_summary")));
                Dictionary<string, object> info =
                    Get(summary, "info") as Dictionary<string, object>;
                if (info != null)
                {
                    workingDirectory = AsString(Get(info, "cwd"));
                }
                if (String.IsNullOrEmpty(workingDirectory))
                {
                    workingDirectory = AsString(
                        Get(summary, "working_directory"));
                }
            }

            if (!String.IsNullOrEmpty(workingDirectory))
            {
                string trimmed = workingDirectory.TrimEnd(
                    Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string leaf = Path.GetFileName(trimmed);
                if (!String.IsNullOrEmpty(leaf))
                {
                    projectName = leaf;
                }
            }

            return new GrokSessionContextSnapshot
            {
                SessionId = sessionId,
                ContextUsedPercent = percent.Value,
                ContextTokensUsed = tokensUsed,
                ContextWindowTokens = windowTokens,
                ModelName = String.IsNullOrEmpty(modelName) ? null : modelName,
                ProjectName = projectName,
                SessionTitle = sessionTitle,
                WorkingDirectory = workingDirectory
            };
        }

        private string ResolveSessionDirectory(string sessionId, string cwd)
        {
            if (!String.IsNullOrEmpty(cwd))
            {
                string encoded = EncodeWorkspaceDirectory(cwd);
                string candidate = Path.Combine(sessionsRoot, encoded, sessionId);
                if (IsSessionDirectory(candidate))
                {
                    return candidate;
                }
            }

            if (!Directory.Exists(sessionsRoot))
            {
                return null;
            }
            try
            {
                foreach (string workspace in Directory.GetDirectories(sessionsRoot))
                {
                    string candidate = Path.Combine(workspace, sessionId);
                    if (IsSessionDirectory(candidate))
                    {
                        return candidate;
                    }
                }
            }
            catch
            {
            }
            return null;
        }

        /// <summary>
        /// Session dirs may exist with only live updates.jsonl / events.jsonl
        /// before the first end-of-turn signals.json is written.
        /// </summary>
        private static bool IsSessionDirectory(string path)
        {
            if (String.IsNullOrEmpty(path) || !Directory.Exists(path))
            {
                return false;
            }
            string[] markers = new string[]
            {
                "events.jsonl", "signals.json", "updates.jsonl",
                "summary.json", "chat_history.jsonl"
            };
            for (int i = 0; i < markers.Length; i++)
            {
                if (File.Exists(Path.Combine(path, markers[i])))
                {
                    return true;
                }
            }
            return false;
        }

        private static Dictionary<string, object> LoadJsonObject(string path)
        {
            if (!File.Exists(path))
            {
                return null;
            }
            try
            {
                return Serializer.DeserializeObject(File.ReadAllText(path,
                    Encoding.UTF8)) as Dictionary<string, object>;
            }
            catch
            {
                return null;
            }
        }

        private static double? ContextUsedPercent(Dictionary<string, object> root)
        {
            double? raw = AsDouble(Get(root, "contextWindowUsage"));
            if (raw.HasValue && raw.Value >= 0 && raw.Value <= 100)
            {
                return raw.Value;
            }
            double? used = AsDouble(Get(root, "contextTokensUsed"));
            double? window = AsDouble(Get(root, "contextWindowTokens"));
            if (used.HasValue && window.HasValue && window.Value > 0)
            {
                return Math.Min(100, Math.Max(0, used.Value * 100.0 / window.Value));
            }
            return null;
        }

        /// <summary>
        /// Tail-scan updates.jsonl for the newest params._meta.totalTokens.
        /// </summary>
        private long? LatestLiveContextTokens(string sessionDirectory)
        {
            string updatesPath = Path.Combine(sessionDirectory, "updates.jsonl");
            if (!File.Exists(updatesPath))
            {
                return null;
            }
            try
            {
                using (FileStream stream = new FileStream(updatesPath, FileMode.Open,
                    FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    long endOffset = stream.Length;
                    if (endOffset <= 0)
                    {
                        return null;
                    }
                    long startOffset = endOffset > UpdatesTailByteLimit
                        ? endOffset - UpdatesTailByteLimit : 0;
                    stream.Seek(startOffset, SeekOrigin.Begin);
                    int length = (int)(endOffset - startOffset);
                    byte[] bytes = new byte[length];
                    int read = stream.Read(bytes, 0, bytes.Length);
                    if (read <= 0)
                    {
                        return null;
                    }
                    string text = Encoding.UTF8.GetString(bytes, 0, read);
                    string[] lines = text.Split('\n');
                    int minIndex = startOffset > 0 ? 1 : 0;
                    for (int i = lines.Length - 1; i >= minIndex; i--)
                    {
                        string line = lines[i].TrimEnd('\r');
                        if (line.IndexOf("totalTokens", StringComparison.Ordinal) < 0)
                        {
                            continue;
                        }
                        long? tokens = TotalTokensFromJsonLine(line);
                        if (tokens.HasValue)
                        {
                            return tokens;
                        }
                    }
                }
            }
            catch
            {
            }
            return null;
        }

        private long? TotalTokensFromJsonLine(string line)
        {
            if (String.IsNullOrWhiteSpace(line))
            {
                return null;
            }
            try
            {
                Dictionary<string, object> root =
                    Serializer.DeserializeObject(line) as Dictionary<string, object>;
                if (root == null)
                {
                    return null;
                }
                Dictionary<string, object> paramsObj =
                    Get(root, "params") as Dictionary<string, object>;
                Dictionary<string, object> meta = paramsObj == null
                    ? null : Get(paramsObj, "_meta") as Dictionary<string, object>;
                double? raw = AsDouble(Get(meta, "totalTokens"));
                if (!raw.HasValue || raw.Value < 0)
                {
                    return null;
                }
                return (long)Math.Round(raw.Value);
            }
            catch
            {
                return null;
            }
        }

        private static object Get(Dictionary<string, object> dictionary, string key)
        {
            object value;
            return dictionary != null && dictionary.TryGetValue(key, out value)
                ? value : null;
        }

        private static double? AsDouble(object value)
        {
            if (value == null)
            {
                return null;
            }
            if (value is double)
            {
                return (double)value;
            }
            if (value is float)
            {
                return (float)value;
            }
            if (value is decimal)
            {
                return (double)(decimal)value;
            }
            if (value is int)
            {
                return (int)value;
            }
            if (value is long)
            {
                return (long)value;
            }
            if (value is short)
            {
                return (short)value;
            }
            double parsed;
            if (Double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                NumberStyles.Float, CultureInfo.InvariantCulture, out parsed))
            {
                return parsed;
            }
            return null;
        }

        private static long? AsInt64(object value)
        {
            double? number = AsDouble(value);
            if (!number.HasValue)
            {
                return null;
            }
            return (long)Math.Round(number.Value);
        }

        private static string AsString(object value)
        {
            if (value == null)
            {
                return null;
            }
            string text = Convert.ToString(value, CultureInfo.InvariantCulture);
            return String.IsNullOrEmpty(text) ? null : text;
        }

        private static string FirstNonEmpty(params string[] values)
        {
            if (values == null)
            {
                return null;
            }
            foreach (string value in values)
            {
                if (!String.IsNullOrEmpty(value))
                {
                    return value;
                }
            }
            return null;
        }
    }
}
