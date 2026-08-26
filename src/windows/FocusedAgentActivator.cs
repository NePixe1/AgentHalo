using System;
using System.Collections.Generic;

namespace CodexHalo
{
    public static class FocusedAgentActivator
    {
        public static void Activate(
            AgentKind focusedAgent,
            IList<SessionSnapshot> visibleSessions,
            IList<SessionSnapshot> hookSnapshots,
            bool paused,
            FocusedSessionLiveEvidence evidence,
            IDictionary<int, HostProcessRecord> processes,
            int selfProcessId,
            Action activateCodex,
            Action<int> activateHost)
        {
            if (focusedAgent == AgentKind.Codex)
            {
                if (activateCodex != null)
                {
                    activateCodex();
                }
                return;
            }
            int pid = FocusedSessionHostResolver.ResolveProcessId(
                focusedAgent, visibleSessions, hookSnapshots, paused, evidence);
            if (pid <= 0)
            {
                return;
            }
            int hostPid = ProcessTreeHostWalker.ResolveHost(
                pid, processes, selfProcessId);
            if (hostPid <= 0 || activateHost == null)
            {
                return;
            }
            activateHost(hostPid);
        }
    }
}
