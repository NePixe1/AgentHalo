using System;
using System.Collections.Generic;
using System.IO;

namespace CodexHalo
{
    public sealed class PiLivePid
    {
        public string SessionId;
        public int ProcessId;
    }

    public sealed class FocusedSessionLiveEvidence
    {
        public List<ClaudeLiveSessionRef> Claude;
        public List<GrokActiveSessionRef> Grok;
        public List<PiLivePid> Pi;

        public FocusedSessionLiveEvidence()
        {
            Claude = new List<ClaudeLiveSessionRef>();
            Grok = new List<GrokActiveSessionRef>();
            Pi = new List<PiLivePid>();
        }
    }

    public static class FocusedSessionHostResolver
    {
        public static int ResolveProcessId(
            AgentKind focusedAgent,
            IList<SessionSnapshot> visibleSessions,
            IList<SessionSnapshot> hookSnapshots,
            bool paused,
            FocusedSessionLiveEvidence evidence)
        {
            if (paused)
            {
                return 0;
            }
            if (evidence == null)
            {
                evidence = new FocusedSessionLiveEvidence();
            }
            switch (focusedAgent)
            {
                case AgentKind.Codex:
                    return 0;
                case AgentKind.ClaudeCode:
                    return ClaudePid(visibleSessions, hookSnapshots, evidence.Claude);
                case AgentKind.Grok:
                    return GrokPid(visibleSessions, evidence.Grok);
                case AgentKind.Pi:
                    return PiPid(visibleSessions, hookSnapshots, evidence.Pi);
                default:
                    return 0;
            }
        }

        private static int ClaudePid(
            IList<SessionSnapshot> visibleSessions,
            IList<SessionSnapshot> hookSnapshots,
            List<ClaudeLiveSessionRef> live)
        {
            if (live == null)
            {
                live = new List<ClaudeLiveSessionRef>();
            }
            if (visibleSessions != null && visibleSessions.Count > 0)
            {
                SessionSnapshot first = visibleSessions[0];
                string threadId = first == null ? null : first.ThreadId;
                if (!String.IsNullOrEmpty(threadId))
                {
                    foreach (ClaudeLiveSessionRef match in live)
                    {
                        if (match != null && match.SessionId == threadId &&
                            match.ProcessId > 0)
                        {
                            return match.ProcessId;
                        }
                    }
                }
                return 0;
            }
            ClaudeLiveSessionRef preferred =
                ClaudeLiveSessionReader.PreferredStandbySession(live, hookSnapshots);
            if (preferred != null && preferred.ProcessId > 0)
            {
                return preferred.ProcessId;
            }
            return 0;
        }

        private static int GrokPid(
            IList<SessionSnapshot> visibleSessions,
            List<GrokActiveSessionRef> live)
        {
            List<GrokActiveSessionRef> withPid = new List<GrokActiveSessionRef>();
            if (live != null)
            {
                foreach (GrokActiveSessionRef session in live)
                {
                    if (session != null && session.ProcessId > 0)
                    {
                        withPid.Add(session);
                    }
                }
            }
            if (visibleSessions != null && visibleSessions.Count > 0)
            {
                SessionSnapshot snapshot = visibleSessions[0];
                if (snapshot == null)
                {
                    return 0;
                }
                foreach (GrokActiveSessionRef exact in withPid)
                {
                    if (exact.SessionId == snapshot.ThreadId)
                    {
                        return exact.ProcessId;
                    }
                }
                if (snapshot.ThreadId == "grok" && withPid.Count == 1)
                {
                    return withPid[0].ProcessId;
                }
                string directory = NormalizedDirectory(snapshot.WorkingDirectory);
                if (directory.Length > 0)
                {
                    List<GrokActiveSessionRef> matched = new List<GrokActiveSessionRef>();
                    foreach (GrokActiveSessionRef session in withPid)
                    {
                        if (String.Equals(
                            NormalizedDirectory(session.WorkingDirectory),
                            directory, StringComparison.OrdinalIgnoreCase))
                        {
                            matched.Add(session);
                        }
                    }
                    if (matched.Count == 1)
                    {
                        return matched[0].ProcessId;
                    }
                }
                return 0;
            }
            return withPid.Count == 1 ? withPid[0].ProcessId : 0;
        }

        private static int PiPid(
            IList<SessionSnapshot> visibleSessions,
            IList<SessionSnapshot> hookSnapshots,
            List<PiLivePid> live)
        {
            Dictionary<string, int> liveById = new Dictionary<string, int>(
                StringComparer.Ordinal);
            if (live != null)
            {
                foreach (PiLivePid item in live)
                {
                    if (item == null || item.ProcessId <= 0 ||
                        String.IsNullOrEmpty(item.SessionId))
                    {
                        continue;
                    }
                    liveById[item.SessionId] = item.ProcessId;
                }
            }
            if (visibleSessions != null && visibleSessions.Count > 0)
            {
                SessionSnapshot first = visibleSessions[0];
                string threadId = first == null ? null : first.ThreadId;
                int pid;
                if (!String.IsNullOrEmpty(threadId) &&
                    liveById.TryGetValue(threadId, out pid))
                {
                    return pid;
                }
                return 0;
            }
            SessionSnapshot newest = null;
            if (hookSnapshots != null)
            {
                foreach (SessionSnapshot snapshot in hookSnapshots)
                {
                    if (snapshot == null || snapshot.Agent != AgentKind.Pi ||
                        String.IsNullOrEmpty(snapshot.ThreadId) ||
                        !liveById.ContainsKey(snapshot.ThreadId))
                    {
                        continue;
                    }
                    if (newest == null ||
                        snapshot.LastEventUtc > newest.LastEventUtc)
                    {
                        newest = snapshot;
                    }
                }
            }
            int standbyPid;
            if (newest != null && liveById.TryGetValue(newest.ThreadId, out standbyPid))
            {
                return standbyPid;
            }
            return 0;
        }

        private static string NormalizedDirectory(string path)
        {
            if (path == null)
            {
                return String.Empty;
            }
            string trimmed = path.Trim();
            if (trimmed.Length == 0)
            {
                return String.Empty;
            }
            try
            {
                return Path.GetFullPath(trimmed).TrimEnd(
                    Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            }
            catch
            {
                return trimmed.TrimEnd(
                    Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            }
        }
    }
}
