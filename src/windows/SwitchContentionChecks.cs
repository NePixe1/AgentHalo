using System;
using System.Diagnostics;
using System.Reflection;
using System.Threading;

namespace CodexHalo
{
    internal static class SwitchContentionChecks
    {
        internal static double ElapsedMilliseconds;
        internal static void Run()
        {
            using (var monitor = new CodexSessionMonitor("missing-test-session-directory", false))
            using (var entered = new ManualResetEvent(false))
            using (var release = new ManualResetEvent(false))
            {
                var settings = new HaloSettings();
                monitor.GetAggregate(settings, false);
                monitor.GetAllRecent();
                object gate = typeof(CodexSessionMonitor).GetField("sync",
                    BindingFlags.Instance | BindingFlags.NonPublic).GetValue(monitor);
                var worker = new Thread(delegate()
                {
                    lock (gate) { entered.Set(); release.WaitOne(1000); }
                });
                worker.Start();
                try
                {
                    if (!entered.WaitOne(2000)) throw new Exception("Contention test did not acquire scan lock");
                    var watch = Stopwatch.StartNew();
                    monitor.Start();
                    monitor.Stop();
                    monitor.GetAggregate(settings, false);
                    monitor.GetAllRecent();
                    watch.Stop();
                    ElapsedMilliseconds = watch.Elapsed.TotalMilliseconds;
                    if (ElapsedMilliseconds > 200)
                        throw new Exception("Agent switching waited for scan lock: " + ElapsedMilliseconds + "ms");
                }
                finally { release.Set(); worker.Join(); }
            }
        }
    }
}
