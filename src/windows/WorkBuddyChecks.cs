using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    internal static class WorkBuddyChecks
    {
        internal static void Run()
        {
            DateTime now = DateTime.UtcNow;
            string timestamp = ((long)(now - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds).ToString();
            foreach (var pair in new Dictionary<string, HaloState> {
                {"planning", HaloState.Thinking}, {"working", HaloState.Working}, {"streaming", HaloState.Working},
                {"pending", HaloState.Attention}, {"waiting_permission", HaloState.Attention}, {"waiting_question", HaloState.Attention},
                {"completed", HaloState.Done}, {"error", HaloState.Error}, {"failed", HaloState.Error}, {"idle", HaloState.Idle} })
            {
                var s = WorkBuddyMonitor.ParseRow(new[] {"session", pair.Key, "Fixture", @"C:\work", "model", timestamp, "120", "1000"});
                Check(s.State == pair.Value, pair.Key + " mapping");
                Check(s.ContextInputTokens == 120 && s.ContextWindowTokens == 1000, "context is not inferred from model name");
            }
            var observation = new WorkBuddyMonitor.Observation { Present = true, Connected = true };
            Check(WorkBuddyMonitor.BuildAggregate(observation, false, now, now).Label == "STANDBY", "online without active task is standby");
            observation.Sessions.Add(WorkBuddyMonitor.ParseRow(new[] {"s", "completed", "Fixture", @"C:\work", "model", timestamp, "0", "0"}));
            Check(WorkBuddyMonitor.BuildAggregate(observation, false, now.AddSeconds(-1), now).Label == "COMPLETE", "fresh completion");
            Check(WorkBuddyMonitor.BuildAggregate(observation, false, now.AddSeconds(1), now).Label == "STANDBY", "saved completion is not replayed");
            Check(WorkBuddyMonitor.BuildAggregate(observation, false, now.AddSeconds(-1), now.AddSeconds(9)).Label == "STANDBY", "completion settles");
            observation.Present = false;
            Check(WorkBuddyMonitor.BuildAggregate(observation, false, now, now).Label == "OFFLINE", "exit suppresses saved data");
            Check(WorkBuddyMonitor.BuildAggregate(observation, true, now, now).Label == "PAUSED", "paused");
            observation.Present = true; observation.Connected = false;
            Check(WorkBuddyMonitor.BuildAggregate(observation, false, now, now).Label == "CONNECTING", "unreadable database is not completion");
            var settings = new HaloSettings { EnabledAgents = new List<string> {"codex", "pi"} };
            settings.NormalizeEnabledAgents();
            Check(!settings.IsAgentEnabled(AgentKind.WorkBuddy), "existing monitored choices preserved");
            settings.SetAgentEnabled(AgentKind.WorkBuddy, true); settings.SetFocusedAgent(AgentKind.WorkBuddy);
            Check(settings.GetFocusedAgent() == AgentKind.WorkBuddy, "focus persistence");
            Check(DetailsWindow.ResolveAgentSwitchThumbOffsetForTest(HaloSettings.SupportedAgents(), AgentKind.WorkBuddy) == 180, "six agent switch fits panel");
            var working = WorkBuddyMonitor.ParseRow(new[] {"s", "working", "Fixture", @"C:\Work", "model", timestamp, "0", "0"});
            Check(!WorkBuddyMonitor.IsSessionEligible(working, false, now), "orphaned working record is not activity");
            working.LastEventUtc = now.AddHours(-2);
            Check(WorkBuddyMonitor.IsSessionEligible(working, true, now), "long live tool is not timed out");
            Check(!WorkBuddyMonitor.IsSessionEligible(observation.Sessions[0], false, now.AddMinutes(1)), "completion before app launch is stale");
            CheckTranscript();
            byte[] pixels = { 20, 190, 10, 255, 20, 190, 10, 0 };
            var icon = System.Windows.Media.Imaging.BitmapSource.Create(2, 1, 96, 96,
                System.Windows.Media.PixelFormats.Bgra32, null, pixels, 8);
            var gray = DetailsWindow.CreateGrayscaleIcon(icon);
            gray.CopyPixels(pixels, 8, 0);
            Check(gray.IsFrozen && pixels[0] == pixels[1] && pixels[1] == pixels[2], "inactive icon has no color tint");
            Check(pixels[3] == 255 && pixels[7] == 0, "inactive icon preserves transparency");
        }
        private static void CheckTranscript()
        {
            string home = Path.Combine(Path.GetTempPath(), "agent-halo-workbuddy-test-" + Guid.NewGuid().ToString("N"));
            string directory = Path.Combine(home, ".workbuddy", "projects", "c-Work");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "fixture.jsonl");
            var json = new JavaScriptSerializer();
            var monitor = new WorkBuddyMonitor(home);
            var session = new SessionSnapshot { ThreadId = "fixture", WorkingDirectory = @"C:\Work" };
            try
            {
                string record = "{\"type\":\"message\",\"providerData\":{\"requestModelName\":\"Fixture Model\"},\"message\":{\"usage\":{\"input_tokens\":120,\"output_tokens\":30}}}";
                File.WriteAllText(path, record + "\n", new UTF8Encoding(false));
                monitor.ReadMetrics(session, json);
                Check(session.ModelName == "Fixture Model" && session.TurnInputTokens == 120 && session.TurnOutputTokens == 30, "native transcript metrics");
                string next = "{\"message\":{\"usage\":{\"input_tokens\":240,\"output_tokens\":40}}}";
                File.AppendAllText(path, next, new UTF8Encoding(false));
                monitor.ReadMetrics(session, json);
                Check(session.TurnInputTokens == 120, "incomplete last line keeps last valid usage");
                File.AppendAllText(path, "\n{\"message\":{\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n", new UTF8Encoding(false));
                monitor.ReadMetrics(session, json);
                Check(session.TurnInputTokens == 240 && session.TurnOutputTokens == 40, "append and zero placeholder handling");
                File.WriteAllText(path, "{\"message\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":2}}}\n", new UTF8Encoding(false));
                monitor.ReadMetrics(session, json);
                Check(session.TurnInputTokens == 9, "truncated transcript resets cursor");
                File.WriteAllText(path, "{\"message\":{\"usage\":{\"input_tokens\":8,\"output_tokens\":3}}}\n", new UTF8Encoding(false));
                File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddSeconds(1));
                monitor.ReadMetrics(session, json);
                Check(session.TurnInputTokens == 8 && session.TurnOutputTokens == 3, "same-length replacement refreshes usage");
            }
            finally { Directory.Delete(home, true); }
        }
        internal static int WriteSnapshot(string path)
        {
            var monitor = new WorkBuddyMonitor();
            var observation = monitor.Scan();
            var aggregate = WorkBuddyMonitor.BuildAggregate(observation, false, DateTime.UtcNow.AddMinutes(-20), DateTime.UtcNow);
            // Keep diagnostics free of prompts, transcript text and credentials.
            var data = new { observedAt = DateTime.UtcNow.ToString("o"), present = observation.Present,
                pid = observation.Pid, connected = observation.Connected, state = aggregate.State.ToString(), label = aggregate.Label,
                sessions = observation.Sessions.Select(s => new { id = s.ThreadId, state = s.State.ToString(),
                    evidence = s.EvidenceKind, updatedAt = s.LastEventUtc.ToString("o"), model = s.ModelName,
                    input = s.TurnInputTokens, output = s.TurnOutputTokens, context = s.ContextInputTokens, contextWindow = s.ContextWindowTokens }).ToArray() };
            File.WriteAllText(path, new JavaScriptSerializer().Serialize(data), new UTF8Encoding(false));
            return 0;
        }
        private static void Check(bool success, string detail)
        { if (!success) throw new Exception("WorkBuddy: " + detail); }
    }
}
