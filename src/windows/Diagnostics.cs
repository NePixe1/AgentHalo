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
                    realtimeAction == "Writing answer",
                    "live final answer message -> working");
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
                    realtimeAction == "Writing answer" &&
                    answerStreaming,
                    "live text delta -> answer streaming");
                Assert(!realtime.FindActive(new[] { realtimeCompleted, realtimeTextDelta },
                    out realtimeState, out realtimeAction, out answerStreaming),
                    "live response completed clears answer streaming");
                Assert(!realtime.FindActive(new[] { realtimeTextDone, realtimeTextDelta },
                    out realtimeState, out realtimeAction, out answerStreaming),
                    "live text done clears answer streaming");
                string realtimeInputAdded =
                    "SSE event: {\"type\":\"response.output_item.added\",\"item\":{" +
                    "\"id\":\"input-test\",\"type\":\"function_call\"," +
                    "\"status\":\"in_progress\",\"name\":\"request_user_input\"}}";
                Assert(realtime.FindActive(new[] { realtimeInputAdded },
                    out realtimeState, out realtimeAction) &&
                    realtimeState == HaloState.Attention,
                    "live request_user_input -> attention");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call_output\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working,
                    "custom tool output keeps working visible");

                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\"," +
                    "\"name\":\"request_user_input\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention,
                    "request_user_input -> attention");

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
                    "\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\"," +
                    "\"role\":\"assistant\",\"phase\":\"final_answer\"," +
                    "\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working &&
                    tracker.Snapshot.Action == "Writing answer",
                    "normal final answer -> working");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\"," +
                    "\"phase\":\"final_answer\",\"message\":\"done\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Working,
                    "final answer agent message stays working");
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
                    "plain plan final answer outputs as working");
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
                Assert(tracker.Snapshot.State == HaloState.Working,
                    "plan final answer outputs as working");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention &&
                    tracker.Snapshot.Active,
                    "plan complete waits for user choice");
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"," +
                    "\"collaboration_mode_kind\":\"plan\"}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\"," +
                    "\"item\":{\"type\":\"Plan\",\"text\":\"# Plan\"}}}\n",
                    Encoding.UTF8);
                File.AppendAllText(temp, "{\"timestamp\":\"" + now +
                    "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
                    Encoding.UTF8);
                tracker.Refresh();
                Assert(tracker.Snapshot.State == HaloState.Attention,
                    "completed plan item waits for user choice");
                Assert(GeneratedHaloSpec.ContractVersion == 2,
                    "generated shared contract version");
                Assert(GeneratedHaloSpec.ReleaseVersion == "0.13.0",
                    "generated shared release version");
                Assert(GeneratedHaloSpec.State(HaloState.Attention).Label == "NEEDS YOU",
                    "generated state labels");
                Assert(GeneratedHaloSpec.FriendlyAction("apply_patch") == "Editing files",
                    "generated action rules");
                Assert(GeneratedHaloSpec.ClassifyFailure("server overloaded") ==
                    "服务暂时不可用", "generated failure rules");
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
                Assert(Math.Abs(HaloWindow.DiagnosticSizeForScale(150) - 112) < 0.001,
                    "removed 150 percent size falls back to 100 percent");
                Assert(Math.Abs(HaloWindow.DiagnosticSizeForScale(99) - 112) < 0.001,
                    "invalid halo size falls back to 100 percent");
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
            panel.SetPreviewMetrics(new UsageMetrics
            {
                HasPrimary = true,
                HasSecondary = true,
                PrimaryUsedPercent = 47,
                SecondaryUsedPercent = 76,
                PrimaryResetUtc = DateTime.Today.AddHours(14).AddMinutes(58).ToUniversalTime(),
                SecondaryResetUtc = DateTime.Today.AddDays(3).AddHours(9)
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

