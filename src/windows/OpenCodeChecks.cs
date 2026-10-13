using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    internal static class OpenCodeChecks
    {
        internal static void Run()
        {
            DateTime started;
            using (var process = System.Diagnostics.Process.GetCurrentProcess())
                Check(OpenCodeMonitor.TryGetLiveProcessStartTime(process.Id, out started) &&
                    Math.Abs((started - process.StartTime.ToUniversalTime()).TotalSeconds) < 1,
                    "limited query validates process creation time");
            Check(!OpenCodeMonitor.TryGetLiveProcessStartTime(Int32.MaxValue, out started), "dead pid is rejected");
            var json = new JavaScriptSerializer();
            var data = json.DeserializeObject("{\"sessions\":[{\"id\":\"root\",\"title\":\"Monitor tests\",\"state\":\"thinking\",\"input\":120,\"output\":10,\"context\":400,\"contextWindow\":1000},{\"id\":\"child\",\"parentID\":\"root\",\"state\":\"done\"}]}") as Dictionary<string, object>;
            var sessions = OpenCodeMonitor.Parse(data);
            Check(sessions.Count == 1 && sessions[0].State == HaloState.Thinking, "child done does not complete root");
            Check(sessions[0].ContextWindowTokens == 1000 && sessions[0].TurnInputTokens == 120, "OpenCode metrics");
            Check(OpenCodeMonitor.BuildAggregate(sessions, false, false, DateTime.UtcNow).Label == "OFFLINE", "process exit overrides stale active");
            var connecting = OpenCodeMonitor.BuildAggregate(sessions, false, false, DateTime.UtcNow, true);
            Check(connecting.Label == "CONNECTING" && connecting.State == HaloState.Idle && connecting.Sessions.Count == 0,
                "running without plugin is unknown, not offline or fabricated standby");
            Check(DetailsWindow.FriendlyStatusDetailForTest(connecting, connecting.Sessions) == L10n.Instance["status.connecting_opencode"],
                "missing plugin subtitle must not say offline");
            Check(OpenCodeMonitor.BuildAggregate(new List<SessionSnapshot>(), true, false, DateTime.UtcNow).Label == "STANDBY", "online empty instance is standby");
            Check(OpenCodeMonitor.BuildAggregate(sessions, true, true, DateTime.UtcNow).Label == "PAUSED", "pause");
            data = json.DeserializeObject("{\"sessions\":[{\"id\":\"root\",\"state\":\"thinking\"},{\"id\":\"child\",\"parentID\":\"root\",\"state\":\"attention\"}]}") as Dictionary<string, object>;
            Check(OpenCodeMonitor.BuildAggregate(OpenCodeMonitor.Parse(data), true, false, DateTime.UtcNow).State == HaloState.Attention, "child permission reaches attention");
            HaloSettings settings = new HaloSettings();
            settings.SetFocusedAgent(AgentKind.OpenCode);
            Check(settings.GetFocusedAgent() == AgentKind.OpenCode, "OpenCode focus persistence");
            settings.EnabledAgents = new List<string> { "codex", "pi" };
            Check(!settings.IsAgentEnabled(AgentKind.OpenCode), "existing enabled agents are preserved");
            var done = new List<SessionSnapshot> { new SessionSnapshot {
                Agent = AgentKind.OpenCode, State = HaloState.Done,
                CompletedUtc = DateTime.UtcNow, Action = "Complete" } };
            Check(OpenCodeMonitor.BuildAggregate(done, true, false, DateTime.UtcNow).Label == "COMPLETE", "fresh completion");
            Check(OpenCodeMonitor.BuildAggregate(done, true, false, DateTime.UtcNow.AddSeconds(10)).Label == "STANDBY", "completion settles without losing presence");
        }
        private static void Check(bool ok, string detail) { if (!ok) throw new Exception("OpenCode: " + detail); }
    }
}
