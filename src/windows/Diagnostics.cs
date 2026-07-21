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
        public static int WriteCodexUsageSnapshot(string outputPath)
        {
            try
            {
                CodexUsageMonitor monitor = CodexUsageMonitor.Instance;
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
                bool answerStreaming;
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
                Assert(GeneratedHaloSpec.ReleaseVersion == "0.14.0",
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
                File.WriteAllText(mainExe, "fake exe", Encoding.UTF8);
                string legacyHelper = Path.Combine(claudeHome, ".agent-halo",
                    "AgentHaloHook.exe");
                Directory.CreateDirectory(Path.GetDirectoryName(legacyHelper));
                File.WriteAllText(legacyHelper, "legacy", Encoding.UTF8);
                string claudeSettings = Path.Combine(claudeHome, ".claude",
                    "settings.json");
                File.WriteAllText(claudeSettings,
                    "{\"hooks\":{\"Notification\":[{\"hooks\":[{\"type\":\"command\"," +
                    "\"command\":\"user-command\"}]}],\"PreToolUse\":[{\"matcher\":\".*\"," +
                    "\"hooks\":[{\"type\":\"command\",\"command\":\"old.exe AgentHaloHook.exe PreToolUse\"}]}]}}",
                    Encoding.UTF8);
                ClaudeHookConfigurator.Configure(claudeHome, mainExe);
                string configured = File.ReadAllText(claudeSettings, Encoding.UTF8);
                Assert(!File.Exists(legacyHelper),
                    "Claude hook configurator removes legacy helper");
                Assert(configured.Contains("AgentHalo.exe") &&
                    configured.Contains("--claude-hook") &&
                    configured.Contains("PreToolUse") &&
                    configured.Contains("PostToolBatch") &&
                    configured.Contains("PermissionRequest") &&
                    configured.Contains("PermissionDenied") &&
                    configured.Contains("user-command") &&
                    !configured.Contains("AgentHaloHook.exe"),
                    "Claude hook configurator merges settings");
                ClaudeHookConfigurator.Configure(claudeHome, mainExe);
                string configuredAgain = File.ReadAllText(claudeSettings, Encoding.UTF8);
                Assert(CountOccurrences(configuredAgain, "--claude-hook") ==
                    CountOccurrences(configured, "--claude-hook"),
                    "Claude hook configurator is idempotent");

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
                File.WriteAllText(Path.Combine(liveSessions, "live.json"),
                    "{\"status\":\"waiting\",\"pid\":999999,\"sessionId\":\"dead\"}",
                    Encoding.UTF8);
                Assert(!ClaudeLiveSessionReader.HasStandbySession(liveHome),
                    "Claude live session reader ignores dead pid");
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

                HaloSettings presenceSettings = new HaloSettings();
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
}
