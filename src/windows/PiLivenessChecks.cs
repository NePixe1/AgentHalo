using System;
using System.Diagnostics;
using System.IO;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    internal static class PiLivenessChecks
    {
        internal static void Run()
        {
            string path = Path.Combine(Path.GetTempPath(), "pi-liveness-" + Guid.NewGuid().ToString("N") + ".jsonl");
            var json = new JavaScriptSerializer();
            int pid = Process.GetCurrentProcess().Id;
            Func<string, string, DateTime, string> line = (id, state, time) => json.Serialize(new {
                source = "pi-extension", sessionId = id, state, timestamp = time.ToString("o"),
                pid, @event = "tool_execution_start"
            }) + "\n";
            try
            {
                File.WriteAllText(path, line("old", "working", DateTime.UtcNow.AddSeconds(-2)) +
                    line("current", "thinking", DateTime.UtcNow));
                var monitor = new PiStatusMonitor(path);
                monitor.Refresh();
                var ids = monitor.LiveSessionIds();
                Check(ids.Count == 1 && ids.Contains("current"), "resumed session supersedes older activity in same PID");
                var longWork = new SessionSnapshot { Agent = AgentKind.Pi, State = HaloState.Working,
                    Active = true, LastEventUtc = DateTime.UtcNow.AddHours(-1) };
                Check(HaloWindow.IsHookActivitySessionVisible(longWork, DateTime.UtcNow, true), "long tool remains active without token events");
                Check(!HaloWindow.IsHookActivitySessionVisible(longWork, DateTime.UtcNow, false), "dead/superseded session never stays active");
                File.AppendAllText(path, line("current", "offline", DateTime.UtcNow.AddSeconds(1)));
                monitor.Refresh();
                Check(monitor.LiveSessionIds().Count == 0, "shutdown cannot resurrect an old session");
                DateTime started;
                Check(WindowsProcessProbe.TryGetLiveStartTime(pid, out started), "live process uses limited query rights");
                Check(!WindowsProcessProbe.TryGetLiveStartTime(Int32.MaxValue, out started), "nonexistent PID rejected");
            }
            finally { File.Delete(path); }
        }
        private static void Check(bool ok, string message)
        {
            if (!ok) throw new InvalidOperationException("Pi liveness: " + message);
        }
    }
}
