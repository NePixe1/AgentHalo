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
public static class Diagnostics
    {
        public static int WritePiRuntimeSnapshot(string outputPath)
        {
            try
            {
                PiRuntimeMonitor monitor = new PiRuntimeMonitor();
                monitor.Refresh();
                SessionSnapshot snapshot = monitor.Snapshot();
                Dictionary<string, object> result = new Dictionary<string, object>();
                result["running"] = monitor.IsRunning;
                result["session_id"] = snapshot == null ? null : snapshot.ThreadId;
                result["project"] = snapshot == null ? null : snapshot.ProjectName;
                result["evidence"] = snapshot == null ? null : snapshot.EvidenceKind;
                result["model"] = snapshot == null ? null : snapshot.ModelName;
                result["provider"] = snapshot == null ? null : snapshot.ModelProvider;
                result["input_tokens"] = snapshot == null ? 0 : snapshot.TurnInputTokens;
                result["output_tokens"] = snapshot == null ? 0 : snapshot.TurnOutputTokens;
                result["context_tokens"] = snapshot == null ? 0 :
                    snapshot.ContextInputTokens;
                result["context_window"] = snapshot == null ? 0 :
                    snapshot.ContextWindowTokens;
                File.WriteAllText(outputPath,
                    new JavaScriptSerializer().Serialize(result),
                    new UTF8Encoding(false));
                return monitor.IsRunning ? 0 : 2;
            }
            catch (Exception ex)
            {
                File.WriteAllText(outputPath, "{\"running\":false,\"detail\":\"" +
                    EscapeJson(ex.GetType().Name) + "\"}", new UTF8Encoding(false));
                return 1;
            }
        }

        public static int WriteCodexUsageSnapshot(string outputPath)
        {
            CodexUsageMonitor monitor = null;
            try
            {
                UsageFocusGate.Activate(AgentKind.Codex);
                monitor = CodexUsageMonitor.Instance;
                monitor.SetActive(true);
                monitor.RequestRefreshForTest();
                DateTime deadline = DateTime.UtcNow.AddSeconds(20);
                while (monitor.IsRefreshing && DateTime.UtcNow < deadline)
                {
                    Thread.Sleep(100);
                }
                UsageMetrics metrics;
                monitor.TryRead(out metrics);
                Dictionary<string, object> result = new Dictionary<string, object>();
                result["status"] = monitor.Status.ToString();
                result["has_five_hour"] = metrics != null && metrics.HasFiveHour;
                result["has_weekly"] = metrics != null && metrics.HasWeekly;
                result["has_context"] = metrics != null && metrics.HasContext;
                if (metrics != null && metrics.HasFiveHour)
                {
                    result["five_hour_used_percent"] = metrics.FiveHourUsedPercent;
                    result["five_hour_resets_at"] = Iso(metrics.FiveHourResetUtc);
                }
                if (metrics != null && metrics.HasWeekly)
                {
                    result["weekly_used_percent"] = metrics.WeeklyUsedPercent;
                    result["weekly_resets_at"] = Iso(metrics.WeeklyResetUtc);
                }
                if (metrics != null && metrics.HasContext)
                {
                    result["context_used_percent"] = metrics.ContextUsedPercent;
                }
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                File.WriteAllText(outputPath, serializer.Serialize(result),
                    new UTF8Encoding(false));
                return monitor.Status == CodexUsageDataStatus.Fresh ? 0 : 2;
            }
            catch (Exception ex)
            {
                File.WriteAllText(outputPath, "{\"status\":\"Error\",\"detail\":\"" +
                    EscapeJson(ex.GetType().Name) + "\"}", new UTF8Encoding(false));
                return 1;
            }
            finally
            {
                UsageFocusGate.DeactivateAll();
                if (monitor != null)
                {
                    monitor.SetActive(false);
                }
            }
        }

        private static string Iso(DateTime value)
        {
            return value == DateTime.MinValue ? String.Empty :
                value.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
        }

        private static string EscapeJson(string value)
        {
            return (value ?? String.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"");
        }

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
                    id + "\",\"cwd\":\"C:\\\\work\\\\halo\",\"model_provider\":\"ccswitch\"}}");
                lines.Add("{\"timestamp\":\"" + now +
                    "\",\"type\":\"turn_context\",\"payload\":{\"cwd\":\"C:\\\\work\\\\halo\"," +
                    "\"model\":\"glm-5.2\",\"collaboration_mode\":{\"mode\":\"default\"}}}");
                lines.Add("{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}");
                lines.Add("{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"shell_command\"}}");
                lines.Add("{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{" +
                    "\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":400,\"output_tokens\":80}," +
                    "\"last_token_usage\":{\"input_tokens\":200,\"cached_input_tokens\":100,\"output_tokens\":20}," +
                    "\"model_context_window\":200000}}}");
                File.WriteAllLines(temp, lines.ToArray(), Encoding.UTF8);
                SessionTracker tracker = new SessionTracker(temp);
                Assert(tracker.Snapshot.ProjectName == "halo", "project metadata");
                Assert(tracker.Snapshot.State == HaloState.Working, "function call -> working");
                Assert(tracker.Snapshot.ModelName == "glm-5.2" &&
                    tracker.Snapshot.ModelProvider == "ccswitch",
                    "Codex model and provider metadata");
                Assert(tracker.Snapshot.TurnInputTokens == 200 &&
                    tracker.Snapshot.TurnCachedInputTokens == 100 &&
                    tracker.Snapshot.TurnOutputTokens == 20,
                    "Codex first turn token sample");
                Assert(tracker.Snapshot.ContextInputTokens == 200 &&
                    tracker.Snapshot.ContextWindowTokens == 200000,
                    "Codex context token sample");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{" +
                    "\"total_token_usage\":{\"input_tokens\":1600,\"cached_input_tokens\":700,\"output_tokens\":120}," +
                    "\"last_token_usage\":{\"input_tokens\":600,\"cached_input_tokens\":300,\"output_tokens\":40}," +
                    "\"model_context_window\":200000}}}\n", Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.TurnInputTokens == 800 &&
                    tracker.Snapshot.TurnCachedInputTokens == 400 &&
                    tracker.Snapshot.TurnOutputTokens == 60,
                    "Codex turn tokens use cumulative delta");

                CodexProviderProfile customProfile = new CodexProviderProfile
                {
                    Model = "glm-5.2",
                    ProviderId = "ccswitch",
                    ProviderName = "Custom Provider",
                    BaseUrl = "http://127.0.0.1:8317/v1",
                    IsCustomApi = true
                };
                CodexCustomApiMetrics customMetrics = CodexCustomApiMetricsReader.Read(
                    new List<SessionSnapshot> { tracker.Snapshot }, customProfile,
                    CodexUsageDataStatus.Fresh);
                Assert(customMetrics.IsCustomApi && customMetrics.Model == "glm-5.2" &&
                    customMetrics.ProjectName == "halo" &&
                    customMetrics.InputTokens == 800 && customMetrics.OutputTokens == 60,
                    "Codex custom API metrics use session metadata");
                CodexProviderProfile officialProfile = new CodexProviderProfile
                {
                    ProviderId = "openai",
                    BaseUrl = "https://api.openai.com/v1"
                };
                SessionSnapshot officialSnapshot = new SessionSnapshot
                {
                    Agent = AgentKind.Codex,
                    ModelProvider = "openai",
                    ModelName = "gpt-5.6-sol"
                };
                Assert(!CodexCustomApiMetricsReader.Read(
                    new List<SessionSnapshot> { officialSnapshot }, officialProfile,
                    CodexUsageDataStatus.Fresh).IsCustomApi,
                    "official OAuth remains quota mode");
                Assert(CodexCustomApiMetricsReader.Read(
                    new List<SessionSnapshot> { officialSnapshot }, officialProfile,
                    CodexUsageDataStatus.ApiKey).IsCustomApi,
                    "API key auth uses custom API panel");

                string configTemp = Path.Combine(Path.GetTempPath(),
                    "agent-halo-codex-config-" + Guid.NewGuid().ToString("N") + ".toml");
                File.WriteAllText(configTemp,
                    "model = \"deepseek-v4\"\nmodel_provider = \"ccswitch\"\n" +
                    "[model_providers.ccswitch]\nname = \"Private API\"\n" +
                    "base_url = \"http://127.0.0.1:8317/v1\"\n",
                    new UTF8Encoding(false));
                CodexProviderProfile parsedProfile = CodexProviderProfileReader.Read(configTemp);
                File.Delete(configTemp);
                Assert(parsedProfile.IsCustomApi && parsedProfile.Model == "deepseek-v4" &&
                    parsedProfile.ProviderName == "Private API",
                    "Codex custom provider config detection");

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
                Assert(tracker.Snapshot.State == HaloState.Thinking,
                    "tool output returns business state to thinking immediately");
                Assert(tracker.Snapshot.TurnPhase == AgentTurnPhase.Thinking &&
                    tracker.Snapshot.Activity == AgentActivityKind.ReviewingResult,
                    "tool output records reviewing-result business dimensions");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\"," +
                    "\"call_id\":\"tool-a\",\"name\":\"shell_command\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\"," +
                    "\"call_id\":\"tool-b\",\"name\":\"apply_patch\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\"," +
                    "\"call_id\":\"tool-a\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working,
                    "one completed parallel tool does not close another active tool");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working,
                    "reasoning does not override a different active tool id");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\"," +
                    "\"call_id\":\"tool-b\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Thinking,
                    "last parallel tool completion returns to thinking");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"reasoning_start\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Thinking,
                    "generic reasoning_start is not misclassified as tool execution");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"tool_failed\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Thinking &&
                    tracker.Snapshot.FailureSeverity ==
                        AgentFailureSeverity.RecoverableTool,
                    "recoverable tool failure does not become fatal error");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\"," +
                    "\"name\":\"apply_patch\",\"status\":\"completed\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working,
                    "custom tool call -> working");
                Assert(tracker.Snapshot.Action == "Editing files",
                    "apply_patch shows editing action");

                CodexRealtimeActivityReader realtime =
                    new CodexRealtimeActivityReader();
                string realtimeAdded =
                    "SSE event: {\"type\":\"response.output_item.added\",\"item\":{" +
                    "\"id\":\"ctc-test\",\"type\":\"custom_tool_call\"," +
                    "\"status\":\"in_progress\",\"name\":\"apply_patch\"}}";
                string realtimeDone =
                    "SSE event: {\"type\":\"response.output_item.done\",\"item\":{" +
                    "\"id\":\"ctc-test\",\"type\":\"custom_tool_call\"," +
                    "\"status\":\"completed\",\"name\":\"apply_patch\"}}";
                HaloState realtimeState;
                string realtimeAction;
                bool answerStreaming;
                string realtimeThreadId;
                string prefixedRealtimeAdded =
                    "session_loop{thread_id=thread-live}:turn: " + realtimeAdded;
                Assert(realtime.FindActive(new[] { prefixedRealtimeAdded },
                    out realtimeState, out realtimeAction, out answerStreaming,
                    out realtimeThreadId) &&
                    String.Equals(realtimeThreadId, "thread-live",
                        StringComparison.Ordinal),
                    "live activity keeps its Codex thread id");
                Assert(realtime.FindActive(new[] { realtimeAdded },
                    out realtimeState, out realtimeAction) &&
                    realtimeState == HaloState.Working &&
                    realtimeAction == "Editing files",
                    "live apply_patch start -> working");
                Assert(!realtime.FindActive(new[] { realtimeDone, realtimeAdded },
                    out realtimeState, out realtimeAction),
                    "live apply_patch done clears realtime working");
                string realtimeMessageAdded =
                    "SSE event: {\"type\":\"response.output_item.added\",\"item\":{" +
                    "\"id\":\"msg-test\",\"type\":\"message\",\"status\":\"in_progress\"}}";
                string realtimeMessageDone =
                    "SSE event: {\"type\":\"response.output_item.done\",\"item\":{" +
                    "\"id\":\"msg-test\",\"type\":\"message\",\"status\":\"completed\"}}";
                Assert(realtime.FindActive(new[] { realtimeMessageAdded },
                    out realtimeState, out realtimeAction) &&
                    realtimeState == HaloState.Working &&
                    realtimeAction == "Generating response",
                    "live unphased message -> generic working response");
                Assert(!realtime.FindActive(new[] { realtimeMessageDone, realtimeMessageAdded },
                    out realtimeState, out realtimeAction),
                    "live final answer done clears realtime working");
                string realtimeTextDelta =
                    "SSE event: {\"type\":\"response.output_text.delta\"," +
                    "\"delta\":\"hello\"}";
                string realtimeTextDone =
                    "SSE event: {\"type\":\"response.output_text.done\"}";
                string realtimeCompleted =
                    "SSE event: {\"type\":\"response.completed\",\"response\":{" +
                    "\"id\":\"resp-test\"}}";
                Assert(realtime.FindActive(new[] { realtimeTextDelta },
                    out realtimeState, out realtimeAction, out answerStreaming) &&
                    realtimeState == HaloState.Working &&
                    realtimeAction == "Generating response" &&
                    !answerStreaming,
                    "live text delta -> working without answer streaming");
                string realtimeContextCompactDelta =
                    "SSE event: {\"type\":\"response.output_text.delta\"," +
                    "\"delta\":\"Compressing context\"}";
                Assert(realtime.FindActive(new[] { realtimeContextCompactDelta },
                    out realtimeState, out realtimeAction, out answerStreaming) &&
                    realtimeState == HaloState.Working &&
                    realtimeAction == "Compressing context" &&
                    !answerStreaming,
                    "live context compact delta -> working without answer streaming");
                Assert(!realtime.FindActive(new[] { realtimeCompleted, realtimeTextDelta },
                    out realtimeState, out realtimeAction, out answerStreaming),
                    "live response completed clears realtime working");
                Assert(!realtime.FindActive(new[] { realtimeTextDone, realtimeTextDelta },
                    out realtimeState, out realtimeAction, out answerStreaming),
                    "live text done clears realtime working");
                string realtimeInputAdded =
                    "SSE event: {\"type\":\"response.output_item.added\",\"item\":{" +
                    "\"id\":\"input-test\",\"type\":\"function_call\"," +
                    "\"status\":\"in_progress\",\"name\":\"request_user_input\"}}";
                Assert(realtime.FindActive(new[] { realtimeInputAdded },
                    out realtimeState, out realtimeAction) &&
                    realtimeState == HaloState.Attention,
                    "live request_user_input -> attention");
                string realtimeArgumentsDelta =
                    "SSE event: {\"type\":\"response.function_call_arguments.delta\"," +
                    "\"item_id\":\"fc-test\",\"delta\":\"{\\\"cmd\\\":\\\"git\"}";
                string realtimeArgumentsDone =
                    "SSE event: {\"type\":\"response.function_call_arguments.done\"," +
                    "\"item_id\":\"fc-test\"}";
                string realtimeFunctionDone =
                    "SSE event: {\"type\":\"response.output_item.done\",\"item\":{" +
                    "\"id\":\"fc-test\",\"type\":\"function_call\"," +
                    "\"status\":\"completed\",\"name\":\"exec_command\"}}";
                Assert(realtime.FindActive(new[] { realtimeArgumentsDelta },
                    out realtimeState, out realtimeAction) &&
                    realtimeState == HaloState.Working,
                    "live function argument stream keeps Codex active");
                Assert(!realtime.FindActive(new[] { realtimeFunctionDone,
                    realtimeArgumentsDone, realtimeArgumentsDelta },
                    out realtimeState, out realtimeAction),
                    "live function argument stream clears after item done");
                string realtimeEscalatedArguments =
                    "SSE event: {\"type\":\"response.function_call_arguments.delta\"," +
                    "\"item_id\":\"fc-approval\",\"delta\":\"require_escalated sandbox_permissions justification\"}";
                Assert(realtime.FindActive(new[] { realtimeEscalatedArguments },
                    out realtimeState, out realtimeAction) &&
                    realtimeState == HaloState.Attention,
                    "live escalated command arguments -> attention");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call_output\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Thinking,
                    "completed custom tool returns business state to thinking");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\"," +
                    "\"name\":\"request_user_input\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention &&
                    tracker.Snapshot.AttentionReason == AgentAttentionReason.UserInput,
                    "request_user_input -> attention");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\"," +
                    "\"name\":\"exec_command\",\"arguments\":\"{" +
                    "\\\"sandbox_permissions\\\":\\\"require_escalated\\\"," +
                    "\\\"justification\\\":\\\"approve\\\"}\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention &&
                    tracker.Snapshot.AttentionReason ==
                        AgentAttentionReason.CommandConfirmation,
                    "escalated exec command -> attention, got " +
                    tracker.Snapshot.State + " / " + tracker.Snapshot.AttentionReason +
                    " / " + tracker.Snapshot.Action);

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"approval_requested\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention &&
                    tracker.Snapshot.AttentionReason == AgentAttentionReason.Approval,
                    "approval request -> attention");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_failed\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Error &&
                    tracker.Snapshot.FailureSeverity == AgentFailureSeverity.FatalTurn,
                    "terminal turn failure -> error");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\"," +
                    "\"role\":\"assistant\",\"phase\":\"final_answer\"," +
                    "\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working &&
                    tracker.Snapshot.Action == "Writing answer" &&
                    tracker.Snapshot.TurnPhase == AgentTurnPhase.Answering,
                    "normal final answer outputs as working");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\"," +
                    "\"phase\":\"final_answer\",\"message\":\"done\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working &&
                    tracker.Snapshot.Action == "Writing answer",
                    "final answer agent message outputs as working");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Done, "task complete -> done");
                Assert(!tracker.Snapshot.Active, "task complete deactivates session");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"," +
                    "\"collaboration_mode_kind\":\"plan\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Thinking,
                    "plan task starts thinking");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\"," +
                    "\"role\":\"assistant\",\"phase\":\"final_answer\"," +
                    "\"content\":[{\"type\":\"output_text\",\"text\":\"plain answer\"}]}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working,
                    "plain plan final answer outputs as working, got " +
                    tracker.Snapshot.State + " / " + tracker.Snapshot.Action);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Done &&
                    !tracker.Snapshot.Active,
                    "plain plan complete becomes done");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"," +
                    "\"collaboration_mode_kind\":\"plan\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\"," +
                    "\"role\":\"assistant\",\"phase\":\"final_answer\"," +
                    "\"content\":[{\"type\":\"output_text\",\"text\":\"<proposed_plan>\"}]}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working &&
                    tracker.Snapshot.Action == "Writing answer",
                    "plan final answer outputs as working");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention &&
                    tracker.Snapshot.Active,
                    "plan complete waits for user choice");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"turn_context\",\"payload\":{\"collaboration_mode\":{" +
                    "\"mode\":\"plan\"}}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\"," +
                    "\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\"," +
                    "\"text\":\"<proposed_plan>\"}]}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention,
                    "turn_context plan task complete -> attention");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"," +
                    "\"collaboration_mode_kind\":\"plan\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Done,
                    "plan without final answer -> done");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"," +
                    "\"collaboration_mode_kind\":\"plan\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\"," +
                    "\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\"," +
                    "\"text\":\"<proposed_plan>\"}]}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention,
                    "plan round 1 attention");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Done,
                    "plan flag resets across turns");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"," +
                    "\"collaboration_mode_kind\":\"plan\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\"," +
                    "\"item\":{\"type\":\"Plan\",\"text\":\"Plan body\"}}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention,
                    "completed plan item waits for user choice");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"," +
                    "\"collaboration_mode_kind\":\"plan\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_failed\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Error,
                    "plan fatal turn -> error");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Done,
                    "fatal turn clears plan flag");
                Assert(GeneratedHaloSpec.ContractVersion == 2,
                    "generated shared contract version");
                Assert(GeneratedHaloSpec.ReleaseVersion == "1.0.0",
                    "generated shared release version");
                Assert(GeneratedHaloSpec.State(HaloState.Attention).Label == "NEEDS YOU",
                    "generated state labels");
                Assert(GeneratedHaloSpec.FriendlyAction("apply_patch") == "Editing files",
                    "generated action rules");
                Assert(GeneratedHaloSpec.ClassifyFailure("server overloaded") ==
                    "failure.service_unavailable", "generated failure rules");
                L10n.Instance.SetLanguage("zh");
                HaloWindow.ConfigureLocalization(new HaloSettings { Language = "en" });
                Assert(L10n.Instance.CurrentLanguage == "en",
                    "saved Windows language initializes L10n before UI text is built");
                Assert(L10n.Instance.Format("quota.remaining", 92) == "92% left",
                    "English quota remaining copy");
                Assert(L10n.Instance.Format("quota.resets", "Aug 2") == "Resets Aug 2",
                    "English quota reset copy");
                Assert(HaloWindow.IsLanguageMenuItemChecked(null, null),
                    "auto language item is checked when preference follows system");
                Assert(!HaloWindow.IsLanguageMenuItemChecked("en", null),
                    "resolved system language does not check explicit English item");
                Assert(HaloWindow.IsLanguageMenuItemChecked("en", "en"),
                    "explicit English language item is checked when preference is English");
                L10n.Instance.SetLanguage("zh");
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
                Assert(HaloVisual.DiagnosticAttentionPulse(0.54) > 0.88,
                    "attention first pulse is clearly visible");
                Assert(HaloVisual.DiagnosticAttentionPulse(1.24) > 0.70,
                    "attention second pulse is visible and softer");
                Assert(HaloVisual.DiagnosticAttentionPulse(2.55) < 0.24,
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
                Assert(Math.Abs(HaloWindow.DiagnosticSizeForScale(150) - 112) < 0.001,
                    "removed 150 percent size falls back to 100 percent");
                Assert(Math.Abs(HaloWindow.DiagnosticSizeForScale(99) - 112) < 0.001,
                    "invalid halo size falls back to 100 percent");
                List<System.Drawing.Rectangle> displayAreas =
                    new List<System.Drawing.Rectangle>
                    {
                        new System.Drawing.Rectangle(0, 0, 1920, 1040),
                        new System.Drawing.Rectangle(1920, 0, 2560, 1400)
                    };
                Assert(HaloWindow.DiagnosticIsFrameVisible(
                    new System.Drawing.Rectangle(1800, 900, 112, 112), displayAreas),
                    "on-screen halo remains visible");
                Assert(HaloWindow.DiagnosticIsFrameVisible(
                    new System.Drawing.Rectangle(4440, 1300, 112, 112), displayAreas),
                    "partially visible halo remains visible");
                Assert(!HaloWindow.DiagnosticIsFrameVisible(
                    new System.Drawing.Rectangle(4600, 1500, 112, 112), displayAreas),
                    "off-screen halo requires recovery");
                MediaColor workingBlue = HaloVisual.StateColor(HaloState.Working);
                MediaColor completedGreen = HaloVisual.StateColor(HaloState.Done);
                Assert(ColorSaturation(workingBlue) >=
                    ColorSaturation(completedGreen) - 0.02,
                    "Windows execution blue matches completed green saturation");
                using (Forms.ContextMenuStrip menu = new Forms.ContextMenuStrip())
                {
                    Forms.ToolStripMenuItem checkedItem =
                        new Forms.ToolStripMenuItem("始终置顶");
                    checkedItem.Checked = true;
                    menu.Items.Add(checkedItem);
                    Win11MenuRenderer.Apply(menu);
                    Assert(menu.Renderer is Win11MenuRenderer,
                        "Windows 11 menu renderer is applied");
                    Assert(checkedItem.Padding.Left == 8 &&
                        checkedItem.Padding.Top == 6,
                        "Windows 11 menu items use compact inset padding");
                }
                UsageMetrics usage = new UsageMetrics
                {
                    ContextInputTokens = 202600,
                    ContextWindowTokens = 258400
                };
                Assert(Math.Abs(usage.ContextUsedPercent - 78.405) < 0.01,
                    "context uses latest input tokens rather than cumulative usage");
                DateTime localReset = DateTime.Today.AddHours(14).AddMinutes(58);
                Assert(DetailsWindow.FormatResetTime(localReset.ToUniversalTime()) ==
                    "14:58 刷新", "same-day quota reset formatting");
                Assert(String.IsNullOrEmpty(DetailsWindow.FormatResetTime(
                    DateTime.MinValue)), "missing reset time stays hidden");
                Assert(DetailsWindow.IsQuotaExpired(
                    DateTime.UtcNow.AddSeconds(-1), DateTime.UtcNow),
                    "expired quota snapshot is stale");
                Assert(!DetailsWindow.IsQuotaExpired(
                    DateTime.UtcNow.AddMinutes(5), DateTime.UtcNow),
                    "future quota reset remains valid");
                string contextOnlyRate =
                    "{\"payload\":{\"info\":{\"rate_limits\":{}," +
                    "\"last_token_usage\":{\"input_tokens\":50}," +
                    "\"model_context_window\":100}}}";
                string quotaOnlyRate =
                    "{\"payload\":{\"info\":{\"rate_limits\":{\"primary\":{" +
                    "\"used_percent\":25,\"window_minutes\":300," +
                    "\"resets_at\":4102444800}," +
                    "\"secondary\":{\"used_percent\":40,\"window_minutes\":10080," +
                    "\"resets_at\":4102444800}}}}}";
                UsageMetrics parsedUsage;
                Assert(RateLimitReader.TryReadFromNewestLinesForTest(
                    new[] { contextOnlyRate, quotaOnlyRate }, out parsedUsage),
                    "rate limit parser reads split snapshots");
                Assert(parsedUsage.HasFiveHour && parsedUsage.HasWeekly &&
                    parsedUsage.HasContext, "rate limit parser fills all fields");
                Assert(Math.Abs(parsedUsage.FiveHourUsedPercent - 25) < 0.001 &&
                    Math.Abs(parsedUsage.WeeklyUsedPercent - 40) < 0.001 &&
                    Math.Abs(parsedUsage.ContextUsedPercent - 50) < 0.001,
                    "rate limit parser preserves latest field values");
                string weeklyOnlyRate =
                    "{\"payload\":{\"info\":{\"rate_limits\":{\"primary\":{" +
                    "\"used_percent\":0,\"window_minutes\":10080," +
                    "\"resets_at\":4102444800},\"secondary\":null}," +
                    "\"last_token_usage\":{\"input_tokens\":10}," +
                    "\"model_context_window\":100}}}";
                Assert(RateLimitReader.TryReadFromNewestLinesForTest(
                    new[] { weeklyOnlyRate }, out parsedUsage) &&
                    parsedUsage.HasWeekly && !parsedUsage.HasFiveHour &&
                    Math.Abs(parsedUsage.WeeklyUsedPercent) < 0.001,
                    "single primary 10080-minute window is weekly, not five-hour");
                string monthlyRate =
                    "{\"payload\":{\"info\":{\"rate_limits\":{\"monthly\":{" +
                    "\"used_percent\":37,\"resets_at\":4102444800}}," +
                    "\"last_token_usage\":{\"input_tokens\":25}," +
                    "\"model_context_window\":100}}}";
                Assert(RateLimitReader.TryReadFromNewestLinesForTest(
                    new[] { monthlyRate }, out parsedUsage),
                    "rate limit parser reads monthly quota");
                Assert(parsedUsage.HasMonthly && !parsedUsage.HasFiveHour &&
                    !parsedUsage.HasWeekly &&
                    Math.Abs(parsedUsage.MonthlyUsedPercent - 37) < 0.001,
                    "monthly quota stays separate from Plus buckets");
                string longPrimaryRate =
                    "{\"payload\":{\"info\":{\"rate_limits\":{\"primary\":{" +
                    "\"used_percent\":41,\"window_minutes\":43200," +
                    "\"resets_at\":4102444800}}}}}";
                Assert(RateLimitReader.TryReadFromNewestLinesForTest(
                    new[] { longPrimaryRate }, out parsedUsage) &&
                    parsedUsage.HasMonthly &&
                    Math.Abs(parsedUsage.MonthlyUsedPercent - 41) < 0.001,
                    "single long-window primary quota becomes monthly");

                string liveUsage = "{\"plan_type\":\"plus\",\"rate_limit\":{" +
                    "\"primary_window\":{\"used_percent\":24," +
                    "\"limit_window_seconds\":18000,\"reset_after_seconds\":900}," +
                    "\"secondary_window\":{\"used_percent\":61," +
                    "\"limit_window_seconds\":604800,\"reset_after_seconds\":7200}}}";
                Assert(CodexUsageResponseMapper.TryMapForTest(liveUsage,
                    DateTime.UtcNow, out parsedUsage) &&
                    parsedUsage.HasFiveHour && parsedUsage.HasWeekly,
                    "OAuth usage response maps both quota windows");
                Assert(Math.Abs(parsedUsage.FiveHourUsedPercent - 24) < 0.001 &&
                    Math.Abs(parsedUsage.WeeklyUsedPercent - 61) < 0.001,
                    "OAuth quota percentages retain their window identity");

                string weeklyPrimaryUsage = "{\"rate_limit\":{" +
                    "\"primary_window\":{\"used_percent\":17," +
                    "\"limit_window_seconds\":604800," +
                    "\"reset_after_seconds\":3600},\"secondary_window\":null}}";
                Assert(CodexUsageResponseMapper.TryMapForTest(weeklyPrimaryUsage,
                    DateTime.UtcNow, out parsedUsage) && parsedUsage.HasWeekly &&
                    !parsedUsage.HasFiveHour &&
                    Math.Abs(parsedUsage.WeeklyUsedPercent - 17) < 0.001,
                    "OAuth weekly primary is not misclassified as five-hour quota");

                DateTime mergeNow = DateTime.UtcNow;
                UsageMetrics localQuota = new UsageMetrics
                {
                    HasFiveHour = true,
                    FiveHourUsedPercent = 80,
                    FiveHourResetUtc = mergeNow.AddHours(2),
                    HasWeekly = true,
                    WeeklyUsedPercent = 70,
                    WeeklyResetUtc = mergeNow.AddDays(2),
                    ContextInputTokens = 50,
                    ContextWindowTokens = 100
                };
                UsageMetrics remoteQuota = new UsageMetrics
                {
                    HasFiveHour = true,
                    FiveHourUsedPercent = 20,
                    FiveHourResetUtc = mergeNow.AddHours(3),
                    HasWeekly = true,
                    WeeklyUsedPercent = 30,
                    WeeklyResetUtc = mergeNow.AddDays(3),
                    ContextInputTokens = -1
                };
                UsageMetrics mergedQuota = CodexUsageMonitor.MergeForTest(
                    localQuota, remoteQuota, mergeNow);
                Assert(Math.Abs(mergedQuota.FiveHourUsedPercent - 20) < 0.001 &&
                    Math.Abs(mergedQuota.WeeklyUsedPercent - 30) < 0.001 &&
                    Math.Abs(mergedQuota.ContextUsedPercent - 50) < 0.001,
                    "live OAuth quota overrides JSONL while JSONL supplies context");
                UsageMetrics fallbackQuota = CodexUsageMonitor.MergeForTest(
                    localQuota, null, mergeNow);
                Assert(Math.Abs(fallbackQuota.FiveHourUsedPercent - 80) < 0.001 &&
                    Math.Abs(fallbackQuota.WeeklyUsedPercent - 70) < 0.001,
                    "JSONL quota remains available when OAuth has no snapshot");
                remoteQuota.FiveHourResetUtc = mergeNow.AddMinutes(-1);
                UsageMetrics expiredRemoteQuota = CodexUsageMonitor.MergeForTest(
                    localQuota, remoteQuota, mergeNow);
                Assert(Math.Abs(expiredRemoteQuota.FiveHourUsedPercent - 80) < 0.001,
                    "expired OAuth window does not replace a current JSONL fallback");

                ClaudeHookStatusReducer claude =
                    new ClaudeHookStatusReducer("claude-test");
                string claudeNow = DateTime.UtcNow.ToString("o",
                    CultureInfo.InvariantCulture);
                claude.Consume(ClaudeHookLine("UserPromptSubmit", "claude-test",
                    "C:\\work\\agenthalo", null, null, claudeNow), DateTime.UtcNow);
                Assert(claude.Snapshot.State == HaloState.Thinking &&
                    claude.Snapshot.ProjectName == "agenthalo",
                    "Claude prompt submit -> thinking");
                claude.Consume(ClaudeHookLine("PreToolUse", "claude-test",
                    "C:\\work\\agenthalo", "Bash", null, claudeNow), DateTime.UtcNow);
                Assert(claude.Snapshot.State == HaloState.Thinking,
                    "Claude quick pre tool keeps thinking briefly visible");
                claude.ApplyWorkingVisibility(DateTime.UtcNow.AddMilliseconds(800));
                Assert(claude.Snapshot.State == HaloState.Working &&
                    claude.Snapshot.Action == "Running command",
                    "Claude bash tool -> working command");
                DateTime postToolAt = DateTime.UtcNow;
                claude.Consume(ClaudeHookLine("PostToolUse", "claude-test",
                    "C:\\work\\agenthalo", "Bash", null,
                    postToolAt.ToString("o", CultureInfo.InvariantCulture)),
                    postToolAt);
                Assert(claude.Snapshot.State == HaloState.Working,
                    "Claude post tool remains briefly working");
                claude.ApplyWorkingVisibility(postToolAt.AddMilliseconds(500));
                Assert(claude.Snapshot.State == HaloState.Working,
                    "Claude post tool remains working within short hold");
                claude.ApplyWorkingVisibility(postToolAt.AddMilliseconds(800));
                Assert(claude.Snapshot.State == HaloState.Thinking,
                    "Claude post tool fades to thinking");
                claude.Consume(ClaudeHookLine("Notification", "claude-test",
                    "C:\\work\\agenthalo", null, "permission_prompt", claudeNow),
                    DateTime.UtcNow);
                claude.ApplyWorkingVisibility(DateTime.UtcNow.AddMinutes(10));
                Assert(claude.Snapshot.State == HaloState.Attention,
                    "Claude permission prompt holds attention");
                claude.Consume(ClaudeHookLine("Stop", "claude-test",
                    "C:\\work\\agenthalo", null, null, claudeNow), DateTime.UtcNow);
                Assert(claude.Snapshot.State == HaloState.Done &&
                    !claude.Snapshot.Active, "Claude stop -> done");
                claude.Consume(ClaudeHookLine("StopFailure", "claude-test",
                    "C:\\work\\agenthalo", null, null, claudeNow), DateTime.UtcNow);
                Assert(claude.Snapshot.State == HaloState.Error,
                    "Claude stop failure -> error");
                claude.Consume(ClaudeHookLine("UserPromptSubmit", "claude-test",
                    "C:\\work\\agenthalo", null, null, claudeNow), DateTime.UtcNow);
                claude.Consume(ClaudeHookLine("PreCompact", "claude-test",
                    "C:\\work\\agenthalo", null, null, claudeNow), DateTime.UtcNow);
                Assert(claude.Snapshot.State == HaloState.Working &&
                    claude.Snapshot.Action == "Compressing context",
                    "Claude pre compact -> working");
                claude.Consume(ClaudeHookLine("PostCompact", "claude-test",
                    "C:\\work\\agenthalo", null, null, claudeNow), DateTime.UtcNow);
                Assert(claude.Snapshot.State == HaloState.Thinking,
                    "Claude active post compact -> thinking");

                ClaudeHookStatusReducer manualCompact =
                    new ClaudeHookStatusReducer("claude-manual-compact");
                manualCompact.Consume(ClaudeHookLine("SessionStart",
                    "claude-manual-compact", "C:\\work\\agenthalo", null, null,
                    claudeNow), DateTime.UtcNow);
                manualCompact.Consume(ClaudeHookLine("PreCompact",
                    "claude-manual-compact", "C:\\work\\agenthalo", null, null,
                    claudeNow), DateTime.UtcNow);
                manualCompact.Consume(ClaudeHookLine("SessionStart",
                    "claude-manual-compact", "C:\\work\\agenthalo", null, null,
                    claudeNow), DateTime.UtcNow);
                Assert(manualCompact.Snapshot.State == HaloState.Working &&
                    manualCompact.Snapshot.Action == "Compressing context",
                    "Claude manual compact SessionStart preserves working");
                manualCompact.Consume(ClaudeHookLine("PostCompact",
                    "claude-manual-compact", "C:\\work\\agenthalo", null, null,
                    claudeNow), DateTime.UtcNow);
                Assert(manualCompact.Snapshot.State == HaloState.Done &&
                    manualCompact.Snapshot.Action == "Context compacted" &&
                    !manualCompact.Snapshot.Active &&
                    manualCompact.Snapshot.CompletedUtc != DateTime.MinValue,
                    "Claude manual post compact -> done");
                DateTime staleToolAt = DateTime.UtcNow.AddSeconds(-181);
                claude.Consume(ClaudeHookLine("PreToolUse", "claude-test",
                    "C:\\work\\agenthalo", "Read", null,
                    staleToolAt.ToString("o", CultureInfo.InvariantCulture)),
                    DateTime.UtcNow);
                claude.ApplyWorkingVisibility(DateTime.UtcNow);
                Assert(claude.Snapshot.State == HaloState.Thinking,
                    "Claude stuck tool safety fades to thinking");

                string claudeStatus = Path.Combine(Path.GetTempPath(),
                    "agent-halo-claude-" + Guid.NewGuid().ToString("N") + ".jsonl");
                File.WriteAllText(claudeStatus, ClaudeHookLine("UserPromptSubmit",
                    "claude-monitor", "C:\\work\\monitor", null, null,
                    claudeNow) + Environment.NewLine, Encoding.UTF8);
                ClaudeHookStatusMonitor claudeMonitor =
                    new ClaudeHookStatusMonitor(claudeStatus);
                claudeMonitor.Refresh();
                List<SessionSnapshot> claudeSnapshots = claudeMonitor.Snapshots();
                Assert(claudeSnapshots.Count == 1 &&
                    claudeSnapshots[0].State == HaloState.Thinking,
                    "Claude monitor reads status JSONL");
                File.Delete(claudeStatus);

                string claudeTranscriptNow = DateTime.UtcNow.ToString("o",
                    CultureInfo.InvariantCulture);
                ClaudeTranscriptSessionReducer transcript =
                    new ClaudeTranscriptSessionReducer(
                        "C:\\tmp\\304976ed-0876-44e9-99ce-2c9a74ab4ee2.jsonl",
                        DateTime.UtcNow, true);
                transcript.Consume(ClaudeTranscriptUserLine("claude-transcript",
                    "C:\\work\\agenthalo", "Build Claude status",
                    claudeTranscriptNow), DateTime.UtcNow);
                Assert(transcript.Snapshot.State == HaloState.Thinking &&
                    transcript.Snapshot.ProjectName == "agenthalo",
                    "Claude transcript user prompt -> thinking");
                transcript.Consume(ClaudeTranscriptAssistantToolLine(
                    "claude-transcript", "C:\\work\\agenthalo", "Bash",
                    claudeTranscriptNow), DateTime.UtcNow);
                Assert(transcript.Snapshot.State == HaloState.Working &&
                    transcript.Snapshot.Action == "Running command",
                    "Claude transcript tool use -> working");
                transcript.Consume(ClaudeTranscriptToolResultLine(
                    "claude-transcript", "C:\\work\\agenthalo",
                    claudeTranscriptNow), DateTime.UtcNow);
                Assert(transcript.Snapshot.State == HaloState.Working,
                    "Claude transcript tool result remains briefly working");
                DateTime transcriptHoldStart = DateTime.UtcNow;
                transcript.ApplyWorkingVisibility(transcriptHoldStart.AddMilliseconds(500));
                Assert(transcript.Snapshot.State == HaloState.Working,
                    "Claude transcript tool result remains working within short hold");
                transcript.ApplyWorkingVisibility(transcriptHoldStart.AddMilliseconds(800));
                Assert(transcript.Snapshot.State == HaloState.Thinking,
                    "Claude transcript post tool fades to thinking");
                transcript.Consume(ClaudeTranscriptAssistantToolLine(
                    "claude-transcript", "C:\\work\\agenthalo", "Bash",
                    claudeTranscriptNow), DateTime.UtcNow);
                Assert(transcript.Snapshot.State == HaloState.Working,
                    "Claude transcript second tool use -> working");
                transcript.Consume(ClaudeTranscriptAssistantTextLine(
                    "claude-transcript", "C:\\work\\agenthalo",
                    claudeTranscriptNow), DateTime.UtcNow);
                Assert(transcript.Snapshot.State == HaloState.Thinking,
                    "Claude transcript assistant text interrupts working hold");
                transcript.Consume(ClaudeTranscriptAssistantToolLine(
                    "claude-transcript", "C:\\work\\agenthalo",
                    "AskUserQuestion", claudeTranscriptNow), DateTime.UtcNow);
                Assert(transcript.Snapshot.State == HaloState.Attention,
                    "Claude transcript AskUserQuestion -> attention");
                transcript.Consume(ClaudeTranscriptTurnDurationLine(
                    "claude-transcript", "C:\\work\\agenthalo",
                    claudeTranscriptNow), DateTime.UtcNow);
                Assert(transcript.Snapshot.State == HaloState.Done &&
                    !transcript.Snapshot.Active,
                    "Claude transcript turn duration -> done");
                transcript.Consume(ClaudeTranscriptSystemLine(
                    "claude-transcript", "C:\\work\\agenthalo", "api_error",
                    claudeTranscriptNow), DateTime.UtcNow);
                Assert(transcript.Snapshot.State == HaloState.Error,
                    "Claude transcript api error -> error");

                ClaudeHookStatusReducer quickHook =
                    new ClaudeHookStatusReducer("quick-hook");
                DateTime quickStart = DateTime.UtcNow;
                quickHook.Consume(ClaudeHookLine("UserPromptSubmit", "quick-hook",
                    "C:\\work\\agenthalo", quickStart.ToString("o",
                        CultureInfo.InvariantCulture)), quickStart);
                quickHook.Consume(ClaudeHookLine("PreToolUse", "quick-hook",
                    "C:\\work\\agenthalo", quickStart.AddMilliseconds(120)
                        .ToString("o", CultureInfo.InvariantCulture), "Bash"),
                    quickStart.AddMilliseconds(120));
                quickHook.ApplyWorkingVisibility(quickStart.AddMilliseconds(500));
                Assert(quickHook.Snapshot.State == HaloState.Thinking,
                    "Claude quick tool keeps thinking briefly visible");
                quickHook.ApplyWorkingVisibility(quickStart.AddMilliseconds(800));
                Assert(quickHook.Snapshot.State == HaloState.Working,
                    "Claude quick tool switches to working after thinking hold");

                string claudeProjects = Path.Combine(Path.GetTempPath(),
                    "agent-halo-claude-projects-" + Guid.NewGuid().ToString("N"));
                string claudeTranscriptDir = Path.Combine(claudeProjects, "project");
                Directory.CreateDirectory(claudeTranscriptDir);
                string claudeTranscriptFile = Path.Combine(claudeTranscriptDir,
                    "monitor.jsonl");
                File.WriteAllText(claudeTranscriptFile,
                    ClaudeTranscriptUserLine("claude-monitor-transcript",
                        "C:\\work\\monitor", "Work", claudeTranscriptNow) +
                    Environment.NewLine, Encoding.UTF8);
                ClaudeTranscriptSessionMonitor transcriptMonitor =
                    new ClaudeTranscriptSessionMonitor(claudeProjects);
                transcriptMonitor.Refresh();
                List<SessionSnapshot> transcriptSnapshots =
                    transcriptMonitor.Snapshots();
                Assert(transcriptSnapshots.Count == 1 &&
                    transcriptSnapshots[0].State == HaloState.Thinking,
                    "Claude transcript monitor reads project JSONL");
                Directory.Delete(claudeProjects, true);

                string claudeHome = Path.Combine(Path.GetTempPath(),
                    "agent-halo-claude-home-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(Path.Combine(claudeHome, ".claude"));
                string mainExe = Path.Combine(claudeHome, "bundle",
                    "AgentHalo.exe");
                Directory.CreateDirectory(Path.GetDirectoryName(mainExe));
                // Real-looking PE is unnecessary; File.Exists is enough for staging.
                File.WriteAllText(mainExe, "fake exe", Encoding.UTF8);
                string legacyHelper = AgentHaloPaths.LegacyAgentHaloHookExe(claudeHome);
                Directory.CreateDirectory(Path.GetDirectoryName(legacyHelper));
                File.WriteAllText(legacyHelper, "legacy", Encoding.UTF8);
                string claudeSettings = Path.Combine(claudeHome, ".claude",
                    "settings.json");
                File.WriteAllText(claudeSettings,
                    "{\"hooks\":{\"Notification\":[{\"hooks\":[{\"type\":\"command\"," +
                    "\"command\":\"user-command\"}]}],\"PreToolUse\":[{\"matcher\":\".*\"," +
                    "\"hooks\":[{\"type\":\"command\",\"command\":\"old.exe AgentHaloHook.exe PreToolUse\"}]}]}}",
                    Encoding.UTF8);
                string stagedHook = AgentHaloPaths.StatusHookExe(claudeHome);
                AgentHaloRuntimeBootstrap.Bootstrap(claudeHome, mainExe);
                string configured = File.ReadAllText(claudeSettings, Encoding.UTF8);
                Assert(File.Exists(stagedHook),
                    "runtime bootstrap stages bin\\status-hook.exe");
                Assert(configured.Contains("status-hook.exe") &&
                    configured.Contains("--claude-hook") &&
                    configured.Contains("PreToolUse") &&
                    configured.Contains("PostToolBatch") &&
                    configured.Contains("PermissionRequest") &&
                    configured.Contains("PermissionDenied") &&
                    configured.Contains("user-command") &&
                    !configured.Contains("old.exe AgentHaloHook.exe") &&
                    !configured.Contains("AgentHaloHook.exe"),
                    "Claude hook configurator rewrites settings onto preferred path");
                ClaudeHookConfigurator.Configure(claudeHome, stagedHook);
                string configuredAgain = File.ReadAllText(claudeSettings, Encoding.UTF8);
                Assert(CountOccurrences(configuredAgain, "--claude-hook") ==
                    CountOccurrences(configured, "--claude-hook"),
                    "Claude hook configurator is idempotent");
                File.WriteAllText(
                    claudeSettings,
                    configuredAgain.Replace(
                        "--claude-hook PreToolUse",
                        "--claude-hook Stop"),
                    Encoding.UTF8);
                ClaudeHookConfigurator.Configure(claudeHome, stagedHook);
                string repairedEvent = File.ReadAllText(claudeSettings, Encoding.UTF8);
                Assert(CountOccurrences(repairedEvent, "--claude-hook PreToolUse") == 1,
                    "Claude hook configurator repairs a mismatched event argument");
                AgentHaloRuntimeBootstrap.Bootstrap(claudeHome, mainExe);
                Assert(File.Exists(stagedHook), "bootstrap keeps status-hook.exe");
                Assert(!File.Exists(legacyHelper),
                    "bootstrap scrubs unreferenced AgentHaloHook.exe after rewrite");

                string liveHome = Path.Combine(Path.GetTempPath(),
                    "agent-halo-claude-live-" + Guid.NewGuid().ToString("N"));
                string liveSessions = Path.Combine(liveHome, ".claude", "sessions");
                Directory.CreateDirectory(liveSessions);
                File.WriteAllText(Path.Combine(liveSessions, "live.json"),
                    "{\"status\":\"busy\",\"pid\":" +
                    Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) +
                    ",\"sessionId\":\"live\",\"cwd\":\"C:\\\\work\"}",
                    Encoding.UTF8);
                Assert(ClaudeLiveSessionReader.HasStandbySession(liveHome),
                    "Claude live session reader detects live CLI");
                Assert(ClaudeLiveSessionReader.LiveSessionIds(liveHome).Contains("live"),
                    "Claude live session reader exposes the live session id");
                File.WriteAllText(Path.Combine(liveSessions, "live.json"),
                    "{\"status\":\"waiting\",\"pid\":999999,\"sessionId\":\"dead\"}",
                    Encoding.UTF8);
                Assert(!ClaudeLiveSessionReader.HasStandbySession(liveHome),
                    "Claude live session reader ignores dead pid");
                Assert(!ClaudeLiveSessionReader.LiveSessionIds(liveHome).Contains("dead"),
                    "Claude dead session id is excluded from liveness");
                Directory.Delete(liveHome, true);
                Directory.Delete(claudeHome, true);

                string claudeMetricsHome = Path.Combine(Path.GetTempPath(),
                    "agent-halo-claude-metrics-" + Guid.NewGuid().ToString("N"));
                string claudeProjectDir = Path.Combine(claudeMetricsHome,
                    ".claude", "projects", "agenthalo");
                Directory.CreateDirectory(claudeProjectDir);
                Directory.CreateDirectory(Path.Combine(claudeMetricsHome, ".claude"));
                File.WriteAllText(Path.Combine(claudeMetricsHome, ".claude",
                    "settings.json"),
                    "{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://example.invalid\"," +
                    "\"CLAUDE_MAX_CONTEXT_WINDOW\":\"200000\"}}", Encoding.UTF8);
                File.WriteAllText(Path.Combine(claudeProjectDir, "session.jsonl"),
                    "{\"type\":\"assistant\",\"message\":{\"model\":\"deepseek-v4-pro\"," +
                    "\"usage\":{\"input_tokens\":38000,\"output_tokens\":1200}}}\n",
                    Encoding.UTF8);
                ClaudeCodeMetrics claudeMetrics =
                    ClaudeCodeMetricsReader.Read(claudeMetricsHome);
                Assert(claudeMetrics.IsCustomApi,
                    "Claude custom API settings are detected");
                Assert(claudeMetrics.Model == "deepseek-v4-pro",
                    "Claude model is read from transcript");
                Assert(claudeMetrics.InputTokens == 38000 &&
                    claudeMetrics.OutputTokens == 1200,
                    "Claude token usage is read from transcript");
                Assert(Math.Abs(claudeMetrics.ContextUsedPercent - 19.0) < 0.001,
                    "Claude context percentage uses input tokens and window");
                Directory.Delete(claudeMetricsHome, true);

                DateTime supersessionNow = DateTime.UtcNow;
                SessionSnapshot oldError = new SessionSnapshot
                {
                    ThreadId = "old-error",
                    ProjectName = "OldProject",
                    State = HaloState.Error,
                    Action = "Interrupted",
                    LastEventUtc = supersessionNow.AddMinutes(-1),
                    Active = false,
                    Agent = AgentKind.Codex
                };
                SessionSnapshot newerWorking = new SessionSnapshot
                {
                    ThreadId = "new-working",
                    ProjectName = "NewProject",
                    State = HaloState.Working,
                    Action = "Running command",
                    LastEventUtc = supersessionNow,
                    Active = true,
                    Agent = AgentKind.Codex
                };
                List<SessionSnapshot> supersessionInput =
                    new List<SessionSnapshot> { oldError, newerWorking };
                List<SessionSnapshot> supersessionDisplay =
                    CodexSessionMonitor.WithoutSupersededErrors(supersessionInput);
                Assert(supersessionDisplay.Count == 1 &&
                    supersessionDisplay[0].ThreadId == "new-working",
                    "newer Windows session removes old interrupted display state");
                Assert(supersessionInput.Count == 2,
                    "Windows supersession filter preserves raw sessions");

                SessionSnapshot newerDone = new SessionSnapshot
                {
                    ThreadId = "new-done",
                    ProjectName = "NewProject",
                    State = HaloState.Done,
                    Action = "Complete",
                    LastEventUtc = supersessionNow,
                    CompletedUtc = supersessionNow,
                    Active = false,
                    Agent = AgentKind.Codex
                };
                List<SessionSnapshot> doneDisplay =
                    CodexSessionMonitor.WithoutSupersededErrors(
                        new[] { oldError, newerDone });
                Assert(doneDisplay.Count == 1 &&
                    doneDisplay[0].ThreadId == "new-done",
                    "newer Windows completion removes old interrupted display state");
                List<SessionSnapshot> acknowledgedDoneDisplay = doneDisplay
                    .Where(delegate(SessionSnapshot snapshot)
                    {
                        return snapshot.State != HaloState.Done;
                    })
                    .ToList();
                Assert(acknowledgedDoneDisplay.Count == 0,
                    "acknowledged Windows completion does not resurrect old error");

                SessionSnapshot olderWorking = new SessionSnapshot
                {
                    ThreadId = "old-working",
                    ProjectName = "OldProject",
                    State = HaloState.Working,
                    Action = "Running command",
                    LastEventUtc = supersessionNow.AddMinutes(-1),
                    Active = true,
                    Agent = AgentKind.Codex
                };
                SessionSnapshot newerError = new SessionSnapshot
                {
                    ThreadId = "new-error",
                    ProjectName = "NewProject",
                    State = HaloState.Error,
                    Action = "Interrupted",
                    LastEventUtc = supersessionNow,
                    Active = false,
                    Agent = AgentKind.Codex
                };
                List<SessionSnapshot> latestErrorDisplay =
                    CodexSessionMonitor.WithoutSupersededErrors(
                        new[] { olderWorking, newerError });
                Assert(latestErrorDisplay.Count == 2 &&
                    latestErrorDisplay.Any(delegate(SessionSnapshot snapshot)
                    {
                        return snapshot.ThreadId == "new-error";
                    }), "latest Windows error remains visible with active sessions");

                SessionSnapshot metadataOnly = new SessionSnapshot
                {
                    ThreadId = "metadata-only",
                    ProjectName = "Codex",
                    State = HaloState.Idle,
                    Action = "Ready",
                    LastEventUtc = supersessionNow,
                    Active = false,
                    Agent = AgentKind.Codex
                };
                List<SessionSnapshot> metadataDisplay =
                    CodexSessionMonitor.WithoutSupersededErrors(
                        new[] { oldError, metadataOnly });
                Assert(metadataDisplay.Any(delegate(SessionSnapshot snapshot)
                {
                    return snapshot.ThreadId == "old-error";
                }), "metadata-only Windows session does not suppress old error");

                HaloSettings presenceSettings = new HaloSettings
                {
                    InstalledAt = supersessionNow.AddHours(-1).ToString("o")
                };
                using (CodexSessionMonitor presenceMonitor = new CodexSessionMonitor())
                {
                    AggregateSnapshot standby = presenceMonitor.GetAggregate(
                        presenceSettings, true);
                    Assert(standby.State == HaloState.Done &&
                        standby.Presence == AgentPresenceState.Standby &&
                        standby.TurnPhase == AgentTurnPhase.None &&
                        standby.Label == "STANDBY",
                        "running Codex without an active turn becomes normalized standby");
                    AggregateSnapshot offline = presenceMonitor.GetAggregate(
                        presenceSettings, false);
                    Assert(offline.State == HaloState.Idle &&
                        offline.Presence == AgentPresenceState.Offline &&
                        offline.TurnPhase == AgentTurnPhase.None,
                        "stopped Codex becomes normalized offline");
                }
                SessionSnapshot recentActive = new SessionSnapshot
                {
                    ThreadId = "recent-active",
                    State = HaloState.Working,
                    Active = true,
                    LastEventUtc = supersessionNow.AddMinutes(-1)
                };
                Assert(CodexSessionMonitor.IsSessionVisible(recentActive,
                    presenceSettings, true, supersessionNow),
                    "recent active session remains visible while Codex runs");
                Assert(!CodexSessionMonitor.IsSessionVisible(recentActive,
                    presenceSettings, false, supersessionNow),
                    "active session cannot keep Codex online after its process exits");
                recentActive.LastEventUtc = supersessionNow.AddMinutes(-11);
                Assert(!CodexSessionMonitor.IsSessionVisible(recentActive,
                    presenceSettings, true, supersessionNow),
                    "stale active session cannot leave the halo permanently working");
                SessionSnapshot longAttentionCodex = new SessionSnapshot
                {
                    ThreadId = "long-attn-codex",
                    State = HaloState.Attention,
                    Action = "Needs you",
                    Active = true,
                    LastEventUtc = supersessionNow.AddMinutes(-30)
                };
                Assert(CodexSessionMonitor.IsSessionVisible(longAttentionCodex,
                    presenceSettings, true, supersessionNow),
                    "Codex attention remains visible across long human waits");
                Assert(!CodexSessionMonitor.IsSessionVisible(longAttentionCodex,
                    presenceSettings, false, supersessionNow),
                    "Codex attention still requires the process to be running");
                Assert(!CodexSessionMonitor.IsSessionVisible(longAttentionCodex,
                    presenceSettings, true, supersessionNow,
                    "new-active-thread", true, null),
                    "another realtime thread supersedes stale Codex attention");
                Assert(CodexSessionMonitor.IsSessionVisible(longAttentionCodex,
                    presenceSettings, true, supersessionNow,
                    "long-attn-codex", true, null),
                    "matching realtime thread keeps Codex attention visible");
                Assert(!CodexSessionMonitor.IsSessionVisible(longAttentionCodex,
                    presenceSettings, true, supersessionNow,
                    null, false, supersessionNow.AddMinutes(-5)),
                    "attention from before the current Codex process is hidden");
                Assert(!CodexSessionMonitor.HasBlockingState(
                    new[] { longAttentionCodex }, true),
                    "fresh realtime activity can replace an old attention blocker");
                Assert(CodexSessionMonitor.HasBlockingState(
                    new[] { longAttentionCodex }, false),
                    "attention remains blocking while its long wait is current");

                SessionSnapshot recentDone = new SessionSnapshot
                {
                    ThreadId = "recent-done",
                    State = HaloState.Done,
                    Active = false,
                    CompletedUtc = supersessionNow.AddSeconds(-2),
                    LastEventUtc = supersessionNow.AddSeconds(-2)
                };
                Assert(CodexSessionMonitor.IsSessionVisible(recentDone,
                    presenceSettings, true, supersessionNow),
                    "fresh Codex completion remains visible briefly while the app runs");
                Assert(!CodexSessionMonitor.IsSessionVisible(recentDone,
                    presenceSettings, false, supersessionNow),
                    "quitting Codex must hide done so offline can surface");
                recentDone.CompletedUtc = supersessionNow.AddSeconds(-12);
                recentDone.LastEventUtc = recentDone.CompletedUtc;
                Assert(!CodexSessionMonitor.IsSessionVisible(recentDone,
                    presenceSettings, true, supersessionNow),
                    "Codex completion settles after ~8s so standby can appear");
                Assert(CodexRuntimeReader.IsPrimaryCodexProcessName("Codex"),
                    "exact Codex process name is primary");
                Assert(CodexRuntimeReader.IsPrimaryCodexProcessName("codex"),
                    "exact lowercase codex process name is primary");
                Assert(!CodexRuntimeReader.IsPrimaryCodexProcessName("codex-code-mode-host"),
                    "helper process names must not count as Codex presence");
                Assert(!CodexRuntimeReader.IsPrimaryCodexProcessName("CodexHelper"),
                    "substring Codex names must not count as Codex presence");

                string watcherRoot = Path.Combine(Path.GetTempPath(),
                    "agent-halo-session-watch-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(watcherRoot);
                using (CodexSessionMonitor watcherMonitor =
                    new CodexSessionMonitor(watcherRoot, false))
                {
                    watcherMonitor.Start();
                    string watcherSession = Path.Combine(watcherRoot,
                        "rollout-" + Guid.NewGuid().ToString() + ".jsonl");
                    File.WriteAllText(watcherSession,
                        "{\"timestamp\":\"" + DateTime.UtcNow.ToString("o") +
                        "\",\"type\":\"session_meta\",\"payload\":{\"id\":\"watcher-test\"," +
                        "\"cwd\":\"C:\\\\work\\\\watcher\"}}\n" +
                        "{\"timestamp\":\"" + DateTime.UtcNow.ToString("o") +
                        "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n",
                        Encoding.UTF8);
                    DateTime watcherDeadline = DateTime.UtcNow.AddSeconds(3);
                    AggregateSnapshot watcherAggregate = null;
                    while (DateTime.UtcNow < watcherDeadline)
                    {
                        watcherAggregate = watcherMonitor.GetAggregate(
                            presenceSettings, true);
                        if (watcherAggregate.State == HaloState.Thinking) break;
                        Thread.Sleep(50);
                    }
                    Assert(watcherAggregate != null &&
                        watcherAggregate.State == HaloState.Thinking &&
                        watcherAggregate.EvidenceSource ==
                            AgentEvidenceSource.SessionJsonl,
                        "session watcher discovers a new active turn incrementally");
                }
                Directory.Delete(watcherRoot, true);

                // Context pill STANDBY soft-hold (parity with macOS DetailsPanel).
                DateTime holdT0 = new DateTime(2026, 7, 28, 12, 0, 0, DateTimeKind.Utc);
                DetailsWindow.ContextDisplayResolution liveHold =
                    DetailsWindow.ResolveContextDisplay(
                        42.0, false, false, null, null, holdT0,
                        DetailsWindow.StandbyContextHoldDuration);
                Assert(liveHold.DisplayPercent.HasValue &&
                    Math.Abs(liveHold.DisplayPercent.Value - 42.0) < 0.001 &&
                    liveHold.HeldPercent.HasValue &&
                    !liveHold.HoldExpiresUtc.HasValue,
                    "live context displays and is remembered without starting hold timer");
                DetailsWindow.ContextDisplayResolution startHold =
                    DetailsWindow.ResolveContextDisplay(
                        null, false, true, 42.0, null, holdT0,
                        DetailsWindow.StandbyContextHoldDuration);
                Assert(startHold.DisplayPercent.HasValue &&
                    Math.Abs(startHold.DisplayPercent.Value - 42.0) < 0.001 &&
                    startHold.HoldExpiresUtc.HasValue &&
                    startHold.HoldExpiresUtc.Value ==
                        holdT0.Add(DetailsWindow.StandbyContextHoldDuration),
                    "first STANDBY tick soft-holds the last live context percent");
                DetailsWindow.ContextDisplayResolution midHold =
                    DetailsWindow.ResolveContextDisplay(
                        null, false, true, 42.0,
                        holdT0.Add(DetailsWindow.StandbyContextHoldDuration),
                        holdT0.Add(TimeSpan.FromSeconds(5)),
                        DetailsWindow.StandbyContextHoldDuration);
                Assert(midHold.DisplayPercent.HasValue,
                    "mid-hold keeps the context pill visible");
                DetailsWindow.ContextDisplayResolution expiredHold =
                    DetailsWindow.ResolveContextDisplay(
                        null, false, true, 42.0,
                        holdT0.Add(DetailsWindow.StandbyContextHoldDuration),
                        holdT0.Add(DetailsWindow.StandbyContextHoldDuration)
                            .Add(TimeSpan.FromMilliseconds(10)),
                        DetailsWindow.StandbyContextHoldDuration);
                Assert(!expiredHold.DisplayPercent.HasValue &&
                    !expiredHold.HeldPercent.HasValue,
                    "STANDBY hold expires and hides the context pill");
                DetailsWindow.ContextDisplayResolution offlineHold =
                    DetailsWindow.ResolveContextDisplay(
                        null, true, false, 42.0,
                        holdT0.Add(DetailsWindow.StandbyContextHoldDuration),
                        holdT0, DetailsWindow.StandbyContextHoldDuration);
                Assert(!offlineHold.DisplayPercent.HasValue &&
                    !offlineHold.HeldPercent.HasValue,
                    "OFFLINE clears context immediately without soft-hold");
                // Frozen disk/usage readings during STANDBY must not re-arm live
                // display: callers pass null live while isStandby (ApplyContextSource).
                DetailsWindow.ContextDisplayResolution standbyIgnoresLive =
                    DetailsWindow.ResolveContextDisplay(
                        null, false, true, 55.0, null, holdT0,
                        DetailsWindow.StandbyContextHoldDuration);
                Assert(standbyIgnoresLive.DisplayPercent.HasValue &&
                    Math.Abs(standbyIgnoresLive.DisplayPercent.Value - 55.0) < 0.001,
                    "STANDBY soft-hold uses remembered percent only");

                // Focused agent grok persistence
                HaloSettings grokSettings = new HaloSettings();
                grokSettings.SetFocusedAgent(AgentKind.Grok);
                Assert(grokSettings.GetFocusedAgent() == AgentKind.Grok,
                    "settings should accept grok focus");
                Assert(String.Equals(grokSettings.FocusedAgent, "grok",
                    StringComparison.OrdinalIgnoreCase), "serialized focusedAgent is grok");

                JavaScriptSerializer settingsSerializer = new JavaScriptSerializer();
                HaloSettings grokDeserialized = settingsSerializer.Deserialize<HaloSettings>(
                    "{\"FocusedAgent\":\"grok\"}");
                Assert(grokDeserialized != null &&
                    grokDeserialized.GetFocusedAgent() == AgentKind.Grok,
                    "deserialized focusedAgent grok maps to AgentKind.Grok");

                HaloSettings invalidFocus = settingsSerializer.Deserialize<HaloSettings>(
                    "{\"FocusedAgent\":\"nope\"}");
                Assert(invalidFocus != null &&
                    invalidFocus.GetFocusedAgent() == AgentKind.Codex,
                    "invalid focusedAgent falls back to Codex");
                // Load() repair accepts only known agent values; "nope" resets.
                Assert(!String.Equals(invalidFocus.FocusedAgent, "grok",
                    StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(invalidFocus.FocusedAgent, "claudeCode",
                        StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(invalidFocus.FocusedAgent, "pi",
                        StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(invalidFocus.FocusedAgent, "codex",
                        StringComparison.OrdinalIgnoreCase),
                    "invalid focusedAgent is not a known agent string before Load repair");

                // Existing agents still round-trip after Grok support.
                HaloSettings codexSettings = new HaloSettings();
                codexSettings.SetFocusedAgent(AgentKind.Codex);
                Assert(codexSettings.GetFocusedAgent() == AgentKind.Codex &&
                    String.Equals(codexSettings.FocusedAgent, "codex",
                        StringComparison.OrdinalIgnoreCase),
                    "codex focus still persists");
                HaloSettings claudeFocusSettings = new HaloSettings();
                claudeFocusSettings.SetFocusedAgent(AgentKind.ClaudeCode);
                Assert(claudeFocusSettings.GetFocusedAgent() == AgentKind.ClaudeCode &&
                    String.Equals(claudeFocusSettings.FocusedAgent, "claudeCode",
                        StringComparison.OrdinalIgnoreCase),
                    "claudeCode focus still persists");

                HaloSettings piFocusSettings = new HaloSettings();
                piFocusSettings.SetFocusedAgent(AgentKind.Pi);
                Assert(piFocusSettings.GetFocusedAgent() == AgentKind.Pi &&
                    String.Equals(piFocusSettings.FocusedAgent, "pi",
                        StringComparison.OrdinalIgnoreCase),
                    "pi focus persists");

                HaloSettings legacyAgents = settingsSerializer.Deserialize<HaloSettings>(
                    "{\"FocusedAgent\":\"grok\"}");
                legacyAgents.NormalizeEnabledAgents();
                Assert(legacyAgents.GetEnabledAgents().Count == 4 &&
                    legacyAgents.GetFocusedAgent() == AgentKind.Grok,
                    "legacy settings enable every supported agent");

                HaloSettings filteredAgents = settingsSerializer.Deserialize<HaloSettings>(
                    "{\"FocusedAgent\":\"claudeCode\",\"EnabledAgents\":[\"codex\",\"pi\"]}");
                Assert(filteredAgents.NormalizeEnabledAgents() &&
                    filteredAgents.GetEnabledAgents().SequenceEqual(new[]
                    {
                        AgentKind.Codex, AgentKind.Pi
                    }) && filteredAgents.GetFocusedAgent() == AgentKind.Codex,
                    "disabled focused agent falls back to first enabled agent");
                Assert(filteredAgents.SetAgentEnabled(AgentKind.Codex, false) &&
                    filteredAgents.GetFocusedAgent() == AgentKind.Pi &&
                    filteredAgents.GetEnabledAgents().SequenceEqual(new[]
                    {
                        AgentKind.Pi
                    }), "disabling focused agent selects the remaining agent");
                Assert(!filteredAgents.SetAgentEnabled(AgentKind.Pi, false) &&
                    filteredAgents.IsAgentEnabled(AgentKind.Pi),
                    "settings keep at least one monitored agent");

                HaloSettings monitorSettings = new HaloSettings();
                Assert(HaloWindow.ShouldRunCodexMonitor(monitorSettings),
                    "Codex monitor runs while Codex is focused");
                monitorSettings.SetFocusedAgent(AgentKind.Pi);
                Assert(!HaloWindow.ShouldRunCodexMonitor(monitorSettings),
                    "Codex monitor stops while another agent is focused");
                monitorSettings.SetFocusedAgent(AgentKind.Codex);
                monitorSettings.Paused = true;
                Assert(!HaloWindow.ShouldRunCodexMonitor(monitorSettings),
                    "Codex monitor stops while monitoring is paused");

                string piExtensionSource = PiExtensionConfigurator.ReadEmbeddedSource();
                Assert(!String.IsNullOrWhiteSpace(piExtensionSource) &&
                    piExtensionSource.Contains("agent_settled") &&
                    piExtensionSource.Contains("tool_execution_start"),
                    "Pi status extension is embedded with authoritative events");
                Assert(!piExtensionSource.Contains("prompt:") &&
                    !piExtensionSource.Contains("toolArgs") &&
                    !piExtensionSource.Contains("baseUrl"),
                    "Pi extension excludes prompts, tool arguments and provider URLs");

                string oldPiRoot = Environment.GetEnvironmentVariable(
                    "PI_CODING_AGENT_DIR");
                string piAgentRoot = Path.Combine(Path.GetTempPath(),
                    "agent-halo-pi-extension-" + Guid.NewGuid().ToString("N"));
                try
                {
                    Environment.SetEnvironmentVariable("PI_CODING_AGENT_DIR", piAgentRoot);
                    string installedPiExtension = PiExtensionConfigurator.Configure();
                    Assert(File.Exists(installedPiExtension) &&
                        String.Equals(File.ReadAllText(installedPiExtension, Encoding.UTF8),
                            piExtensionSource, StringComparison.Ordinal),
                        "Pi extension installs atomically from the embedded source");
                }
                finally
                {
                    Environment.SetEnvironmentVariable("PI_CODING_AGENT_DIR", oldPiRoot);
                }

                string piStatusHome = Path.Combine(Path.GetTempPath(),
                    "agent-halo-pi-status-" + Guid.NewGuid().ToString("N"));
                string piStatusPath = AgentHaloPaths.PiStatusLog(piStatusHome);
                Directory.CreateDirectory(Path.GetDirectoryName(piStatusPath));
                string piNow = DateTime.UtcNow.ToString("o");
                int currentPid = Process.GetCurrentProcess().Id;
                File.WriteAllText(piStatusPath,
                    "{\"version\":1,\"timestamp\":\"" + piNow +
                    "\",\"source\":\"pi-extension\",\"event\":\"tool_execution_start\"," +
                    "\"state\":\"working\",\"pid\":" +
                    currentPid.ToString(CultureInfo.InvariantCulture) +
                    ",\"sessionId\":\"pi-self-test\",\"cwd\":\"C:\\\\work\\\\demo\"," +
                    "\"provider\":\"test-provider\",\"model\":\"test-model\"," +
                    "\"contextTokens\":24000,\"contextWindow\":120000," +
                    "\"inputTokens\":1200,\"outputTokens\":80," +
                    "\"toolName\":\"read\"}\n", Encoding.UTF8);
                PiStatusMonitor piStatusMonitor = new PiStatusMonitor(piStatusPath);
                Assert(piStatusMonitor.Refresh(), "Pi status log refreshes");
                List<SessionSnapshot> piSnapshots = piStatusMonitor.Snapshots();
                Assert(piSnapshots.Count == 1 &&
                    piSnapshots[0].Agent == AgentKind.Pi &&
                    piSnapshots[0].State == HaloState.Working &&
                    piSnapshots[0].ModelName == "test-model" &&
                    piSnapshots[0].ContextInputTokens == 24000 &&
                    piStatusMonitor.LiveSessionIds().Contains("pi-self-test"),
                    "Pi status maps working/model/context and validates live pid");
                AggregateSnapshot piAggregate = HaloWindow.BuildPiAggregateForTest(
                    piSnapshots, false, piStatusMonitor.LiveSessionIds(), DateTime.UtcNow);
                Assert(piAggregate.State == HaloState.Working &&
                    piAggregate.FocusedAgent == AgentKind.Pi,
                    "Pi aggregate exposes active working state");

                DateTime piRuntimeNow = DateTime.UtcNow;
                PiSessionEvidence piRuntimeEvidence = new PiSessionEvidence
                {
                    SessionId = "pi-runtime-test",
                    WorkingDirectory = "C:\\work\\runtime",
                    CreatedUtc = piRuntimeNow.AddMinutes(-20),
                    LastWriteUtc = piRuntimeNow.AddMinutes(-1)
                };
                List<PiRuntimeProcess> piRuntimeProcesses = new List<PiRuntimeProcess>
                {
                    new PiRuntimeProcess
                    {
                        ProcessId = 100,
                        ParentProcessId = 1,
                        Name = "pwsh.exe",
                        StartedUtc = piRuntimeNow.AddHours(-2)
                    },
                    new PiRuntimeProcess
                    {
                        ProcessId = 101,
                        ParentProcessId = 100,
                        Name = "node.exe",
                        StartedUtc = piRuntimeNow.AddHours(-1)
                    }
                };
                Assert(PiRuntimeMonitor.IsRunningForTest(piRuntimeEvidence,
                    piRuntimeNow, piRuntimeProcesses),
                    "Pi runtime fallback recognizes a shell-hosted Node session");
                Assert(!PiRuntimeMonitor.IsRunningForTest(new PiSessionEvidence
                {
                    SessionId = "stale",
                    LastWriteUtc = piRuntimeNow.AddDays(-4)
                }, piRuntimeNow, piRuntimeProcesses),
                    "Pi runtime fallback rejects stale session evidence");

                SessionSnapshot piRuntimeSnapshot = new SessionSnapshot
                {
                    ThreadId = "pi-runtime-test",
                    ProjectName = "runtime",
                    WorkingDirectory = "C:\\work\\runtime",
                    State = HaloState.Idle,
                    Action = "Ready",
                    LastEventUtc = piRuntimeNow.AddMinutes(-1),
                    Agent = AgentKind.Pi,
                    EvidenceSource = AgentEvidenceSource.PiExtension,
                    EvidenceKind = "runtime-session"
                };
                AggregateSnapshot piRuntimeAggregate =
                    HaloWindow.BuildPiAggregateForTest(
                        new List<SessionSnapshot> { piRuntimeSnapshot }, false,
                        new HashSet<string>(StringComparer.OrdinalIgnoreCase), true,
                        piRuntimeNow);
                Assert(piRuntimeAggregate.State == HaloState.Idle &&
                    piRuntimeAggregate.Sessions.Count == 1 &&
                    piRuntimeAggregate.Detail == L10n.Instance["status.standby_pi"],
                    "Pi runtime fallback exposes standby with project context");

                string piRuntimeRoot = Path.Combine(Path.GetTempPath(),
                    "agent-halo-pi-runtime-" + Guid.NewGuid().ToString("N"));
                try
                {
                    string piRuntimeSessions = Path.Combine(piRuntimeRoot, "sessions", "demo");
                    Directory.CreateDirectory(piRuntimeSessions);
                    string piRuntimeFile = Path.Combine(piRuntimeSessions, "session.jsonl");
                    File.WriteAllText(piRuntimeFile,
                        "{\"type\":\"session\",\"version\":3," +
                        "\"id\":\"pi-runtime-file\",\"cwd\":\"C:\\\\work\\\\runtime\"}\n" +
                        "{\"type\":\"message\",\"message\":{" +
                        "\"role\":\"assistant\",\"provider\":\"test-provider\"," +
                        "\"model\":\"test-model\",\"usage\":{" +
                        "\"input\":1200,\"output\":80,\"cacheRead\":22000," +
                        "\"cacheWrite\":0,\"totalTokens\":23280}}}\n",
                        Encoding.UTF8);
                    File.WriteAllText(Path.Combine(piRuntimeRoot, "models.json"),
                        "{\"providers\":{\"test-provider\":{\"models\":[{" +
                        "\"id\":\"test-model\",\"contextWindow\":120000}]}}}",
                        Encoding.UTF8);
                    PiSessionEvidence parsedPiRuntime =
                        PiRuntimeMonitor.ReadLatestSession(piRuntimeRoot);
                    Assert(parsedPiRuntime != null &&
                        parsedPiRuntime.SessionId == "pi-runtime-file" &&
                        parsedPiRuntime.WorkingDirectory == "C:\\work\\runtime" &&
                        parsedPiRuntime.Model == "test-model" &&
                        parsedPiRuntime.InputTokens == 1200 &&
                        parsedPiRuntime.OutputTokens == 80 &&
                        parsedPiRuntime.ContextTokens == 23280 &&
                        parsedPiRuntime.ContextWindowTokens == 120000,
                        "Pi runtime fallback reads model, usage, and context telemetry");
                }
                finally
                {
                    try { Directory.Delete(piRuntimeRoot, true); } catch { }
                }

                // Hook routing: Grok env must write logs/grok-status.jsonl only
                // and normalize snake_case event names to PascalCase.
                string hookIsoHome = Path.Combine(Path.GetTempPath(),
                    "agent-halo-hook-iso-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(AgentHaloPaths.LogsDirectory(hookIsoHome));
                int grokHookCode = ClaudeHookStatusWriter.WriteForTest(
                    eventName: "pre_tool_use",
                    home: hookIsoHome,
                    grokSessionId: "test-grok-session",
                    grokHookEvent: "PreToolUse",
                    stdinJson: "{\"sessionId\":\"test-grok-session\",\"cwd\":\"/tmp/proj\"," +
                        "\"toolName\":\"run_terminal_command\"," +
                        "\"permissionMode\":\"auto\"}");
                Assert(grokHookCode == 0, "grok hook writer exit 0");
                string grokStatusPath = AgentHaloPaths.GrokStatusLog(hookIsoHome);
                string claudeStatusPath = AgentHaloPaths.ClaudeStatusLog(hookIsoHome);
                Assert(File.Exists(grokStatusPath), "Grok path writes logs/grok-status.jsonl");
                string grokHookText = File.ReadAllText(grokStatusPath);
                Assert(grokHookText.IndexOf("grok-hook", StringComparison.Ordinal) >= 0,
                    "source grok-hook");
                Assert(grokHookText.IndexOf("\"PreToolUse\"", StringComparison.Ordinal) >= 0,
                    "snake_case event normalizes to PreToolUse");
                Assert(grokHookText.IndexOf("\"permissionMode\":\"auto\"",
                    StringComparison.Ordinal) >= 0,
                    "hook should persist permissionMode for Auto ring gating");
                Assert(!File.Exists(claudeStatusPath) ||
                    File.ReadAllText(claudeStatusPath).IndexOf("test-grok-session",
                        StringComparison.Ordinal) < 0,
                    "Grok session must not appear in claude jsonl");

                // Claude path without GROK env must not touch grok jsonl.
                ClaudeHookStatusWriter.WriteForTest("PreToolUse", hookIsoHome, null, null,
                    "{\"sessionId\":\"claude-1\",\"cwd\":\"/tmp/c\",\"toolName\":\"Bash\"}");
                string claudeHookText = File.ReadAllText(claudeStatusPath);
                Assert(claudeHookText.IndexOf("claude-hook", StringComparison.Ordinal) >= 0,
                    "claude source");
                Assert(File.ReadAllText(grokStatusPath).IndexOf("claude-1",
                    StringComparison.Ordinal) < 0,
                    "Claude session must not appear in grok jsonl");
                Assert(String.Equals(
                    ClaudeHookStatusWriter.NormalizeEventName("pre_tool_use"),
                    "PreToolUse", StringComparison.Ordinal),
                    "NormalizeEventName pre_tool_use");
                Assert(String.Equals(
                    ClaudeHookStatusWriter.NormalizeEventName("PreToolUse"),
                    "PreToolUse", StringComparison.Ordinal),
                    "NormalizeEventName keeps PascalCase");
                try
                {
                    Directory.Delete(hookIsoHome, true);
                }
                catch
                {
                }

                // Grok hook configurator + reducer + active sessions (Task 3)
                string home = Path.Combine(Path.GetTempPath(),
                    "agent-halo-grok-cfg-" + Guid.NewGuid().ToString("N"));
                string fakeExe = Path.Combine(home, "AgentHalo.exe");
                Directory.CreateDirectory(home);
                File.WriteAllText(fakeExe, "x");
                GrokHookConfigurator.Configure(home, fakeExe);
                string hooksPath = Path.Combine(home, ".grok", "hooks",
                    "agent-halo-status.json");
                Assert(File.Exists(hooksPath), "writes agent-halo-status.json");
                string hooksJson = File.ReadAllText(hooksPath);
                Assert(hooksJson.IndexOf("--claude-hook", StringComparison.Ordinal) >= 0,
                    "command uses --claude-hook");
                Assert(hooksJson.IndexOf("UserPromptSubmit", StringComparison.Ordinal) >= 0,
                    "registers UserPromptSubmit");
                // Idempotent: second call does not throw; content still valid
                GrokHookConfigurator.Configure(home, fakeExe);
                Assert(File.Exists(hooksPath) &&
                    File.ReadAllText(hooksPath).IndexOf("--claude-hook",
                        StringComparison.Ordinal) >= 0,
                    "Grok hook configurator is idempotent");
                Assert(GrokHookConfigurator.IsConfiguredForTest(
                    hooksPath, fakeExe), "current Grok hook executable is configured");
                string movedExe = Path.Combine(home, "moved", "AgentHalo.exe");
                Directory.CreateDirectory(Path.GetDirectoryName(movedExe));
                File.WriteAllText(movedExe, "x");
                Assert(!GrokHookConfigurator.IsConfiguredForTest(
                    hooksPath, movedExe),
                    "stale Grok hook executable path is not accepted");
                GrokHookConfigurator.Configure(home, movedExe);
                Assert(GrokHookConfigurator.IsConfiguredForTest(
                    hooksPath, movedExe),
                    "Grok hook executable path is rewritten after move");
                Assert(!GrokHookConfigurator.IsConfiguredForTest(
                    hooksPath, fakeExe),
                    "old Grok hook executable path is removed after rewrite");

                GrokHookStatusReducer r = new GrokHookStatusReducer("s1");
                DateTime t0 = new DateTime(2026, 7, 25, 0, 0, 0, DateTimeKind.Utc);
                r.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:01Z\",\"event\":\"UserPromptSubmit\",\"sessionId\":\"s1\",\"cwd\":\"/p/AgentHalo\",\"permissionMode\":\"auto\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(1));
                Assert(r.Snapshot.Agent == AgentKind.Grok, "agent kind Grok");
                Assert(r.Snapshot.State == HaloState.Thinking, "prompt -> thinking");
                r.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:02Z\",\"event\":\"PreToolUse\",\"sessionId\":\"s1\",\"cwd\":\"/p/AgentHalo\",\"toolName\":\"run_terminal_command\",\"permissionMode\":\"auto\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(2));
                r.ApplyWorkingVisibility(t0.AddSeconds(3));
                Assert(r.Snapshot.State == HaloState.Working, "tool -> working");
                // Auto mode: permission_prompt must not flash purple.
                r.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:04Z\",\"event\":\"Notification\",\"sessionId\":\"s1\",\"notificationType\":\"permission_prompt\",\"permissionMode\":\"auto\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(4));
                Assert(r.Snapshot.State == HaloState.Working,
                    "permission_prompt after PreToolUse must not become attention");
                r.ApplyWorkingVisibility(t0.AddSeconds(4).AddMilliseconds(
                    (int)(GrokHookStatusReducer.PendingPermissionAttentionDelaySeconds * 1000) + 500));
                Assert(r.Snapshot.State == HaloState.Working,
                    "auto mode stays working after permission delay");
                r.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:05Z\",\"event\":\"Stop\",\"sessionId\":\"s1\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(5));
                Assert(r.Snapshot.State == HaloState.Done, "stop -> done");

                // default mode: human wait after PreToolUse becomes attention after delay.
                GrokHookStatusReducer human = new GrokHookStatusReducer("s-human");
                human.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:01Z\",\"event\":\"UserPromptSubmit\",\"sessionId\":\"s-human\",\"cwd\":\"/p\",\"permissionMode\":\"default\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(1));
                human.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:02Z\",\"event\":\"PreToolUse\",\"sessionId\":\"s-human\",\"cwd\":\"/p\",\"toolName\":\"run_terminal_command\",\"permissionMode\":\"default\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(2));
                DateTime requestedAt = t0.AddSeconds(2).AddMilliseconds(20);
                human.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:02.020Z\",\"event\":\"Notification\",\"sessionId\":\"s-human\",\"notificationType\":\"permission_prompt\",\"permissionMode\":\"default\",\"source\":\"grok-hook\"}",
                    requestedAt);
                Assert(human.Snapshot.State == HaloState.Working,
                    "default mode arms pending without instant purple");
                human.ApplyWorkingVisibility(requestedAt.AddSeconds(
                    GrokHookStatusReducer.PendingPermissionAttentionDelaySeconds + 0.05));
                Assert(human.Snapshot.State == HaloState.Attention,
                    "human wait after delay -> attention");
                Assert(String.Equals(human.Snapshot.Action, "Awaiting permission",
                    StringComparison.Ordinal), "human wait action");
                // Human allow restores working — Grok does not re-emit PreToolUse
                // before PostToolUse, so tool execution UI must be recovered.
                human.ApplyPermissionResolved("allow", 9678,
                    t0.AddSeconds(12));
                Assert(human.Snapshot.State == HaloState.Working,
                    "human allow restores working (tool still running)");
                Assert(String.Equals(human.Snapshot.Action, "Running command",
                    StringComparison.Ordinal),
                    "human allow restores tool action");
                Assert(human.Snapshot.Active,
                    "human allow keeps turn active during tool run");
                human.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:15Z\",\"event\":\"PostToolUse\",\"sessionId\":\"s-human\",\"cwd\":\"/p\",\"toolName\":\"run_terminal_command\",\"permissionMode\":\"default\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(15));
                Assert(human.Snapshot.State == HaloState.Working,
                    "PostToolUse after allow -> reviewing");
                Assert(String.Equals(human.Snapshot.Action, "Reviewing result",
                    StringComparison.Ordinal),
                    "PostToolUse action after restored working");

                // Auto shell permission_requested stays working with multi-second wait_ms.
                GrokHookStatusReducer autoShell = new GrokHookStatusReducer("s-auto-shell");
                autoShell.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:01Z\",\"event\":\"UserPromptSubmit\",\"sessionId\":\"s-auto-shell\",\"cwd\":\"/p\",\"permissionMode\":\"auto\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(1));
                autoShell.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:02Z\",\"event\":\"PreToolUse\",\"sessionId\":\"s-auto-shell\",\"cwd\":\"/p\",\"toolName\":\"run_terminal_command\",\"permissionMode\":\"auto\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(2));
                autoShell.ApplyPermissionRequested(
                    t0.AddSeconds(2).AddMilliseconds(20),
                    t0.AddSeconds(2).AddMilliseconds(20));
                autoShell.ApplyWorkingVisibility(t0.AddSeconds(5));
                Assert(autoShell.Snapshot.State == HaloState.Working,
                    "auto mode permission_requested never becomes attention");
                autoShell.ApplyPermissionResolved("allow", 2500, t0.AddSeconds(5));
                Assert(autoShell.Snapshot.State == HaloState.Working,
                    "auto resolve keeps working");
                GrokHookStatusReducer failed =
                    new GrokHookStatusReducer("failed-session");
                failed.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:06Z\",\"event\":\"StopFailure\",\"sessionId\":\"failed-session\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(6));
                Assert(failed.Snapshot.State == HaloState.Error,
                    "stop failure -> error");
                Assert(!GrokHookStatusMonitor.ShouldPruneSnapshot(
                    failed.Snapshot, t0.AddMinutes(30)),
                    "Grok error snapshot is retained for 30 minutes");
                Assert(GrokHookStatusMonitor.ShouldPruneSnapshot(
                    failed.Snapshot, t0.AddHours(1).AddSeconds(7)),
                    "Grok error snapshot expires after one hour");

                // Long human permission waits must not prune into STANDBY.
                SessionSnapshot longAttention = new SessionSnapshot
                {
                    ThreadId = "long-attn",
                    State = HaloState.Attention,
                    Action = "Awaiting permission",
                    Active = true,
                    LastEventUtc = t0.AddMinutes(-30)
                };
                Assert(!GrokHookStatusMonitor.ShouldPruneSnapshot(
                    longAttention, t0),
                    "Grok attention is not age-pruned after 30 minutes");
                Assert(!ClaudeHookStatusMonitor.ShouldPruneSnapshot(
                    longAttention, t0),
                    "Claude attention is not age-pruned after 30 minutes");
                Assert(HaloWindow.IsHookActivitySessionVisible(
                    longAttention, t0, true),
                    "Grok/Claude aggregate keeps long-held attention");
                Assert(!HaloWindow.IsHookActivitySessionVisible(
                    longAttention, t0, false),
                    "ended hook session cannot keep stale attention visible");
                SessionSnapshot staleWorkingSnap = new SessionSnapshot
                {
                    ThreadId = "stale-work",
                    State = HaloState.Working,
                    Action = "Running command",
                    Active = true,
                    LastEventUtc = t0.AddMinutes(-15)
                };
                Assert(GrokHookStatusMonitor.ShouldPruneSnapshot(
                    staleWorkingSnap, t0),
                    "Grok stale working is still pruned");
                Assert(ClaudeHookStatusMonitor.ShouldPruneSnapshot(
                    staleWorkingSnap, t0),
                    "Claude stale working is still pruned");
                Assert(!HaloWindow.IsHookActivitySessionVisible(
                    staleWorkingSnap, t0, true),
                    "stale working still hidden from aggregate after 10m");

                // Esc cancel skips Stop hooks; map turn cancel onto fault ring.
                GrokHookStatusReducer cancelReducer =
                    new GrokHookStatusReducer("esc-session");
                cancelReducer.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:10Z\",\"event\":\"UserPromptSubmit\",\"sessionId\":\"esc-session\",\"cwd\":\"/p/AgentHalo\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(10));
                cancelReducer.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:12Z\",\"event\":\"PreToolUse\",\"sessionId\":\"esc-session\",\"cwd\":\"/p/AgentHalo\",\"toolName\":\"read_file\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(12));
                cancelReducer.ApplyWorkingVisibility(t0.AddSeconds(13));
                Assert(cancelReducer.Snapshot.State == HaloState.Working,
                    "precondition working before esc cancel");
                cancelReducer.ApplyTurnCancelled(t0.AddSeconds(14));
                Assert(cancelReducer.Snapshot.State == HaloState.Error,
                    "esc cancel -> error ring");
                Assert(String.Equals(cancelReducer.Snapshot.Action, "Interrupted",
                    StringComparison.Ordinal),
                    "esc cancel action is Interrupted");
                Assert(!cancelReducer.Snapshot.Active,
                    "esc cancel clears active turn");
                GrokHookStatusReducer idleCancel =
                    new GrokHookStatusReducer("idle-esc");
                idleCancel.ApplyTurnCancelled(t0.AddSeconds(15));
                Assert(idleCancel.Snapshot.State == HaloState.Idle,
                    "cancel on idle Ready is a no-op");

                // Steer soft-cancel must not paint the red fault ring.
                GrokHookStatusReducer steerReducer =
                    new GrokHookStatusReducer("steer-session");
                steerReducer.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:10Z\",\"event\":\"UserPromptSubmit\",\"sessionId\":\"steer-session\",\"cwd\":\"/p/AgentHalo\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(10));
                steerReducer.Consume(
                    "{\"timestamp\":\"2026-07-25T00:00:12Z\",\"event\":\"PreToolUse\",\"sessionId\":\"steer-session\",\"cwd\":\"/p/AgentHalo\",\"toolName\":\"read_file\",\"source\":\"grok-hook\"}",
                    t0.AddSeconds(12));
                steerReducer.ApplyWorkingVisibility(t0.AddSeconds(13));
                Assert(steerReducer.Snapshot.State == HaloState.Working,
                    "precondition working before steer cancel");
                steerReducer.ApplySteerCancel(t0.AddSeconds(14));
                Assert(steerReducer.Snapshot.State == HaloState.Idle,
                    "steer cancel -> idle not error");
                Assert(String.Equals(steerReducer.Snapshot.Action, "Ready",
                    StringComparison.Ordinal),
                    "steer cancel action is Ready");
                Assert(!steerReducer.Snapshot.Active,
                    "steer cancel clears active turn");

                // Incremental events.jsonl tail + monitor wiring.
                string cancelHome = Path.Combine(Path.GetTempPath(),
                    "agent-halo-grok-esc-" + Guid.NewGuid().ToString("N"));
                try
                {
                    string statusPath = Path.Combine(cancelHome, "grok-status.jsonl");
                    string sessionsRoot = Path.Combine(cancelHome, "sessions");
                    string cwd = "/tmp/AgentHaloCancelTest";
                    string sessionId = "sess-esc-1";
                    string encoded =
                        GrokSessionContextReader.EncodeWorkspaceDirectory(cwd);
                    string sessionDir = Path.Combine(sessionsRoot, encoded, sessionId);
                    Directory.CreateDirectory(sessionDir);
                    DateTime cancelBaseUtc = DateTime.UtcNow.AddSeconds(-6);
                    File.WriteAllText(statusPath,
                        "{\"timestamp\":\"" + cancelBaseUtc.AddSeconds(1).ToString("o") + "\",\"event\":\"UserPromptSubmit\",\"sessionId\":\"" + sessionId + "\",\"cwd\":\"" + cwd + "\",\"source\":\"grok-hook\"}\n" +
                        "{\"timestamp\":\"" + cancelBaseUtc.AddSeconds(3).ToString("o") + "\",\"event\":\"PreToolUse\",\"sessionId\":\"" + sessionId + "\",\"cwd\":\"" + cwd + "\",\"toolName\":\"read_file\",\"source\":\"grok-hook\"}\n",
                        Encoding.UTF8);
                    File.WriteAllText(Path.Combine(sessionDir, "events.jsonl"),
                        "{\"ts\":\"" + cancelBaseUtc.AddSeconds(1.5).ToString("o") + "\",\"type\":\"turn_started\"}\n",
                        Encoding.UTF8);

                    GrokHookStatusMonitor cancelMonitor =
                        new GrokHookStatusMonitor(statusPath, sessionsRoot);
                    Assert(cancelMonitor.Refresh(), "hooks load for esc monitor");
                    SessionSnapshot workingSnap =
                        cancelMonitor.Snapshots().FirstOrDefault();
                    Assert(workingSnap != null &&
                        workingSnap.State == HaloState.Working,
                        "precondition: working from PreToolUse");

                    File.AppendAllText(Path.Combine(sessionDir, "events.jsonl"),
                        "{\"ts\":\"" + cancelBaseUtc.AddSeconds(4).ToString("o") + "\",\"type\":\"turn_ended\",\"outcome\":\"cancelled\",\"cancellation_category\":\"mid_turn_abort\",\"cancellation_context\":{\"trigger\":\"esc\"}}\n",
                        Encoding.UTF8);
                    Assert(cancelMonitor.Refresh(),
                        "cancel via events should change state");
                    SessionSnapshot interruptedSnap =
                        cancelMonitor.Snapshots().FirstOrDefault();
                    Assert(interruptedSnap != null &&
                        interruptedSnap.State == HaloState.Error,
                        "esc cancel via events.jsonl -> error");
                    Assert(interruptedSnap != null &&
                        String.Equals(interruptedSnap.Action, "Interrupted",
                            StringComparison.Ordinal),
                        "esc cancel action Interrupted");
                    Assert(interruptedSnap != null && !interruptedSnap.Active,
                        "esc cancel not active");

                    GrokSessionTurnEventsReader turnReader =
                        new GrokSessionTurnEventsReader();
                    string seedPath = Path.Combine(cancelHome, "seed-events.jsonl");
                    File.WriteAllText(seedPath,
                        "{\"ts\":\"2026-07-30T08:00:00.000Z\",\"type\":\"turn_started\"}\n" +
                        "{\"ts\":\"2026-07-30T08:00:01.000Z\",\"type\":\"phase_changed\",\"phase\":\"thinking\"}\n",
                        Encoding.UTF8);
                    GrokSessionEventsDelta seedDelta = turnReader.Poll(seedPath);
                    Assert(seedDelta != null && seedDelta.IsEmpty,
                        "no turn_ended yet");
                    File.AppendAllText(seedPath,
                        "{\"ts\":\"2026-07-30T08:00:05.000Z\",\"type\":\"turn_ended\",\"outcome\":\"cancelled\"}\n",
                        Encoding.UTF8);
                    GrokSessionEventsDelta endedDelta = turnReader.Poll(seedPath);
                    Assert(endedDelta != null &&
                        endedDelta.TurnEnd != null &&
                        endedDelta.TurnEnd.Outcome ==
                            GrokSessionTurnEndOutcome.Cancelled,
                        "poll surfaces cancelled turn_ended");
                    GrokSessionEventsDelta secondPoll = turnReader.Poll(seedPath);
                    Assert(secondPoll != null && secondPoll.IsEmpty,
                        "second poll with no growth is empty");

                    // Same-chunk cancel + cancel_then_send start supersedes fault.
                    string steerPath = Path.Combine(cancelHome, "steer-events.jsonl");
                    File.WriteAllText(steerPath,
                        "{\"ts\":\"2026-07-30T08:00:00.000Z\",\"type\":\"turn_started\"}\n" +
                        "{\"ts\":\"2026-07-30T08:00:04.000Z\",\"type\":\"turn_ended\",\"outcome\":\"cancelled\",\"cancellation_category\":\"mid_turn_abort\",\"cancellation_context\":{\"trigger\":\"esc\"}}\n" +
                        "{\"ts\":\"2026-07-30T08:00:04.010Z\",\"type\":\"turn_started\",\"redirect_kind\":\"cancel_then_send\"}\n",
                        Encoding.UTF8);
                    GrokSessionTurnEventsReader steerReader =
                        new GrokSessionTurnEventsReader();
                    GrokSessionEventsDelta steerDelta = steerReader.Poll(steerPath);
                    Assert(steerDelta != null && steerDelta.TurnEnd == null,
                        "steer start supersedes cancelled turn_ended in same chunk");
                    Assert(steerDelta != null && steerDelta.TurnStart != null &&
                        String.Equals(steerDelta.TurnStart.RedirectKind,
                            "cancel_then_send", StringComparison.Ordinal),
                        "redirect_kind cancel_then_send parsed");
                    Assert(steerDelta != null && steerDelta.TurnStart != null &&
                        steerDelta.TurnStart.IsSteerRedirect,
                        "cancel_then_send is steer redirect");

                    // send_now trigger is steer-like.
                    string sendNowPath = Path.Combine(cancelHome, "send-now.jsonl");
                    File.WriteAllText(sendNowPath,
                        "{\"ts\":\"2026-07-30T08:00:04.000Z\",\"type\":\"turn_ended\",\"outcome\":\"cancelled\",\"cancellation_category\":\"mid_turn_abort\",\"cancellation_context\":{\"trigger\":\"send_now\"}}\n",
                        Encoding.UTF8);
                    GrokSessionTurnEventsReader sendNowReader =
                        new GrokSessionTurnEventsReader();
                    GrokSessionEventsDelta sendNowDelta = sendNowReader.Poll(sendNowPath);
                    Assert(sendNowDelta != null && sendNowDelta.TurnEnd != null &&
                        sendNowDelta.TurnEnd.IsSteerLikeCancel,
                        "send_now trigger is steer-like cancel");
                }
                finally
                {
                    try
                    {
                        Directory.Delete(cancelHome, true);
                    }
                    catch
                    {
                    }
                }

                // Sent now race: UserPromptSubmit ~4ms after cancel must not go red.
                string sendNowHome = Path.Combine(Path.GetTempPath(),
                    "agent-halo-grok-send-now-" + Guid.NewGuid().ToString("N"));
                try
                {
                    string statusPath = Path.Combine(sendNowHome, "grok-status.jsonl");
                    string sessionsRoot = Path.Combine(sendNowHome, "sessions");
                    string cwd = "/tmp/AgentHaloSendNowTest";
                    string sessionId = "sess-send-now-1";
                    string encoded =
                        GrokSessionContextReader.EncodeWorkspaceDirectory(cwd);
                    string sessionDir = Path.Combine(sessionsRoot, encoded, sessionId);
                    Directory.CreateDirectory(sessionDir);
                    DateTime sendNowBaseUtc = DateTime.UtcNow.AddSeconds(-6);
                    File.WriteAllText(statusPath,
                        "{\"timestamp\":\"" + sendNowBaseUtc.AddSeconds(1).ToString("o") + "\",\"event\":\"UserPromptSubmit\",\"sessionId\":\"" + sessionId + "\",\"cwd\":\"" + cwd + "\",\"source\":\"grok-hook\"}\n" +
                        "{\"timestamp\":\"" + sendNowBaseUtc.AddSeconds(3).ToString("o") + "\",\"event\":\"PreToolUse\",\"sessionId\":\"" + sessionId + "\",\"cwd\":\"" + cwd + "\",\"toolName\":\"read_file\",\"source\":\"grok-hook\"}\n",
                        Encoding.UTF8);
                    File.WriteAllText(Path.Combine(sessionDir, "events.jsonl"),
                        "{\"ts\":\"" + sendNowBaseUtc.AddSeconds(1.5).ToString("o") + "\",\"type\":\"turn_started\"}\n",
                        Encoding.UTF8);

                    GrokHookStatusMonitor sendNowMonitor =
                        new GrokHookStatusMonitor(statusPath, sessionsRoot);
                    Assert(sendNowMonitor.Refresh(), "hooks load for send_now");
                    SessionSnapshot workingSnap =
                        sendNowMonitor.Snapshots().FirstOrDefault();
                    Assert(workingSnap != null &&
                        workingSnap.State == HaloState.Working,
                        "precondition: working before send_now");

                    File.AppendAllText(statusPath,
                        "{\"timestamp\":\"" + sendNowBaseUtc.AddSeconds(4.004).ToString("o") + "\",\"event\":\"UserPromptSubmit\",\"sessionId\":\"" + sessionId + "\",\"cwd\":\"" + cwd + "\",\"source\":\"grok-hook\"}\n",
                        Encoding.UTF8);
                    File.AppendAllText(Path.Combine(sessionDir, "events.jsonl"),
                        "{\"ts\":\"" + sendNowBaseUtc.AddSeconds(4).ToString("o") + "\",\"type\":\"turn_ended\",\"outcome\":\"cancelled\",\"cancellation_category\":\"mid_turn_abort\",\"cancellation_context\":{\"trigger\":\"send_now\"}}\n" +
                        "{\"ts\":\"" + sendNowBaseUtc.AddSeconds(4.004).ToString("o") + "\",\"type\":\"turn_started\",\"redirect_kind\":\"queued_after_cancel\"}\n",
                        Encoding.UTF8);
                    Assert(sendNowMonitor.Refresh(), "send_now refresh changes state");
                    SessionSnapshot afterSteer =
                        sendNowMonitor.Snapshots().FirstOrDefault();
                    Assert(afterSteer != null &&
                        afterSteer.State == HaloState.Thinking,
                        "send_now keeps thinking from UserPromptSubmit");
                    Assert(afterSteer != null &&
                        afterSteer.State != HaloState.Error,
                        "send_now must not paint red Interrupted");
                    Assert(afterSteer != null && afterSteer.Active,
                        "send_now new turn is active");
                }
                finally
                {
                    try
                    {
                        Directory.Delete(sendNowHome, true);
                    }
                    catch
                    {
                    }
                }

                string grokDir = Path.Combine(home, ".grok");
                Directory.CreateDirectory(grokDir);
                File.WriteAllText(Path.Combine(grokDir, "active_sessions.json"),
                    "[{\"session_id\":\"abc\",\"cwd\":\"/tmp/x\"}]");
                Assert(GrokActiveSessionsReader.HasLiveSession(home),
                    "array entry without pid counts as present");
                Assert(GrokActiveSessionsReader.LiveSessionIds(home).Contains("abc"),
                    "Grok active sessions reader exposes the live session id");
                try
                {
                    Directory.Delete(home, true);
                }
                catch
                {
                }

                // HaloWindow Grok focus aggregate filters mixed Claude+Grok sessions
                DateTime aggNow = DateTime.UtcNow;
                List<SessionSnapshot> mixedGrokAgg = new List<SessionSnapshot>
                {
                    new SessionSnapshot
                    {
                        ThreadId = "c1",
                        Agent = AgentKind.ClaudeCode,
                        State = HaloState.Working,
                        Active = true,
                        LastEventUtc = aggNow,
                        ProjectName = "C",
                        Action = "Edit"
                    },
                    new SessionSnapshot
                    {
                        ThreadId = "g1",
                        Agent = AgentKind.Grok,
                        State = HaloState.Working,
                        Active = true,
                        LastEventUtc = aggNow,
                        ProjectName = "GrokProject",
                        Action = "Running command"
                    }
                };
                AggregateSnapshot grokAgg = HaloWindow.BuildGrokAggregateForTest(
                    mixedGrokAgg, false,
                    new HashSet<string>(new string[] { "g1" }), aggNow);
                Assert(grokAgg.FocusedAgent == AgentKind.Grok,
                    "Grok aggregate stamps FocusedAgent.Grok");
                Assert(grokAgg.State == HaloState.Working,
                    "Grok aggregate uses Grok session state");
                Assert(grokAgg.Sessions != null && grokAgg.Sessions.Count == 1 &&
                    String.Equals(grokAgg.Sessions[0].ThreadId, "g1",
                        StringComparison.Ordinal),
                    "Grok aggregate filters out Claude sessions");
                AggregateSnapshot idleGrokPresent = HaloWindow.BuildGrokAggregateForTest(
                    new List<SessionSnapshot>(), false,
                    new HashSet<string>(new string[] { "g-live" }), aggNow);
                Assert(idleGrokPresent.State == HaloState.Idle &&
                    idleGrokPresent.FocusedAgent == AgentKind.Grok,
                    "empty Grok sessions → Idle (standby applied in RefreshState)");
                AggregateSnapshot idleGrokOffline = HaloWindow.BuildGrokAggregateForTest(
                    new List<SessionSnapshot>(), false,
                    new HashSet<string>(), aggNow);
                Assert(idleGrokOffline.State == HaloState.Idle,
                    "empty Grok offline → Idle");
                AggregateSnapshot pausedGrok = HaloWindow.BuildGrokAggregateForTest(
                    mixedGrokAgg, true,
                    new HashSet<string>(new string[] { "g1" }), aggNow);
                Assert(pausedGrok.State == HaloState.Idle &&
                    String.Equals(pausedGrok.Label, "PAUSED", StringComparison.Ordinal),
                    "paused Grok aggregate is PAUSED");
                List<SessionSnapshot> longAttnGrok = new List<SessionSnapshot>
                {
                    new SessionSnapshot
                    {
                        ThreadId = "g-attn",
                        Agent = AgentKind.Grok,
                        State = HaloState.Attention,
                        Active = true,
                        LastEventUtc = aggNow.AddMinutes(-25),
                        ProjectName = "Await",
                        Action = "Awaiting permission"
                    }
                };
                AggregateSnapshot attnGrokAgg = HaloWindow.BuildGrokAggregateForTest(
                    longAttnGrok, false,
                    new HashSet<string>(new string[] { "g-attn" }), aggNow);
                Assert(attnGrokAgg.State == HaloState.Attention,
                    "long-held Grok attention remains NEEDS YOU in aggregate");
                Assert(attnGrokAgg.Sessions != null && attnGrokAgg.Sessions.Count == 1,
                    "long-held Grok attention session stays visible");
                AggregateSnapshot endedAttnGrok = HaloWindow.BuildGrokAggregateForTest(
                    longAttnGrok, false, new HashSet<string>(), aggNow);
                Assert(endedAttnGrok.State == HaloState.Idle &&
                    endedAttnGrok.Sessions.Count == 0,
                    "ended Grok session drops stale attention to offline");
                AggregateSnapshot doneGrok = new AggregateSnapshot
                {
                    State = HaloState.Done,
                    FocusedAgent = AgentKind.Grok
                };
                Assert(HaloWindow.ShouldRefreshGrokStateForTick(
                    false, false, doneGrok),
                    "Grok done state keeps refreshing until it settles");
                Assert(HaloWindow.ShouldRefreshGrokStateForTick(
                    false, true, idleGrokPresent),
                    "Grok presence changes refresh standby/offline state");
                Assert(!HaloWindow.ShouldRefreshGrokStateForTick(
                    false, false, idleGrokPresent),
                    "stable idle Grok state does not refresh unnecessarily");
                Assert(HaloWindow.ShouldPollGrokUsageForAgent(AgentKind.Grok) &&
                    !HaloWindow.ShouldPollGrokUsageForAgent(AgentKind.Codex) &&
                    !HaloWindow.ShouldPollGrokUsageForAgent(AgentKind.ClaudeCode),
                    "Grok usage polling is focused-agent gated");
                Assert(HaloWindow.ShouldPollCodexUsageForAgent(AgentKind.Codex) &&
                    !HaloWindow.ShouldPollCodexUsageForAgent(AgentKind.Grok) &&
                    !HaloWindow.ShouldPollCodexUsageForAgent(AgentKind.ClaudeCode),
                    "Codex usage polling is focused-agent gated");
                Assert(!GrokUsageMonitor.Instance.IsActiveForTest,
                    "Grok usage polling starts inactive");
                Assert(!CodexUsageMonitor.Instance.IsActiveForTest,
                    "Codex OAuth usage polling starts inactive");

                UsageFocusGate.Activate(AgentKind.Codex);
                UsageFocusLease focusedCodexLease;
                Assert(UsageFocusGate.TryAcquire(
                    AgentKind.Codex, out focusedCodexLease),
                    "focused Codex acquires OAuth authorization");
                UsageFocusLease inactiveGrokLease;
                Assert(!UsageFocusGate.TryAcquire(
                    AgentKind.Grok, out inactiveGrokLease),
                    "unfocused Grok cannot acquire OAuth authorization");
                UsageFocusGate.Activate(AgentKind.Grok);
                Assert(!UsageFocusGate.IsCurrent(focusedCodexLease),
                    "focus switch invalidates in-flight Codex authorization");
                bool staleCredentialWriteRejected = false;
                try
                {
                    UsageFocusGate.RunCredentialWrite(
                        focusedCodexLease, delegate { return true; });
                }
                catch (OperationCanceledException)
                {
                    staleCredentialWriteRejected = true;
                }
                Assert(staleCredentialWriteRejected,
                    "stale provider cannot write OAuth credentials");
                UsageFocusGate.Activate(AgentKind.Codex);
                Assert(!UsageFocusGate.IsCurrent(focusedCodexLease),
                    "switching back does not revive an old authorization");
                bool abortMappedToCancel = false;
                try
                {
                    UsageFocusGate.ThrowIfInactive(
                        focusedCodexLease,
                        new System.Net.WebException("aborted"));
                }
                catch (OperationCanceledException)
                {
                    abortMappedToCancel = true;
                }
                Assert(abortMappedToCancel,
                    "inactive lease maps transport abort to focus cancel");
                UsageFocusLease liveCodexLease;
                Assert(UsageFocusGate.TryAcquire(
                    AgentKind.Codex, out liveCodexLease),
                    "focused Codex reacquires after switch-back");
                bool liveLeaseKeepsTransportError = false;
                try
                {
                    UsageFocusGate.ThrowIfInactive(
                        liveCodexLease,
                        new System.Net.WebException("network"));
                    liveLeaseKeepsTransportError = true;
                }
                catch (OperationCanceledException)
                {
                    liveLeaseKeepsTransportError = false;
                }
                Assert(liveLeaseKeepsTransportError,
                    "active lease does not rewrite transport errors as cancel");
                UsageFocusGate.DeactivateAll();

                // DetailsWindow offline copy for focused Grok (three-way switch).
                AggregateSnapshot offlineGrok = new AggregateSnapshot
                {
                    State = HaloState.Idle,
                    Label = "OFFLINE",
                    FocusedAgent = AgentKind.Grok,
                    Sessions = new List<SessionSnapshot>()
                };
                string offlineGrokDetail = DetailsWindow.FriendlyStatusDetailForTest(
                    offlineGrok, offlineGrok.Sessions);
                Assert(offlineGrokDetail.IndexOf("Grok",
                        StringComparison.OrdinalIgnoreCase) >= 0 ||
                    offlineGrokDetail == L10n.Instance["status.offline_grok"],
                    "offline grok detail");
                AggregateSnapshot offlineCodex = new AggregateSnapshot
                {
                    State = HaloState.Idle,
                    Label = "OFFLINE",
                    FocusedAgent = AgentKind.Codex,
                    Sessions = new List<SessionSnapshot>()
                };
                Assert(DetailsWindow.FriendlyStatusDetailForTest(
                        offlineCodex, offlineCodex.Sessions) ==
                    L10n.Instance["status.offline_codex"],
                    "offline codex detail still maps to offline_codex");
                AggregateSnapshot offlineClaude = new AggregateSnapshot
                {
                    State = HaloState.Idle,
                    Label = "OFFLINE",
                    FocusedAgent = AgentKind.ClaudeCode,
                    Sessions = new List<SessionSnapshot>()
                };
                Assert(DetailsWindow.FriendlyStatusDetailForTest(
                        offlineClaude, offlineClaude.Sessions) ==
                    L10n.Instance["status.offline_claude"],
                    "offline claude detail still maps to offline_claude");

                // Grok usage mapper + multi-entry auth persist (Task 6)
                string weeklyBody =
                    "{\"config\":{\"creditUsagePercent\":42.5,\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_WEEKLY\",\"start\":\"2026-07-20T00:00:00Z\",\"end\":\"2026-07-27T00:00:00Z\"}}}";
                UsageMetrics mapped;
                Assert(GrokUsageResponseMapper.TryMap(weeklyBody, out mapped), "map weekly");
                Assert(mapped.HasWeekly && !mapped.HasFiveHour && !mapped.HasMonthly,
                    "only weekly");
                Assert(Math.Abs(mapped.WeeklyUsedPercent - 42.5) < 0.01, "percent");
                Assert(mapped.WeeklyResetUtc.Year == 2026, "reset");

                string zeroBody =
                    "{\"config\":{\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_WEEKLY\",\"start\":\"2026-07-20T00:00:00Z\",\"end\":\"2026-07-27T00:00:00Z\"}}}";
                Assert(GrokUsageResponseMapper.TryMap(zeroBody, out mapped) &&
                    mapped.WeeklyUsedPercent == 0, "absent percent is 0");

                string monthlyBody =
                    "{\"config\":{\"creditUsagePercent\":10,\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_MONTHLY\",\"start\":\"2026-07-01T00:00:00Z\",\"end\":\"2026-08-01T00:00:00Z\"}}}";
                Assert(GrokUsageResponseMapper.TryMap(monthlyBody, out mapped) &&
                    !mapped.HasWeekly, "non-weekly does not fake weekly");

                string grokAuthHome = Path.Combine(Path.GetTempPath(),
                    "agent-halo-grok-auth-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(Path.Combine(grokAuthHome, ".grok"));
                string authPath = Path.Combine(grokAuthHome, ".grok", "auth.json");
                File.WriteAllText(authPath,
                    "{\n  \"iss::client-a\": {\"key\":\"tok-a\",\"refresh_token\":\"ra\",\"expires_at\":\"2099-01-01T00:00:00Z\",\"user_id\":\"u1\"},\n  \"iss::client-b\": {\"key\":\"tok-b\",\"refresh_token\":\"rb\",\"expires_at\":\"2099-01-01T00:00:00Z\",\"user_id\":\"u2\"}\n}\n",
                    new UTF8Encoding(false));
                Assert(GrokAuthStore.PersistForTest(grokAuthHome, "tok-a",
                    "tok-a2", "ra2", DateTime.UtcNow.AddHours(1)),
                    "persist tok-a rotation");
                string after = File.ReadAllText(authPath);
                Assert(after.IndexOf("tok-a2", StringComparison.Ordinal) >= 0,
                    "updated access");
                Assert(after.IndexOf("tok-b", StringComparison.Ordinal) >= 0,
                    "other entry preserved");
                File.WriteAllText(authPath, "NOT-JSON", new UTF8Encoding(false));
                bool threw = false;
                bool persistedCorrupt = false;
                try
                {
                    persistedCorrupt = GrokAuthStore.PersistForTest(grokAuthHome,
                        "tok-a2", "tok-a3", "ra3", DateTime.UtcNow.AddHours(1));
                }
                catch
                {
                    threw = true;
                }
                Assert(threw || !persistedCorrupt, "corrupt auth not overwritten");
                Assert(File.ReadAllText(authPath).IndexOf("NOT-JSON",
                    StringComparison.Ordinal) >= 0,
                    "corrupt auth.json left intact");
                try
                {
                    Directory.Delete(grokAuthHome, true);
                }
                catch
                {
                }

                // Grok session context reader (Task 7) — signals / token ratio / live updates
                Assert(String.Equals(
                    GrokSessionContextReader.EncodeWorkspaceDirectory(
                        "/Users/example/work/AgentHalo"),
                    "%2FUsers%2Fexample%2Fwork%2FAgentHalo",
                    StringComparison.Ordinal),
                    "workspace dirs must match Grok percent-encoding");

                string ctxRoot = Path.Combine(Path.GetTempPath(),
                    "agent-halo-grok-ctx-" + Guid.NewGuid().ToString("N"));
                try
                {
                    string cwd = Path.Combine(ctxRoot, "proj");
                    string sessionId = "sess-1";
                    string enc = GrokSessionContextReader.EncodeWorkspaceDirectory(cwd);
                    string sessionDir = Path.Combine(ctxRoot, ".grok", "sessions",
                        enc, sessionId);
                    Directory.CreateDirectory(sessionDir);
                    File.WriteAllText(Path.Combine(sessionDir, "signals.json"),
                        "{\"contextWindowUsage\":26,\"contextTokensUsed\":130000," +
                        "\"contextWindowTokens\":500000,\"primaryModelId\":\"grok-4.5\"}",
                        new UTF8Encoding(false));
                    Dictionary<string, object> summaryInfo =
                        new Dictionary<string, object>();
                    summaryInfo["id"] = sessionId;
                    summaryInfo["cwd"] = cwd;
                    Dictionary<string, object> summaryRoot =
                        new Dictionary<string, object>();
                    summaryRoot["info"] = summaryInfo;
                    summaryRoot["generated_title"] = "Wire Grok context pill";
                    summaryRoot["session_summary"] = "fallback title";
                    summaryRoot["current_model_id"] = "grok-4.5";
                    File.WriteAllText(Path.Combine(sessionDir, "summary.json"),
                        new JavaScriptSerializer().Serialize(summaryRoot),
                        new UTF8Encoding(false));
                    GrokSessionContextSnapshot snap =
                        new GrokSessionContextReader(
                            Path.Combine(ctxRoot, ".grok", "sessions"))
                        .Read(sessionId, cwd);
                    Assert(snap != null && Math.Abs(snap.ContextUsedPercent - 26) < 0.1,
                        "signals percent");
                    Assert(snap.ContextTokensUsed == 130000, "token counters preserved");
                    Assert(snap.ContextWindowTokens == 500000, "window size preserved");
                    Assert(String.Equals(snap.ModelName, "grok-4.5",
                        StringComparison.Ordinal), "model");
                    Assert(String.Equals(snap.SessionTitle, "Wire Grok context pill",
                        StringComparison.Ordinal), "title from summary");
                    Assert(String.Equals(snap.ProjectName, "proj",
                        StringComparison.Ordinal), "project from cwd leaf");

                    GrokSessionContextSnapshot scanned =
                        new GrokSessionContextReader(
                            Path.Combine(ctxRoot, ".grok", "sessions"))
                        .Read(sessionId, null);
                    Assert(scanned != null &&
                        Math.Abs(scanned.ContextUsedPercent - 26) < 0.1,
                        "scan fallback finds the session without cwd");

                    // Token-ratio fallback (no contextWindowUsage field)
                    string ratioSessionId = "session-ratio";
                    string ratioDir = Path.Combine(ctxRoot, ".grok", "sessions",
                        "%2Ftmp", ratioSessionId);
                    Directory.CreateDirectory(ratioDir);
                    File.WriteAllText(Path.Combine(ratioDir, "signals.json"),
                        "{\"contextTokensUsed\":50,\"contextWindowTokens\":200}",
                        new UTF8Encoding(false));
                    GrokSessionContextSnapshot ratioSnap =
                        new GrokSessionContextReader(
                            Path.Combine(ctxRoot, ".grok", "sessions"))
                        .Read(ratioSessionId, null);
                    Assert(ratioSnap != null &&
                        Math.Abs(ratioSnap.ContextUsedPercent - 25) < 0.01,
                        "token ratio fallback");

                    // Live updates.jsonl totalTokens preferred over frozen signals
                    string liveSessionId = "session-live";
                    string liveDir = Path.Combine(ctxRoot, ".grok", "sessions",
                        "%2Ftmp", liveSessionId);
                    Directory.CreateDirectory(liveDir);
                    File.WriteAllText(Path.Combine(liveDir, "signals.json"),
                        "{\"contextWindowUsage\":26,\"contextTokensUsed\":130000," +
                        "\"contextWindowTokens\":500000,\"primaryModelId\":\"grok-4.5\"}",
                        new UTF8Encoding(false));
                    File.WriteAllText(Path.Combine(liveDir, "updates.jsonl"),
                        "{\"timestamp\":1,\"method\":\"session/update\",\"params\":" +
                        "{\"_meta\":{\"totalTokens\":40000},\"update\":" +
                        "{\"sessionUpdate\":\"agent_thought_chunk\"}}}\n" +
                        "{\"timestamp\":2,\"method\":\"session/update\",\"params\":" +
                        "{\"_meta\":{\"totalTokens\":65000},\"update\":" +
                        "{\"sessionUpdate\":\"tool_call\"}}}\n" +
                        "{\"timestamp\":3,\"method\":\"session/update\",\"params\":" +
                        "{\"update\":{\"sessionUpdate\":\"tool_call_update\"}}}\n",
                        new UTF8Encoding(false));
                    GrokSessionContextSnapshot liveSnap =
                        new GrokSessionContextReader(
                            Path.Combine(ctxRoot, ".grok", "sessions"))
                        .Read(liveSessionId, null);
                    Assert(liveSnap != null && liveSnap.ContextTokensUsed == 65000,
                        "live totalTokens must override stale signals counters");
                    Assert(Math.Abs(liveSnap.ContextUsedPercent - 13) < 0.01,
                        "pill percent = liveTokens / contextWindowTokens");
                    Assert(liveSnap.ContextWindowTokens == 500000,
                        "window size still comes from signals");

                    // Brand-new session: updates.jsonl streams totalTokens before
                    // the first end-of-turn signals.json exists (macOS parity).
                    string firstTurnId = "session-first-turn";
                    string firstTurnCwd = Path.Combine(ctxRoot, "first-proj");
                    string firstTurnDir = Path.Combine(ctxRoot, ".grok", "sessions",
                        GrokSessionContextReader.EncodeWorkspaceDirectory(
                            firstTurnCwd),
                        firstTurnId);
                    Directory.CreateDirectory(firstTurnDir);
                    File.WriteAllText(Path.Combine(firstTurnDir, "updates.jsonl"),
                        "{\"timestamp\":1,\"method\":\"session/update\",\"params\":" +
                        "{\"_meta\":{\"totalTokens\":25000},\"update\":" +
                        "{\"sessionUpdate\":\"agent_thought_chunk\"}}}\n" +
                        "{\"timestamp\":2,\"method\":\"session/update\",\"params\":" +
                        "{\"_meta\":{\"totalTokens\":50000},\"update\":" +
                        "{\"sessionUpdate\":\"tool_call\"}}}\n",
                        new UTF8Encoding(false));
                    Dictionary<string, object> firstSummaryInfo =
                        new Dictionary<string, object>();
                    firstSummaryInfo["id"] = firstTurnId;
                    firstSummaryInfo["cwd"] = firstTurnCwd;
                    Dictionary<string, object> firstSummary =
                        new Dictionary<string, object>();
                    firstSummary["info"] = firstSummaryInfo;
                    firstSummary["generated_title"] = "First turn pill";
                    firstSummary["current_model_id"] = "grok-4.5";
                    File.WriteAllText(Path.Combine(firstTurnDir, "summary.json"),
                        new JavaScriptSerializer().Serialize(firstSummary),
                        new UTF8Encoding(false));
                    GrokSessionContextSnapshot firstTurnSnap =
                        new GrokSessionContextReader(
                            Path.Combine(ctxRoot, ".grok", "sessions"))
                        .Read(firstTurnId, firstTurnCwd);
                    Assert(firstTurnSnap != null &&
                        firstTurnSnap.ContextTokensUsed == 50000,
                        "live totalTokens alone must drive the pill");
                    Assert(firstTurnSnap.ContextWindowTokens ==
                        GrokSessionContextReader.DefaultContextWindowTokens,
                        "default window when signals missing");
                    Assert(Math.Abs(firstTurnSnap.ContextUsedPercent - 10) < 0.01,
                        "percent = liveTokens / default window");
                    Assert(String.Equals(firstTurnSnap.SessionTitle,
                        "First turn pill", StringComparison.Ordinal),
                        "summary still loads without signals");
                    Assert(String.Equals(firstTurnSnap.ModelName, "grok-4.5",
                        StringComparison.Ordinal),
                        "model from summary without signals");

                    GrokSessionContextSnapshot firstTurnScanned =
                        new GrokSessionContextReader(
                            Path.Combine(ctxRoot, ".grok", "sessions"))
                        .Read(firstTurnId, null);
                    Assert(firstTurnScanned != null &&
                        firstTurnScanned.ContextTokensUsed == 50000,
                        "scan must find sessions that only have updates.jsonl");
                }
                finally
                {
                    try
                    {
                        Directory.Delete(ctxRoot, true);
                    }
                    catch
                    {
                    }
                }

                // Layout v2: paths + migrator + AppData usage relocation
                string layoutHome = Path.Combine(Path.GetTempPath(),
                    "agent-halo-paths-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(layoutHome);
                string layoutRoot = AgentHaloPaths.Root(layoutHome);
                Assert(AgentHaloPaths.ClaudeStatusLog(layoutHome) ==
                    Path.Combine(layoutRoot, "logs", "claude-status.jsonl"),
                    "claude log path");
                Assert(AgentHaloPaths.GrokStatusLog(layoutHome) ==
                    Path.Combine(layoutRoot, "logs", "grok-status.jsonl"),
                    "grok log path");
                Assert(AgentHaloPaths.UsageSnapshots(layoutHome) ==
                    Path.Combine(layoutRoot, "cache", "usage-snapshots-v1.json"),
                    "usage cache path");
                Assert(AgentHaloPaths.LegacyClaudeStatusLog(layoutHome) ==
                    Path.Combine(layoutRoot, "claude-code-status.jsonl"),
                    "legacy claude log");
                Assert(AgentHaloPaths.LayoutVersion == 2, "layout version");
                Assert(AgentHaloPaths.LegacyUsageSnapshotsInAppData().EndsWith(
                    "usage-snapshots-v1.json"),
                    "appdata legacy usage name");

                Directory.CreateDirectory(layoutRoot);
                string legacyClaude = AgentHaloPaths.LegacyClaudeStatusLog(layoutHome);
                File.WriteAllText(legacyClaude, "claude-old", Encoding.UTF8);
                string fakeAppDataUsage = Path.Combine(layoutHome,
                    "appdata-usage-snapshots-v1.json");
                File.WriteAllText(fakeAppDataUsage, "{\"version\":1}", Encoding.UTF8);
                string layoutLegacyHelper =
                    AgentHaloPaths.LegacyAgentHaloHookExe(layoutHome);
                File.WriteAllText(layoutLegacyHelper, "legacy", Encoding.UTF8);

                AgentHaloLayoutMigrator.MigrateIfNeeded(layoutHome, fakeAppDataUsage);
                Assert(File.Exists(AgentHaloPaths.ClaudeStatusLog(layoutHome)),
                    "migrator moves claude status log");
                Assert(!File.Exists(legacyClaude), "migrator deletes legacy claude log");
                Assert(File.Exists(AgentHaloPaths.UsageSnapshots(layoutHome)),
                    "migrator moves AppData usage into cache");
                Assert(!File.Exists(fakeAppDataUsage),
                    "migrator deletes AppData usage after move");
                // Migrator only moves data; it must not delete staged binaries.
                Assert(File.Exists(layoutLegacyHelper),
                    "migrator leaves AgentHaloHook.exe for configurators to scrub after rewrite");
                Assert(File.ReadAllText(AgentHaloPaths.LayoutVersionFile(layoutHome))
                    .Trim() == "2", "layout version written");
                AgentHaloLayoutMigrator.MigrateIfNeeded(layoutHome, fakeAppDataUsage);
                Assert(File.ReadAllText(AgentHaloPaths.LayoutVersionFile(layoutHome))
                    .Trim() == "2", "migrator is idempotent");
                Assert(AgentHaloPaths.StatusHookExe(layoutHome).EndsWith(
                    Path.Combine("bin", "status-hook.exe")),
                    "stable status-hook path under bin");
                Directory.Delete(layoutHome, true);

                string failedLayoutHome = Path.Combine(
                    Path.GetTempPath(),
                    "agent-halo-paths-failure-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(AgentHaloPaths.LogsDirectory(failedLayoutHome));
                string failedLegacyClaude =
                    AgentHaloPaths.LegacyClaudeStatusLog(failedLayoutHome);
                File.WriteAllText(failedLegacyClaude, "preserve-me", Encoding.UTF8);
                Directory.CreateDirectory(
                    AgentHaloPaths.ClaudeStatusLog(failedLayoutHome));

                AgentHaloLayoutMigrator.MigrateIfNeeded(failedLayoutHome);
                Assert(File.Exists(failedLegacyClaude),
                    "failed migration preserves the legacy source");
                Assert(!File.Exists(AgentHaloPaths.LayoutVersionFile(failedLayoutHome)),
                    "failed migration does not commit layout version");

                Directory.Delete(
                    AgentHaloPaths.ClaudeStatusLog(failedLayoutHome),
                    true);
                AgentHaloLayoutMigrator.MigrateIfNeeded(failedLayoutHome);
                Assert(File.ReadAllText(
                    AgentHaloPaths.ClaudeStatusLog(failedLayoutHome),
                    Encoding.UTF8) == "preserve-me",
                    "migration retry restores preserved data");
                Assert(!File.Exists(failedLegacyClaude),
                    "successful retry removes the legacy source");
                Assert(File.ReadAllText(
                    AgentHaloPaths.LayoutVersionFile(failedLayoutHome),
                    Encoding.UTF8).Trim() == "2",
                    "successful retry commits layout version");
                Directory.Delete(failedLayoutHome, true);

                File.Delete(temp);
                File.WriteAllText(outputPath,
                    "PASS\nLifecycle, usage metrics, panel formatting, and animation checks passed.\n",
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
                    report.AppendLine("Presence: " + aggregate.Presence);
                    report.AppendLine("Turn: " + aggregate.TurnPhase);
                    report.AppendLine("Activity: " + aggregate.Activity);
                    report.AppendLine("Attention: " + aggregate.AttentionReason);
                    report.AppendLine("Failure: " + aggregate.FailureSeverity);
                    report.AppendLine("Evidence: " + aggregate.EvidenceSource +
                        " / " + aggregate.EvidenceKind);
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

        public static int WriteClaudeSnapshot(string outputPath)
        {
            try
            {
                ClaudeHookStatusMonitor monitor = new ClaudeHookStatusMonitor();
                monitor.Refresh();
                ClaudeTranscriptSessionMonitor transcriptMonitor =
                    new ClaudeTranscriptSessionMonitor();
                transcriptMonitor.Refresh();
                List<SessionSnapshot> snapshots = ClaudeStatusSourceMerger.Merge(
                    monitor.Snapshots(), transcriptMonitor.Snapshots());
                List<Dictionary<string, object>> rows =
                    new List<Dictionary<string, object>>();
                foreach (SessionSnapshot snapshot in snapshots)
                {
                    Dictionary<string, object> row =
                        new Dictionary<string, object>();
                    row["threadId"] = snapshot.ThreadId;
                    row["projectName"] = snapshot.ProjectName;
                    row["workingDirectory"] = snapshot.WorkingDirectory;
                    row["state"] = CodexSessionMonitor.StateLabel(snapshot.State);
                    row["action"] = snapshot.Action;
                    row["lastEventUtc"] = snapshot.LastEventUtc.ToString("o",
                        CultureInfo.InvariantCulture);
                    row["completedUtc"] = snapshot.CompletedUtc == DateTime.MinValue
                        ? null : snapshot.CompletedUtc.ToString("o",
                            CultureInfo.InvariantCulture);
                    row["active"] = snapshot.Active;
                    rows.Add(row);
                }
                string json = new JavaScriptSerializer().Serialize(rows);
                File.WriteAllText(outputPath, json, Encoding.UTF8);
                return 0;
            }
            catch (Exception ex)
            {
                File.WriteAllText(outputPath, "FAIL\n" + ex.ToString(), Encoding.UTF8);
                return 1;
            }
        }

        private static string ClaudeHookLine(string eventName, string sessionId,
            string cwd, string toolName, string notificationType, string timestamp)
        {
            Dictionary<string, object> record = new Dictionary<string, object>();
            record["timestamp"] = timestamp;
            record["event"] = eventName;
            record["sessionId"] = sessionId;
            record["cwd"] = cwd;
            record["toolName"] = toolName;
            record["notificationType"] = notificationType;
            record["source"] = "claude-hook";
            return new JavaScriptSerializer().Serialize(record);
        }

        private static string ClaudeHookLine(string eventName, string sessionId,
            string cwd, string timestamp)
        {
            return ClaudeHookLine(eventName, sessionId, cwd, null, null, timestamp);
        }

        private static string ClaudeHookLine(string eventName, string sessionId,
            string cwd, string timestamp, string toolName)
        {
            return ClaudeHookLine(eventName, sessionId, cwd, toolName, null, timestamp);
        }

        private static string ClaudeTranscriptUserLine(string sessionId,
            string cwd, string content, string timestamp)
        {
            Dictionary<string, object> message = new Dictionary<string, object>();
            message["role"] = "user";
            message["content"] = content;
            return ClaudeTranscriptLine("user", null, sessionId, cwd, message,
                timestamp);
        }

        private static string ClaudeTranscriptAssistantToolLine(string sessionId,
            string cwd, string toolName, string timestamp)
        {
            Dictionary<string, object> tool = new Dictionary<string, object>();
            tool["type"] = "tool_use";
            tool["id"] = "toolu_1";
            tool["name"] = toolName;
            Dictionary<string, object> message = new Dictionary<string, object>();
            message["role"] = "assistant";
            message["stop_reason"] = "tool_use";
            message["content"] = new object[] { tool };
            return ClaudeTranscriptLine("assistant", null, sessionId, cwd, message,
                timestamp);
        }

        private static string ClaudeTranscriptToolResultLine(string sessionId,
            string cwd, string timestamp)
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["type"] = "tool_result";
            result["tool_use_id"] = "toolu_1";
            result["content"] = "ok";
            result["is_error"] = false;
            Dictionary<string, object> message = new Dictionary<string, object>();
            message["role"] = "user";
            message["content"] = new object[] { result };
            return ClaudeTranscriptLine("user", null, sessionId, cwd, message,
                timestamp);
        }

        private static string ClaudeTranscriptAssistantTextLine(string sessionId,
            string cwd, string timestamp)
        {
            Dictionary<string, object> text = new Dictionary<string, object>();
            text["type"] = "text";
            text["text"] = "Thinking through the next step.";
            Dictionary<string, object> message = new Dictionary<string, object>();
            message["role"] = "assistant";
            message["stop_reason"] = "end_turn";
            message["content"] = new object[] { text };
            return ClaudeTranscriptLine("assistant", null, sessionId, cwd, message,
                timestamp);
        }

        private static string ClaudeTranscriptTurnDurationLine(string sessionId,
            string cwd, string timestamp)
        {
            return ClaudeTranscriptSystemLine(sessionId, cwd, "turn_duration",
                timestamp);
        }

        private static string ClaudeTranscriptSystemLine(string sessionId,
            string cwd, string subtype, string timestamp)
        {
            return ClaudeTranscriptLine("system", subtype, sessionId, cwd, null,
                timestamp);
        }

        private static string ClaudeTranscriptLine(string type, string subtype,
            string sessionId, string cwd, Dictionary<string, object> message,
            string timestamp)
        {
            Dictionary<string, object> record = new Dictionary<string, object>();
            record["type"] = type;
            if (!String.IsNullOrEmpty(subtype))
            {
                record["subtype"] = subtype;
            }
            record["sessionId"] = sessionId;
            record["cwd"] = cwd;
            record["timestamp"] = timestamp;
            if (message != null)
            {
                record["message"] = message;
            }
            return new JavaScriptSerializer().Serialize(record);
        }

        private static void Assert(bool condition, string name)
        {
            if (!condition)
            {
                throw new InvalidOperationException("Assertion failed: " + name);
            }
        }

        private static int CountOccurrences(string text, string value)
        {
            int count = 0;
            int index = 0;
            while (!String.IsNullOrEmpty(value) &&
                (index = text.IndexOf(value, index, StringComparison.Ordinal)) >= 0)
            {
                count++;
                index += value.Length;
            }
            return count;
        }

        private static double ColorSaturation(MediaColor color)
        {
            double maximum = Math.Max(color.R, Math.Max(color.G, color.B));
            double minimum = Math.Min(color.R, Math.Min(color.G, color.B));
            return maximum <= 0 ? 0 : (maximum - minimum) / maximum;
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
                RenderMenuPreview(outputDirectory);
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
                    "glow-attention-double-pulse.png", 3.35);
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
            panel.SetPreviewMetrics(new UsageMetrics
            {
                HasWeekly = true,
                WeeklyUsedPercent = 76,
                WeeklyResetUtc = DateTime.Today.AddDays(3).AddHours(9)
                    .AddMinutes(36).ToUniversalTime(),
                ContextInputTokens = 202600,
                ContextWindowTokens = 258400
            });
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

            DetailsWindow customCodexPanel = new DetailsWindow();
            customCodexPanel.SetPreviewCodexCustomMetrics(new CodexCustomApiMetrics
            {
                IsCustomApi = true,
                ProjectName = "AgentHalo",
                Model = "glm-5.2",
                InputTokens = 14200,
                OutputTokens = 730,
                ContextTokens = 14200,
                ContextWindowTokens = 128000
            });
            customCodexPanel.UpdateContent(aggregate, sessions);
            FrameworkElement customCodexContent =
                customCodexPanel.Content as FrameworkElement;
            customCodexPanel.Content = null;
            Grid customCodexStage = new Grid();
            customCodexStage.Width = 380;
            customCodexStage.Background = new SolidColorBrush(
                MediaColor.FromRgb(7, 10, 15));
            customCodexContent.Width = 324;
            customCodexContent.Margin = new Thickness(28);
            customCodexStage.Children.Add(customCodexContent);
            customCodexStage.Measure(new System.Windows.Size(380, 1000));
            double customCodexHeight = Math.Ceiling(
                customCodexStage.DesiredSize.Height);
            if (Math.Abs(height - customCodexHeight) > 0.001)
            {
                throw new InvalidOperationException(
                    "Panel preview height mismatch: official Codex=" +
                    height.ToString(CultureInfo.InvariantCulture) +
                    ", custom Codex=" +
                    customCodexHeight.ToString(CultureInfo.InvariantCulture));
            }
            customCodexStage.Height = customCodexHeight;
            customCodexStage.Arrange(new Rect(0, 0, 380, customCodexHeight));
            customCodexStage.UpdateLayout();
            RenderTargetBitmap customCodexBitmap = new RenderTargetBitmap(760,
                (int)(customCodexHeight * 2), 192, 192, PixelFormats.Pbgra32);
            customCodexBitmap.Render(customCodexStage);
            PngBitmapEncoder customCodexEncoder = new PngBitmapEncoder();
            customCodexEncoder.Frames.Add(BitmapFrame.Create(customCodexBitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                "panel-codex-custom.png")))
            {
                customCodexEncoder.Save(stream);
            }
            customCodexPanel.Close();

            List<SessionSnapshot> claudeSessions = new List<SessionSnapshot>();
            claudeSessions.Add(new SessionSnapshot
            {
                ThreadId = "preview-claude",
                ProjectName = "AgentHalo",
                WorkingDirectory = @"C:\work\AgentHalo",
                State = HaloState.Working,
                Action = "Running command",
                Active = true,
                LastEventUtc = now,
                Agent = AgentKind.ClaudeCode
            });
            AggregateSnapshot claudeAggregate = new AggregateSnapshot
            {
                State = HaloState.Working,
                Label = "EXECUTING",
                Detail = "Claude Code · Running command",
                Sessions = claudeSessions,
                FocusedAgent = AgentKind.ClaudeCode
            };
            DetailsWindow claudePanel = new DetailsWindow();
            claudePanel.SetPreviewClaudeMetrics(new ClaudeCodeMetrics
            {
                IsCustomApi = true,
                Model = "deepseek-v4-pro",
                InputTokens = 38000,
                OutputTokens = 1200,
                ContextTokens = 38000,
                ContextWindowTokens = 200000
            });
            claudePanel.UpdateContent(claudeAggregate, claudeSessions);
            FrameworkElement claudeContent = claudePanel.Content as FrameworkElement;
            claudePanel.Content = null;
            Grid claudeStage = new Grid();
            claudeStage.Width = 380;
            claudeStage.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));
            claudeContent.Width = 324;
            claudeContent.Margin = new Thickness(28);
            claudeStage.Children.Add(claudeContent);
            claudeStage.Measure(new System.Windows.Size(380, 1000));
            double claudeHeight = Math.Ceiling(claudeStage.DesiredSize.Height);
            if (Math.Abs(height - claudeHeight) > 0.001)
            {
                throw new InvalidOperationException(
                    "Panel preview height mismatch: Codex=" +
                    height.ToString(CultureInfo.InvariantCulture) +
                    ", Claude=" +
                    claudeHeight.ToString(CultureInfo.InvariantCulture));
            }
            claudeStage.Height = claudeHeight;
            claudeStage.Arrange(new Rect(0, 0, 380, claudeHeight));
            claudeStage.UpdateLayout();
            RenderTargetBitmap claudeBitmap = new RenderTargetBitmap(760,
                (int)(claudeHeight * 2), 192, 192, PixelFormats.Pbgra32);
            claudeBitmap.Render(claudeStage);
            PngBitmapEncoder claudeEncoder = new PngBitmapEncoder();
            claudeEncoder.Frames.Add(BitmapFrame.Create(claudeBitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                "panel-claude-custom.png")))
            {
                claudeEncoder.Save(stream);
            }
            claudePanel.Close();

            List<SessionSnapshot> piSessions = new List<SessionSnapshot>();
            piSessions.Add(new SessionSnapshot
            {
                ThreadId = "preview-pi",
                ProjectName = "AgentHalo",
                WorkingDirectory = @"C:\work\AgentHalo",
                State = HaloState.Thinking,
                Action = "Thinking",
                Active = true,
                LastEventUtc = now,
                Agent = AgentKind.Pi,
                ModelProvider = "openai",
                ModelName = "gpt-5.4",
                TurnInputTokens = 24500,
                TurnOutputTokens = 920,
                ContextInputTokens = 64000,
                ContextWindowTokens = 200000
            });
            AggregateSnapshot piAggregate = new AggregateSnapshot
            {
                State = HaloState.Thinking,
                Label = "THINKING",
                Detail = "AgentHalo · Thinking",
                Sessions = piSessions,
                FocusedAgent = AgentKind.Pi
            };
            DetailsWindow piPanel = new DetailsWindow();
            piPanel.SetEnabledAgents(new[] { AgentKind.Codex, AgentKind.Pi });
            piPanel.UpdateContent(piAggregate, piSessions);
            FrameworkElement piContent = piPanel.Content as FrameworkElement;
            piPanel.Content = null;
            Grid piStage = new Grid();
            piStage.Width = 380;
            piStage.Background = new SolidColorBrush(MediaColor.FromRgb(7, 10, 15));
            piContent.Width = 324;
            piContent.Margin = new Thickness(28);
            piStage.Children.Add(piContent);
            piStage.Measure(new System.Windows.Size(380, 1000));
            double piHeight = Math.Ceiling(piStage.DesiredSize.Height);
            if (Math.Abs(height - piHeight) > 0.001)
            {
                throw new InvalidOperationException(
                    "Panel preview height mismatch: Codex=" +
                    height.ToString(CultureInfo.InvariantCulture) + ", Pi=" +
                    piHeight.ToString(CultureInfo.InvariantCulture));
            }
            piStage.Height = piHeight;
            piStage.Arrange(new Rect(0, 0, 380, piHeight));
            piStage.UpdateLayout();
            RenderTargetBitmap piBitmap = new RenderTargetBitmap(760,
                (int)(piHeight * 2), 192, 192, PixelFormats.Pbgra32);
            piBitmap.Render(piStage);
            PngBitmapEncoder piEncoder = new PngBitmapEncoder();
            piEncoder.Frames.Add(BitmapFrame.Create(piBitmap));
            using (FileStream stream = File.Create(Path.Combine(outputDirectory,
                "panel-pi.png")))
            {
                piEncoder.Save(stream);
            }
            piPanel.Close();
        }

        private static void RenderMenuPreview(string outputDirectory)
        {
            using (Forms.ContextMenuStrip menu = new Forms.ContextMenuStrip())
            {
                Forms.ToolStripMenuItem topmost =
                    new Forms.ToolStripMenuItem("始终置顶");
                topmost.Checked = true;
                menu.Items.Add(topmost);
                menu.Items.Add("开机自动启动");
                Forms.ToolStripMenuItem size =
                    new Forms.ToolStripMenuItem("光环大小");
                size.DropDownItems.Add("75%");
                Forms.ToolStripMenuItem current =
                    new Forms.ToolStripMenuItem("100%");
                current.Checked = true;
                size.DropDownItems.Add(current);
                size.DropDownItems.Add("125%");
                menu.Items.Add(size);
                menu.Items.Add(new Forms.ToolStripSeparator());
                menu.Items.Add("退出");
                Win11MenuRenderer.Apply(menu);
                menu.CreateControl();
                System.Drawing.Size preferred = menu.GetPreferredSize(
                    new System.Drawing.Size(250, 0));
                menu.Size = preferred;
                menu.PerformLayout();
                using (Bitmap menuBitmap = new Bitmap(menu.Width, menu.Height,
                    System.Drawing.Imaging.PixelFormat.Format32bppArgb))
                {
                    menu.DrawToBitmap(menuBitmap,
                        new System.Drawing.Rectangle(0, 0, menu.Width, menu.Height));
                    using (Bitmap stage = new Bitmap(menu.Width + 48, menu.Height + 48,
                        System.Drawing.Imaging.PixelFormat.Format32bppArgb))
                    using (Graphics graphics = Graphics.FromImage(stage))
                    {
                        graphics.Clear(DrawingColor.FromArgb(239, 242, 244));
                        graphics.DrawImageUnscaled(menuBitmap, 24, 24);
                        stage.Save(Path.Combine(outputDirectory, "menu-win11.png"),
                            System.Drawing.Imaging.ImageFormat.Png);
                    }
                }
            }
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
            int[] percents = { 75, 100, 125 };
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

            double benchmarkSeconds = 4;
            double configuredSeconds;
            if (Double.TryParse(Environment.GetEnvironmentVariable(
                    "AGENTHALO_BENCHMARK_SECONDS"), NumberStyles.Float,
                    CultureInfo.InvariantCulture, out configuredSeconds))
            {
                benchmarkSeconds = Math.Max(1, Math.Min(60, configuredSeconds));
            }
            DispatcherTimer measurement = new DispatcherTimer();
            measurement.Interval = TimeSpan.FromSeconds(benchmarkSeconds);
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
}
