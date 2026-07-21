using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
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
        private readonly HashSet<string> activeToolIds;
        private int anonymousActiveTools;
        private bool currentTurnIsPlanMode;
        private bool planProposalSeen;
        private bool hasTotalUsage;
        private bool turnUsageBaselineKnown;
        private long totalInputTokens;
        private long totalCachedInputTokens;
        private long totalOutputTokens;
        private long turnBaselineInputTokens;
        private long turnBaselineCachedInputTokens;
        private long turnBaselineOutputTokens;

        public string FilePath { get; private set; }
        public SessionSnapshot Snapshot { get; private set; }

        public SessionTracker(string path)
        {
            FilePath = path;
            serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = Int32.MaxValue;
            pending = String.Empty;
            activeToolIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            Snapshot = new SessionSnapshot();
            Snapshot.ThreadId = ExtractThreadId(path);
            Snapshot.ProjectName = "Codex";
            Snapshot.WorkingDirectory = String.Empty;
            Snapshot.State = HaloState.Idle;
            Snapshot.Action = "Ready";
            Snapshot.LastEventUtc = File.GetLastWriteTimeUtc(path);
            Snapshot.Agent = AgentKind.Codex;
            Snapshot.TurnPhase = AgentTurnPhase.None;
            Snapshot.Activity = AgentActivityKind.None;
            Snapshot.EvidenceSource = AgentEvidenceSource.SessionJsonl;
            ReadMetadata();
            ReadInitialTail();
            FileInfo initialInfo = new FileInfo(path);
            observedWriteUtc = initialInfo.LastWriteTimeUtc;
            observedLength = initialInfo.Length;
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

        private bool HasActiveTools
        {
            get { return activeToolIds.Count > 0 || anonymousActiveTools > 0; }
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
                    UpdateFromTurnContext(payload);
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
                    string provider = GetString(payload, "model_provider");
                    if (!String.IsNullOrEmpty(provider))
                    {
                        Snapshot.ModelProvider = provider;
                    }
                    string model = GetString(payload, "model");
                    if (!String.IsNullOrEmpty(model))
                    {
                        Snapshot.ModelName = model;
                    }
                    return;
                }
                if (payload == null)
                {
                    return;
                }

                string payloadType = GetString(payload, "type");
                Snapshot.EvidenceSource = AgentEvidenceSource.SessionJsonl;
                Snapshot.EvidenceKind = payloadType;
                Snapshot.EvidenceId = GetToolId(payload);
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

        private void UpdateFromTurnContext(Dictionary<string, object> payload)
        {
            Dictionary<string, object> collaborationMode =
                GetDictionary(payload, "collaboration_mode");
            string mode = GetString(collaborationMode, "mode");
            if (String.Equals(mode, "plan", StringComparison.OrdinalIgnoreCase))
            {
                currentTurnIsPlanMode = true;
            }
            string model = GetString(payload, "model");
            if (!String.IsNullOrEmpty(model))
            {
                Snapshot.ModelName = model;
            }
            string cwd = GetString(payload, "cwd");
            if (!String.IsNullOrEmpty(cwd))
            {
                Snapshot.WorkingDirectory = cwd;
                string leaf = Path.GetFileName(cwd.TrimEnd(
                    Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                Snapshot.ProjectName = String.IsNullOrEmpty(leaf) ? cwd : leaf;
            }
        }

        private void ReduceEvent(string payloadType,
            Dictionary<string, object> payload, DateTime eventUtc)
        {
            string lower = (payloadType ?? String.Empty).ToLowerInvariant();
            if (GeneratedHaloSpec.IsTaskStartEvent(lower))
            {
                ClearActiveTools();
                StartTurnUsage();
                if (lower == "task_started" && IsPlanModePayload(payload))
                {
                    currentTurnIsPlanMode = true;
                }
                planProposalSeen = false;
                SetBusinessState(HaloState.Thinking, AgentTurnPhase.Thinking,
                    AgentActivityKind.Planning, "Planning", true);
            }
            else if (lower == "token_count")
            {
                UpdateTokenUsage(payload);
            }
            else if (GeneratedHaloSpec.IsTaskCompleteEvent(lower))
            {
                ClearActiveTools();
                if (currentTurnIsPlanMode && planProposalSeen)
                {
                    SetBusinessState(HaloState.Attention,
                        AgentTurnPhase.AwaitingUser, AgentActivityKind.None,
                        "Waiting for your choice", true,
                        AgentAttentionReason.PlanDecision);
                }
                else
                {
                    SetBusinessState(HaloState.Done, AgentTurnPhase.Completed,
                        AgentActivityKind.None, "Complete", false);
                }
                Snapshot.CompletedUtc = eventUtc == DateTime.MinValue ? DateTime.UtcNow : eventUtc;
                ClearPlanModeState();
            }
            else if (lower == "agent_message" || lower.EndsWith("_end"))
            {
                if (lower.EndsWith("_end") &&
                    GeneratedHaloSpec.IsExecutionLifecycleEvent(lower))
                {
                    CompleteTool(payload);
                }
                if (lower == "agent_message" && IsFinalAnswerPayload(payload))
                {
                    if (currentTurnIsPlanMode && ContainsProposedPlan(payload))
                    {
                        planProposalSeen = true;
                    }
                    SetBusinessState(HaloState.Working, AgentTurnPhase.Answering,
                        AgentActivityKind.WritingAnswer, "Writing answer", true);
                    return;
                }
                ApplyActiveThinkingOrWorking();
            }
            else if (GeneratedHaloSpec.IsAttentionEvent(lower))
            {
                SetBusinessState(HaloState.Attention, AgentTurnPhase.AwaitingUser,
                    AgentActivityKind.None, "Needs you", true,
                    AttentionReasonForEvent(lower));
            }
            else if (IsRecoverableToolFailureEvent(lower))
            {
                Snapshot.FailureSeverity = AgentFailureSeverity.RecoverableTool;
                if (Snapshot.Active && !HasActiveTools)
                {
                    Snapshot.State = HaloState.Thinking;
                    Snapshot.TurnPhase = AgentTurnPhase.Thinking;
                    Snapshot.Activity = AgentActivityKind.ReviewingResult;
                    Snapshot.Action = "Reviewing result";
                }
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
                ClearActiveTools();
                ClearPlanModeState();
                SetBusinessState(HaloState.Error, AgentTurnPhase.Failed,
                    AgentActivityKind.None, "Interrupted", false,
                    AgentAttentionReason.None, AgentFailureSeverity.FatalTurn);
            }
            else if ((lower.EndsWith("_begin") || lower.EndsWith("_start")) &&
                GeneratedHaloSpec.IsExecutionLifecycleEvent(lower))
            {
                string action = GeneratedHaloSpec.FriendlyAction(lower);
                SetBusinessState(HaloState.Working, AgentTurnPhase.Executing,
                    ActivityForTool(lower, action), action, true);
            }
        }

        private void StartTurnUsage()
        {
            turnUsageBaselineKnown = hasTotalUsage;
            turnBaselineInputTokens = totalInputTokens;
            turnBaselineCachedInputTokens = totalCachedInputTokens;
            turnBaselineOutputTokens = totalOutputTokens;
            Snapshot.TurnInputTokens = 0;
            Snapshot.TurnCachedInputTokens = 0;
            Snapshot.TurnOutputTokens = 0;
        }

        private void UpdateTokenUsage(Dictionary<string, object> payload)
        {
            Dictionary<string, object> info = GetDictionary(payload, "info");
            Dictionary<string, object> total = GetDictionary(info, "total_token_usage");
            Dictionary<string, object> last = GetDictionary(info, "last_token_usage");
            long nextInput = GetLong(total, "input_tokens", totalInputTokens);
            long nextCached = GetLong(total, "cached_input_tokens", totalCachedInputTokens);
            long nextOutput = GetLong(total, "output_tokens", totalOutputTokens);
            long lastInput = GetLong(last, "input_tokens", 0);
            long lastCached = GetLong(last, "cached_input_tokens", 0);
            long lastOutput = GetLong(last, "output_tokens", 0);

            if (total != null)
            {
                if (!turnUsageBaselineKnown)
                {
                    turnBaselineInputTokens = Math.Max(0, nextInput - lastInput);
                    turnBaselineCachedInputTokens = Math.Max(0, nextCached - lastCached);
                    turnBaselineOutputTokens = Math.Max(0, nextOutput - lastOutput);
                    turnUsageBaselineKnown = true;
                }
                totalInputTokens = nextInput;
                totalCachedInputTokens = nextCached;
                totalOutputTokens = nextOutput;
                hasTotalUsage = true;
                Snapshot.TurnInputTokens = Math.Max(0,
                    totalInputTokens - turnBaselineInputTokens);
                Snapshot.TurnCachedInputTokens = Math.Max(0,
                    totalCachedInputTokens - turnBaselineCachedInputTokens);
                Snapshot.TurnOutputTokens = Math.Max(0,
                    totalOutputTokens - turnBaselineOutputTokens);
            }
            else if (last != null)
            {
                Snapshot.TurnInputTokens = Math.Max(0, lastInput);
                Snapshot.TurnCachedInputTokens = Math.Max(0, lastCached);
                Snapshot.TurnOutputTokens = Math.Max(0, lastOutput);
            }

            if (last != null)
            {
                Snapshot.ContextInputTokens = Math.Max(0, lastInput);
            }
            Snapshot.ContextWindowTokens = Math.Max(0,
                GetLong(info, "model_context_window", Snapshot.ContextWindowTokens));
        }

        private void ReduceResponse(string payloadType, Dictionary<string, object> payload, DateTime eventUtc)
        {
            string lower = (payloadType ?? String.Empty).ToLowerInvariant();
            if (lower == "function_call" || lower == "custom_tool_call")
            {
                string name = GetString(payload, "name");
                if (IsAttentionFunctionCall(name, payload))
                {
                    SetBusinessState(HaloState.Attention,
                        AgentTurnPhase.AwaitingUser, AgentActivityKind.None,
                        "Needs you", true,
                        AttentionReasonForFunction(name, payload));
                }
                else
                {
                    RegisterTool(payload);
                    string action = GeneratedHaloSpec.FriendlyAction(name);
                    SetBusinessState(HaloState.Working,
                        AgentTurnPhase.Executing, ActivityForTool(name, action),
                        action, true);
                }
            }
            else if (lower == "message" && IsFinalAnswerPayload(payload))
            {
                if (currentTurnIsPlanMode && ContainsProposedPlan(payload))
                {
                    planProposalSeen = true;
                }
                SetBusinessState(HaloState.Working, AgentTurnPhase.Answering,
                    AgentActivityKind.WritingAnswer, "Writing answer", true);
            }
            else if (GeneratedHaloSpec.IsToolCall(lower) || lower.EndsWith("_call"))
            {
                RegisterTool(payload);
                string action = GeneratedHaloSpec.FriendlyAction(lower);
                SetBusinessState(HaloState.Working, AgentTurnPhase.Executing,
                    ActivityForTool(lower, action), action, true);
            }
            else if (GeneratedHaloSpec.IsToolOutput(lower) || lower.EndsWith("_output"))
            {
                bool toolFailed = IsToolFailurePayload(payload);
                CompleteTool(payload);
                if (Snapshot.Active)
                {
                    if (HasActiveTools)
                    {
                        SetBusinessState(HaloState.Working,
                            AgentTurnPhase.Executing, AgentActivityKind.UsingTool,
                            "Using tools", true);
                    }
                    else
                    {
                        SetBusinessState(HaloState.Thinking,
                            AgentTurnPhase.Thinking,
                            AgentActivityKind.ReviewingResult,
                            "Reviewing result", true);
                    }
                    if (toolFailed)
                    {
                        Snapshot.FailureSeverity = AgentFailureSeverity.RecoverableTool;
                    }
                }
            }
            else if (lower == "reasoning")
            {
                ApplyActiveThinkingOrWorking();
            }
        }

        private void ApplyActiveThinkingOrWorking()
        {
            if (!Snapshot.Active)
            {
                return;
            }
            if (HasActiveTools)
            {
                SetBusinessState(HaloState.Working, AgentTurnPhase.Executing,
                    AgentActivityKind.UsingTool, Snapshot.Action, true);
            }
            else
            {
                SetBusinessState(HaloState.Thinking, AgentTurnPhase.Thinking,
                    AgentActivityKind.Reasoning, "Thinking", true);
            }
        }

        private void SetBusinessState(HaloState state, AgentTurnPhase turnPhase,
            AgentActivityKind activity, string action, bool active,
            AgentAttentionReason attentionReason = AgentAttentionReason.None,
            AgentFailureSeverity failureSeverity = AgentFailureSeverity.None)
        {
            Snapshot.State = state;
            Snapshot.TurnPhase = turnPhase;
            Snapshot.Activity = activity;
            Snapshot.Action = action;
            Snapshot.Active = active;
            Snapshot.AttentionReason = attentionReason;
            Snapshot.FailureSeverity = failureSeverity;
        }

        private static bool IsRecoverableToolFailureEvent(string eventType)
        {
            string lower = (eventType ?? String.Empty).ToLowerInvariant();
            return lower.Contains("tool_failed") || lower.Contains("tool_failure") ||
                lower.Contains("function_call_failed");
        }

        private static bool IsToolFailurePayload(Dictionary<string, object> payload)
        {
            string status = GetString(payload, "status");
            string isError = GetString(payload, "is_error");
            return String.Equals(status, "failed", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(isError, "true", StringComparison.OrdinalIgnoreCase);
        }

        private static AgentAttentionReason AttentionReasonForEvent(string eventType)
        {
            string lower = (eventType ?? String.Empty).ToLowerInvariant();
            if (lower.Contains("approval")) return AgentAttentionReason.Approval;
            if (lower.Contains("permission")) return AgentAttentionReason.Permission;
            return AgentAttentionReason.UserInput;
        }

        private static AgentAttentionReason AttentionReasonForFunction(string name,
            Dictionary<string, object> payload)
        {
            string lower = (name ?? String.Empty).ToLowerInvariant();
            if (lower.Contains("approval")) return AgentAttentionReason.Approval;
            if (lower.Contains("permission")) return AgentAttentionReason.Permission;
            if (lower.Contains("exec") || lower.Contains("command") ||
                lower.Contains("shell"))
                return AgentAttentionReason.CommandConfirmation;
            if (IsEscalatedCommandArguments(GetString(payload, "arguments")))
                return AgentAttentionReason.CommandConfirmation;
            return AgentAttentionReason.UserInput;
        }

        private void RegisterTool(Dictionary<string, object> payload)
        {
            string status = GetString(payload, "status");
            if (String.Equals(status, "completed", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(status, "failed", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
            string id = GetToolId(payload);
            if (String.IsNullOrEmpty(id))
            {
                anonymousActiveTools++;
            }
            else
            {
                activeToolIds.Add(id);
            }
        }

        private void CompleteTool(Dictionary<string, object> payload)
        {
            string id = GetToolId(payload);
            if (!String.IsNullOrEmpty(id))
            {
                activeToolIds.Remove(id);
                return;
            }
            if (anonymousActiveTools > 0)
            {
                anonymousActiveTools--;
            }
            else if (String.IsNullOrEmpty(id) && activeToolIds.Count == 1)
            {
                activeToolIds.Clear();
            }
        }

        private void ClearActiveTools()
        {
            activeToolIds.Clear();
            anonymousActiveTools = 0;
        }

        private static string GetToolId(Dictionary<string, object> payload)
        {
            string id = GetString(payload, "call_id");
            if (String.IsNullOrEmpty(id)) id = GetString(payload, "item_id");
            if (String.IsNullOrEmpty(id)) id = GetString(payload, "id");
            return id;
        }

        private static AgentActivityKind ActivityForTool(string tool,
            string action)
        {
            string value = ((tool ?? String.Empty) + " " +
                (action ?? String.Empty)).ToLowerInvariant();
            if (value.Contains("apply_patch") || value.Contains("edit") ||
                value.Contains("write")) return AgentActivityKind.EditingFiles;
            if (value.Contains("shell") || value.Contains("command") ||
                value.Contains("exec")) return AgentActivityKind.RunningCommand;
            if (value.Contains("search") || value.Contains("browser"))
                return AgentActivityKind.Searching;
            return AgentActivityKind.UsingTool;
        }

        private void ClearPlanModeState()
        {
            currentTurnIsPlanMode = false;
            planProposalSeen = false;
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

        private static bool IsAttentionFunctionCall(string name,
            Dictionary<string, object> payload)
        {
            if (String.Equals(name, "request_user_input",
                StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            string lowerName = (name ?? String.Empty).ToLowerInvariant();
            if (lowerName.IndexOf("approval", StringComparison.OrdinalIgnoreCase) >= 0 ||
                lowerName.IndexOf("permission", StringComparison.OrdinalIgnoreCase) >= 0 ||
                lowerName.IndexOf("request_user", StringComparison.OrdinalIgnoreCase) >= 0 ||
                lowerName.IndexOf("needs_input", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return true;
            }
            string arguments = GetString(payload, "arguments");
            return IsEscalatedCommandArguments(arguments);
        }

        private static bool IsEscalatedCommandArguments(string arguments)
        {
            return !String.IsNullOrEmpty(arguments) &&
                arguments.IndexOf("require_escalated", StringComparison.OrdinalIgnoreCase) >= 0 &&
                (arguments.IndexOf("sandbox_permissions", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 arguments.IndexOf("justification", StringComparison.OrdinalIgnoreCase) >= 0);
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

        private static long GetLong(Dictionary<string, object> dictionary,
            string key, long fallback)
        {
            object value;
            if (dictionary == null || !dictionary.TryGetValue(key, out value) ||
                value == null)
            {
                return fallback;
            }
            try
            {
                return Convert.ToInt64(value, CultureInfo.InvariantCulture);
            }
            catch
            {
                return fallback;
            }
        }
    }

public sealed class CodexSessionMonitor : IDisposable
    {
        private readonly string root;
        private readonly Dictionary<string, SessionTracker> trackers;
        private readonly CodexRealtimeActivityReader realtimeActivity;
        private readonly bool realtimeEnabled;
        private readonly HashSet<string> pendingSessionPaths;
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
        private FileSystemWatcher sessionWatcher;

        public event EventHandler Changed;

        public CodexSessionMonitor()
            : this(Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile), ".codex", "sessions"), true)
        {
        }

        internal CodexSessionMonitor(string sessionsRoot, bool enableRealtime)
        {
            root = sessionsRoot;
            realtimeEnabled = enableRealtime;
            trackers = new Dictionary<string, SessionTracker>(StringComparer.OrdinalIgnoreCase);
            realtimeActivity = new CodexRealtimeActivityReader();
            pendingSessionPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            realtimeAction = String.Empty;
            dispatcher = Dispatcher.CurrentDispatcher;
            sync = new object();
            timer = new System.Threading.Timer(OnTick, null,
                Timeout.Infinite, Timeout.Infinite);
        }

        public void Start()
        {
            lock (sync)
            {
                EnsureSessionWatcher();
            }
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
                    EnsureSessionWatcher();
                    if (DrainPendingSessions())
                    {
                        changed = true;
                    }
                    if ((DateTime.UtcNow - lastDiscoveryUtc).TotalSeconds >= 30)
                    {
                        changed = Discover() || changed;
                    }
                    foreach (SessionTracker tracker in trackers.Values.ToList())
                    {
                        if (File.Exists(tracker.FilePath) && tracker.Refresh())
                        {
                            changed = true;
                        }
                    }
                    if (realtimeEnabled && DateTime.UtcNow >= nextRealtimePollUtc)
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

        private void EnsureSessionWatcher()
        {
            if (sessionWatcher != null || !Directory.Exists(root))
            {
                return;
            }
            try
            {
                sessionWatcher = new FileSystemWatcher(root, "*.jsonl");
                sessionWatcher.IncludeSubdirectories = true;
                sessionWatcher.NotifyFilter = NotifyFilters.FileName |
                    NotifyFilters.LastWrite | NotifyFilters.Size;
                sessionWatcher.Created += OnSessionFileChanged;
                sessionWatcher.Changed += OnSessionFileChanged;
                sessionWatcher.Renamed += delegate(object sender,
                    RenamedEventArgs args) { QueueSessionPath(args.FullPath); };
                sessionWatcher.EnableRaisingEvents = true;
            }
            catch (Exception ex)
            {
                if (sessionWatcher != null)
                {
                    sessionWatcher.Dispose();
                    sessionWatcher = null;
                }
                SettingsStorage.Log("Session watcher failed: " + ex.Message);
            }
        }

        private void OnSessionFileChanged(object sender, FileSystemEventArgs args)
        {
            QueueSessionPath(args.FullPath);
        }

        private void QueueSessionPath(string path)
        {
            if (String.IsNullOrEmpty(path) ||
                !path.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
            lock (sync)
            {
                pendingSessionPaths.Add(path);
            }
        }

        private bool DrainPendingSessions()
        {
            if (pendingSessionPaths.Count == 0)
            {
                return false;
            }
            bool changed = false;
            List<string> paths = pendingSessionPaths.ToList();
            pendingSessionPaths.Clear();
            foreach (string path in paths)
            {
                if (!File.Exists(path))
                {
                    if (trackers.Remove(path)) changed = true;
                    continue;
                }
                if (!trackers.ContainsKey(path))
                {
                    trackers[path] = new SessionTracker(path);
                    changed = true;
                }
            }
            return changed;
        }

        public AggregateSnapshot GetAggregate(HaloSettings settings)
        {
            return GetAggregate(settings, CodexRuntimeReader.IsRunning());
        }

        internal AggregateSnapshot GetAggregate(HaloSettings settings,
            bool codexRunning)
        {
            lock (sync)
            {
                DateTime now = DateTime.UtcNow;
                List<SessionSnapshot> rawSessions = trackers.Values
                .Select(delegate(SessionTracker tracker)
                {
                    return CloneSnapshot(tracker.Snapshot);
                })
                .ToList();
                List<SessionSnapshot> sessions = WithoutSupersededErrors(rawSessions)
                .Where(delegate(SessionSnapshot snapshot)
                {
                    return IsSessionVisible(snapshot, settings, codexRunning, now);
                })
                .OrderBy(delegate(SessionSnapshot snapshot) { return StatePriority(snapshot.State); })
                .ThenByDescending(delegate(SessionSnapshot snapshot) { return snapshot.LastEventUtc; })
                .ToList();

                AggregateSnapshot result = new AggregateSnapshot();
                result.Sessions = sessions;
                result.FocusedAgent = AgentKind.Codex;
                result.Presence = codexRunning
                    ? AgentPresenceState.Standby : AgentPresenceState.Offline;
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
                if (codexRunning && hasRealtimeActivity && !hasBlockingState)
                {
                    SessionSnapshot current = sessions.FirstOrDefault();
                    result.State = realtimeState;
                    result.Label = StateLabel(realtimeState);
                    result.Detail = (current == null ? "Codex" : current.ProjectName) +
                        " · " + realtimeAction;
                    result.AnswerStreaming = realtimeAnswerStreaming;
                    result.Presence = AgentPresenceState.Active;
                    result.TurnPhase = PhaseForState(realtimeState);
                    result.Activity = ActivityForRealtime(realtimeAction);
                    result.EvidenceSource = AgentEvidenceSource.DiagnosticSqlite;
                    result.EvidenceKind = realtimeAction;
                    result.AttentionReason = realtimeState == HaloState.Attention
                        ? AgentAttentionReason.UserInput : AgentAttentionReason.None;
                    return result;
                }
                if (sessions.Count == 0)
                {
                    if (codexRunning)
                    {
                        result.State = HaloState.Done;
                        result.Label = "STANDBY";
                        result.Detail = L10n.Instance["status.standby_codex"];
                        result.Presence = AgentPresenceState.Standby;
                    }
                    else
                    {
                        result.State = HaloState.Idle;
                        result.Label = StateLabel(HaloState.Idle);
                        result.Detail = "Codex is not running";
                        result.Presence = AgentPresenceState.Offline;
                    }
                    result.TurnPhase = AgentTurnPhase.None;
                    result.Activity = AgentActivityKind.None;
                    result.EvidenceSource = AgentEvidenceSource.Process;
                    result.EvidenceKind = codexRunning
                        ? "process_running" : "process_stopped";
                    return result;
                }

                SessionSnapshot primary = sessions[0];
                result.State = primary.State;
                result.Label = StateLabel(primary.State);
                result.Detail = sessions.Count == 1
                    ? primary.ProjectName + " · " + primary.Action
                    : primary.ProjectName + " +" +
                        (sessions.Count - 1).ToString(CultureInfo.InvariantCulture);
                result.Presence = primary.Active
                    ? AgentPresenceState.Active
                    : (codexRunning ? AgentPresenceState.Standby : AgentPresenceState.Offline);
                result.TurnPhase = primary.TurnPhase;
                result.Activity = primary.Activity;
                result.EvidenceSource = primary.EvidenceSource;
                result.EvidenceKind = primary.EvidenceKind;
                result.AttentionReason = primary.AttentionReason;
                result.FailureSeverity = primary.FailureSeverity;
                return result;
            }
        }

        internal static bool IsSessionVisible(SessionSnapshot snapshot,
            HaloSettings settings, bool codexRunning, DateTime now)
        {
            if (snapshot.State == HaloState.Done)
            {
                return snapshot.CompletedUtc > settings.GetAcknowledgedUtc(snapshot.ThreadId) &&
                    snapshot.CompletedUtc >= settings.GetInstalledUtc() &&
                    snapshot.CompletedUtc >= now.AddDays(-1);
            }
            if (snapshot.Active)
            {
                return codexRunning && snapshot.LastEventUtc >= now.AddMinutes(-10);
            }
            return snapshot.State == HaloState.Error &&
                snapshot.LastEventUtc >= now.AddHours(-12);
        }

        private static AgentTurnPhase PhaseForState(HaloState state)
        {
            switch (state)
            {
                case HaloState.Thinking: return AgentTurnPhase.Thinking;
                case HaloState.Working: return AgentTurnPhase.Executing;
                case HaloState.Attention: return AgentTurnPhase.AwaitingUser;
                case HaloState.Done: return AgentTurnPhase.Completed;
                case HaloState.Error: return AgentTurnPhase.Failed;
                default: return AgentTurnPhase.None;
            }
        }

        private static AgentActivityKind ActivityForRealtime(string action)
        {
            string value = (action ?? String.Empty).ToLowerInvariant();
            if (value.Contains("compressing")) return AgentActivityKind.CompactingContext;
            if (value.Contains("answer") || value.Contains("response"))
                return AgentActivityKind.WritingAnswer;
            if (value.Contains("editing")) return AgentActivityKind.EditingFiles;
            if (value.Contains("command")) return AgentActivityKind.RunningCommand;
            if (value.Contains("search")) return AgentActivityKind.Searching;
            return AgentActivityKind.UsingTool;
        }

        internal static List<SessionSnapshot> WithoutSupersededErrors(
            IEnumerable<SessionSnapshot> snapshots)
        {
            List<SessionSnapshot> all = snapshots.ToList();
            return all.Where(delegate(SessionSnapshot snapshot)
            {
                if (snapshot.State != HaloState.Error)
                {
                    return true;
                }
                return !all.Any(delegate(SessionSnapshot candidate)
                {
                    bool meaningful = candidate.Active ||
                        candidate.State == HaloState.Done ||
                        candidate.State == HaloState.Error;
                    return candidate.Agent == snapshot.Agent &&
                        !String.Equals(candidate.ThreadId, snapshot.ThreadId,
                            StringComparison.OrdinalIgnoreCase) &&
                        meaningful && candidate.LastEventUtc > snapshot.LastEventUtc;
                });
            }).ToList();
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
                Active = snapshot.Active,
                Agent = snapshot.Agent,
                TurnPhase = snapshot.TurnPhase,
                Activity = snapshot.Activity,
                EvidenceSource = snapshot.EvidenceSource,
                EvidenceKind = snapshot.EvidenceKind,
                EvidenceId = snapshot.EvidenceId,
                AttentionReason = snapshot.AttentionReason,
                FailureSeverity = snapshot.FailureSeverity,
                ModelName = snapshot.ModelName,
                ModelProvider = snapshot.ModelProvider,
                TurnInputTokens = snapshot.TurnInputTokens,
                TurnCachedInputTokens = snapshot.TurnCachedInputTokens,
                TurnOutputTokens = snapshot.TurnOutputTokens,
                ContextInputTokens = snapshot.ContextInputTokens,
                ContextWindowTokens = snapshot.ContextWindowTokens
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
            FileSystemWatcher watcher;
            lock (sync)
            {
                watcher = sessionWatcher;
                sessionWatcher = null;
            }
            if (watcher != null)
            {
                watcher.EnableRaisingEvents = false;
                watcher.Dispose();
            }
        }
    }

public sealed class CodexRealtimeActivityReader
    {
        private readonly JavaScriptSerializer serializer;

        public CodexRealtimeActivityReader()
        {
            serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = Int32.MaxValue;
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
            long cutoff = DateTimeOffset.UtcNow.AddMinutes(-5).ToUnixTimeSeconds();
            string query = "select feedback_log_body from logs where ts >= " +
                cutoff.ToString(CultureInfo.InvariantCulture) +
                " and target='codex_api::sse::responses' and " +
                "feedback_log_body like 'SSE event: {\"type\":\"response.%' " +
                "order by id desc limit 96;";
            List<string> rows = CodexSQLiteLogStore.Shared.QueryText(query);
            return FindActive(rows, out state, out action, out answerStreaming);
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
            bool hasArgumentActivity = false;
            bool hasAttentionArgumentActivity = false;
            HashSet<string> completed = new HashSet<string>(
                StringComparer.OrdinalIgnoreCase);
            foreach (string body in newestFirst)
            {
                string eventType;
                string itemId;
                string itemType;
                string name;
                bool attentionHint;
                if (!TryParseToolEvent(body, out eventType, out itemId,
                    out itemType, out name, out attentionHint))
                {
                    continue;
                }
                if (eventType == "response.output_text.delta")
                {
                    state = HaloState.Working;
                    if (IsContextCompressionEvent(body))
                    {
                        action = "Compressing context";
                    }
                    else
                    {
                        action = "Generating response";
                    }
                    answerStreaming = false;
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
                if (eventType == "response.function_call_arguments.delta" ||
                    eventType == "response.function_call_arguments.done")
                {
                    if (completed.Contains(itemId))
                    {
                        continue;
                    }
                    hasArgumentActivity = true;
                    if (attentionHint)
                    {
                        hasAttentionArgumentActivity = true;
                    }
                    continue;
                }
                if (eventType != "response.output_item.added" ||
                    completed.Contains(itemId))
                {
                    continue;
                }
                if (String.Equals(name, "request_user_input",
                    StringComparison.OrdinalIgnoreCase) || IsAttentionToolName(name))
                {
                    state = HaloState.Attention;
                    action = "Needs you";
                }
                else
                {
                    state = HaloState.Working;
                    action = itemType == "message"
                        ? "Generating response"
                        : GeneratedHaloSpec.FriendlyAction(
                            String.IsNullOrEmpty(name) ? itemType : name);
                }
                return true;
            }
            if (hasAttentionArgumentActivity)
            {
                state = HaloState.Attention;
                action = "Needs you";
                return true;
            }
            if (hasArgumentActivity)
            {
                state = HaloState.Working;
                action = "Preparing command";
                return true;
            }
            return false;
        }

        private bool TryParseToolEvent(string body, out string eventType,
            out string itemId, out string itemType, out string name,
            out bool attentionHint)
        {
            eventType = String.Empty;
            itemId = String.Empty;
            itemType = String.Empty;
            name = String.Empty;
            attentionHint = false;
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
                if (eventType == "response.function_call_arguments.delta" ||
                    eventType == "response.function_call_arguments.done")
                {
                    itemId = ReadString(root, "item_id");
                    string delta = ReadString(root, "delta");
                    attentionHint = IsEscalatedArgumentsFragment(delta) ||
                        IsEscalatedArgumentsFragment(body);
                    return !String.IsNullOrEmpty(itemId);
                }
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

        private static bool IsAttentionToolName(string name)
        {
            string lower = (name ?? String.Empty).ToLowerInvariant();
            return lower == "request_user_input" ||
                lower.IndexOf("approval", StringComparison.OrdinalIgnoreCase) >= 0 ||
                lower.IndexOf("permission", StringComparison.OrdinalIgnoreCase) >= 0 ||
                lower.IndexOf("request_user", StringComparison.OrdinalIgnoreCase) >= 0 ||
                lower.IndexOf("needs_input", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static bool IsEscalatedArgumentsFragment(string value)
        {
            return !String.IsNullOrEmpty(value) &&
                value.IndexOf("require_escalated", StringComparison.OrdinalIgnoreCase) >= 0 &&
                (value.IndexOf("sandbox_permissions", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 value.IndexOf("justification", StringComparison.OrdinalIgnoreCase) >= 0);
        }

        private static bool IsContextCompressionEvent(string value)
        {
            if (String.IsNullOrEmpty(value))
            {
                return false;
            }
            return value.IndexOf("compressing context", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("compress context", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("compacting context", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("compact context", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("context compaction", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("summarizing conversation", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("summarizing context", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("压缩上下文", StringComparison.OrdinalIgnoreCase) >= 0 ||
                value.IndexOf("正在压缩", StringComparison.OrdinalIgnoreCase) >= 0;
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

    }

public static class CodexRuntimeReader
    {
        public static bool IsRunning()
        {
            try
            {
                if (Process.GetProcessesByName("Codex").Length > 0 ||
                    Process.GetProcessesByName("codex").Length > 0)
                {
                    return true;
                }
                foreach (Process process in Process.GetProcesses())
                {
                    try
                    {
                        string name = process.ProcessName;
                        if (!String.IsNullOrEmpty(name) &&
                            name.IndexOf("codex", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            return true;
                        }
                    }
                    catch
                    {
                    }
                }
            }
            catch
            {
            }
            return false;
        }
    }

public static class CodexFailureReader
    {
        public static bool TryReadRecent(out string detail, out DateTime eventUtc)
        {
            detail = null;
            eventUtc = DateTime.MinValue;
            long cutoff = DateTimeOffset.UtcNow.AddMinutes(-2).ToUnixTimeSeconds();
            string query = "select ts || char(9) || replace(replace(" +
                "coalesce(feedback_log_body,''),char(10),' '),char(13),' ') from logs " +
                "where ts >= " + cutoff.ToString(CultureInfo.InvariantCulture) +
                " and lower(level)='error' and (" +
                "lower(target) like '%client%' or lower(target) like '%auth%' or " +
                "lower(target) like '%response%' or lower(target) like '%session%') " +
                "order by id desc limit 24;";
            foreach (string line in CodexSQLiteLogStore.Shared.QueryText(query))
            {
                int tab = line.IndexOf('\t');
                if (tab <= 0) continue;
                long seconds;
                if (!long.TryParse(line.Substring(0, tab), out seconds)) continue;
                string matched = GeneratedHaloSpec.ClassifyFailure(
                    line.Substring(tab + 1));
                if (matched == null) continue;
                detail = L10n.Instance[matched];
                eventUtc = DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime;
                return true;
            }
            return false;
        }
    }

public static class RateLimitReader
    {
        public static bool TryRead(out double fiveHourUsed, out double weeklyUsed)
        {
            UsageMetrics metrics;
            bool result = TryRead(out metrics);
            fiveHourUsed = metrics.FiveHourUsedPercent;
            weeklyUsed = metrics.WeeklyUsedPercent;
            return result && metrics.HasFiveHour && metrics.HasWeekly;
        }

        public static bool TryReadMonthly(out double monthlyUsed)
        {
            UsageMetrics metrics;
            bool result = TryRead(out metrics);
            monthlyUsed = metrics.MonthlyUsedPercent;
            return result && metrics.HasMonthly;
        }

        // This reader is the passive JSONL fallback for quota and the source of
        // context-window usage. CodexUsageMonitor now obtains current quota from
        // the OAuth usage endpoint independently of conversation activity.
        //
        // Codex persists rate_limits to disk ONLY as a by-product of a conversation
        // turn — the server attaches them to the response that Codex writes into the
        // session jsonl. Agent Halo is purely passive here; it does not call any
        // Codex/OpenAI API, so it can only see what Codex chose to write down.
        //
        // logs_2.sqlite (the codex_client::transport / sse logs) was investigated as
        // an additional, possibly conversation-independent source and rejected:
        //   - The rows matching "rate_limits" are false positives — they are
        //     conversation bodies that happen to quote Agent Halo's own source/spec
        //     text, not structured quota payloads. There are zero rows with a real
        //     top-level "rate_limits": { ... } JSON object.
        //   - The few genuine-looking fragments (e.g. `primary = {"used_percent":...}`)
        //     are embedded inside chat content and are themselves conversation-triggered,
        //     so they do not solve the "no quota until you talk to Codex" case anyway.
        //
        // If OAuth access is unavailable or the endpoint fails, these snapshots
        // keep the panel useful without turning SQLite chat-content matches into
        // false structured quota records.
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
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                serializer.MaxJsonLength = Int32.MaxValue;
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
                        ApplyRateLimitLine(lines[index], metrics, serializer);
                        if (HasCompleteMetrics(metrics))
                        {
                            return true;
                        }
                    }
                }
            }
            catch
            {
            }
            return metrics.HasFiveHour || metrics.HasWeekly || metrics.HasMonthly ||
                metrics.HasContext;
        }

        internal static bool TryReadFromNewestLinesForTest(
            IEnumerable<string> newestFirst, out UsageMetrics metrics)
        {
            metrics = new UsageMetrics
            {
                ContextInputTokens = -1
            };
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = Int32.MaxValue;
            foreach (string line in newestFirst)
            {
                if (String.IsNullOrEmpty(line) ||
                    !line.Contains(GeneratedHaloSpec.RateLimitMarker))
                {
                    continue;
                }
                ApplyRateLimitLine(line, metrics, serializer);
                if (HasCompleteMetrics(metrics))
                {
                    return true;
                }
            }
            return metrics.HasFiveHour || metrics.HasWeekly || metrics.HasMonthly ||
                metrics.HasContext;
        }

        private static bool HasCompleteMetrics(UsageMetrics metrics)
        {
            return metrics.HasContext && metrics.HasWeekly;
        }

        private static void ApplyRateLimitLine(string line, UsageMetrics metrics,
            JavaScriptSerializer serializer)
        {
            object parsed = serializer.DeserializeObject(line);
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
            Dictionary<string, object> monthly = FindMonthlyLimit(limits);
            if (!metrics.HasMonthly && monthly != null)
            {
                ApplyMonthly(metrics, monthly);
            }
            Dictionary<string, object> weekly = FindNamedLimit(limits,
                "weekly", "week", "weekly_usage", "weekly_quota");
            if (!metrics.HasWeekly && weekly != null)
            {
                ApplyWeekly(metrics, weekly);
            }
            bool primaryLooksMonthly = primary != null && secondary == null &&
                LooksLikeMonthlyLimit(primary, limits);
            if (!metrics.HasMonthly && primaryLooksMonthly)
            {
                ApplyMonthly(metrics, primary);
            }
            ApplyClassifiedWindow(metrics, primary, primaryLooksMonthly);
            ApplyClassifiedWindow(metrics, secondary, false);
            Dictionary<string, object> lastUsage = Child(info, "last_token_usage");
            if (!metrics.HasContext && lastUsage != null && info != null &&
                lastUsage.ContainsKey("input_tokens") &&
                info.ContainsKey("model_context_window"))
            {
                metrics.ContextInputTokens = Convert.ToInt64(
                    lastUsage["input_tokens"], CultureInfo.InvariantCulture);
                metrics.ContextWindowTokens = Convert.ToInt64(
                    info["model_context_window"], CultureInfo.InvariantCulture);
            }
        }

        private static Dictionary<string, object> FindMonthlyLimit(
            Dictionary<string, object> limits)
        {
            if (limits == null)
            {
                return null;
            }
            string[] keys = { "monthly", "month", "monthly_usage", "monthly_quota" };
            foreach (string key in keys)
            {
                Dictionary<string, object> child = Child(limits, key);
                if (child != null)
                {
                    return child;
                }
            }
            Dictionary<string, object> credits = Child(limits, "credits");
            if (credits != null && HasAnyNumber(credits,
                "used_percent", "remaining_percent", "resets_at"))
            {
                return credits;
            }
            return null;
        }

        private static Dictionary<string, object> FindNamedLimit(
            Dictionary<string, object> limits, params string[] keys)
        {
            if (limits == null)
            {
                return null;
            }
            foreach (string key in keys)
            {
                Dictionary<string, object> child = Child(limits, key);
                if (child != null)
                {
                    return child;
                }
            }
            return null;
        }

        private static void ApplyClassifiedWindow(UsageMetrics metrics,
            Dictionary<string, object> source, bool alreadyClassifiedAsMonthly)
        {
            if (source == null || alreadyClassifiedAsMonthly)
            {
                return;
            }
            double minutes;
            if (!TryWindowMinutes(source, out minutes))
            {
                return;
            }
            if (Math.Abs(minutes - GeneratedHaloSpec.RateFiveHourWindowMinutes) < 0.5)
            {
                if (!metrics.HasFiveHour)
                {
                    metrics.FiveHourUsedPercent = UsedPercent(source);
                    metrics.FiveHourResetUtc = UnixTime(source, "resets_at");
                    metrics.HasFiveHour = true;
                }
                return;
            }
            if (Math.Abs(minutes - GeneratedHaloSpec.RateWeeklyWindowMinutes) < 0.5)
            {
                if (!metrics.HasWeekly)
                {
                    ApplyWeekly(metrics, source);
                }
                return;
            }
            if (minutes >= GeneratedHaloSpec.RateMonthlyMinimumWindowMinutes &&
                !metrics.HasMonthly)
            {
                ApplyMonthly(metrics, source);
            }
        }

        private static bool TryWindowMinutes(Dictionary<string, object> source,
            out double minutes)
        {
            minutes = 0;
            object value;
            return source != null &&
                source.TryGetValue(GeneratedHaloSpec.RateWindowMinutesKey, out value) &&
                value != null && Double.TryParse(
                    Convert.ToString(value, CultureInfo.InvariantCulture),
                    NumberStyles.Float, CultureInfo.InvariantCulture, out minutes);
        }

        private static bool LooksLikeMonthlyLimit(Dictionary<string, object> limit,
            Dictionary<string, object> limits)
        {
            if (limit == null)
            {
                return false;
            }
            double minutes;
            if (TryWindowMinutes(limit, out minutes))
            {
                return minutes >= GeneratedHaloSpec.RateMonthlyMinimumWindowMinutes;
            }
            string plan = Convert.ToString(Value(limits, "plan_type"),
                CultureInfo.InvariantCulture);
            string name = Convert.ToString(Value(limits, "limit_name"),
                CultureInfo.InvariantCulture);
            string combined = (plan + " " + name).ToLowerInvariant();
            return combined.IndexOf("monthly", StringComparison.OrdinalIgnoreCase) >= 0 ||
                combined.IndexOf("month", StringComparison.OrdinalIgnoreCase) >= 0 ||
                combined.IndexOf("free", StringComparison.OrdinalIgnoreCase) >= 0 ||
                combined.IndexOf("basic", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static void ApplyMonthly(UsageMetrics metrics,
            Dictionary<string, object> source)
        {
            metrics.MonthlyUsedPercent = UsedPercent(source);
            metrics.MonthlyResetUtc = UnixTime(source, "resets_at");
            metrics.HasMonthly = true;
        }

        private static void ApplyWeekly(UsageMetrics metrics,
            Dictionary<string, object> source)
        {
            metrics.WeeklyUsedPercent = UsedPercent(source);
            metrics.WeeklyResetUtc = UnixTime(source, "resets_at");
            metrics.HasWeekly = true;
        }

        private static double Number(Dictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value)
                ? Convert.ToDouble(value, CultureInfo.InvariantCulture) : 0;
        }

        private static double UsedPercent(Dictionary<string, object> source)
        {
            if (HasAnyNumber(source, GeneratedHaloSpec.RateUsedPercentKey))
            {
                return Number(source, GeneratedHaloSpec.RateUsedPercentKey);
            }
            if (HasAnyNumber(source, "remaining_percent"))
            {
                return 100 - Number(source, "remaining_percent");
            }
            return 0;
        }

        private static bool HasAnyNumber(Dictionary<string, object> source,
            params string[] keys)
        {
            if (source == null)
            {
                return false;
            }
            foreach (string key in keys)
            {
                object value;
                double parsed;
                if (source.TryGetValue(key, out value) && value != null &&
                    Double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                        NumberStyles.Float, CultureInfo.InvariantCulture, out parsed))
                {
                    return true;
                }
            }
            return false;
        }

        private static object Value(Dictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value) ? value : null;
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
