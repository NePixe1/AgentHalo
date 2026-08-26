import Foundation

public enum FocusedAgentActivator {
    public static func activate(
        focusedAgent: AgentKind,
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        paused: Bool,
        evidence: FocusedSessionLiveEvidence,
        processes: [Int32: HostProcessRecord],
        selfProcessId: Int32,
        activateCodex: () -> Void,
        activateHost: (Int32) -> Void
    ) {
        if focusedAgent == .codex {
            activateCodex()
            return
        }
        guard let pid = FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: focusedAgent,
            visibleSessions: visibleSessions,
            hookSnapshots: hookSnapshots,
            paused: paused,
            evidence: evidence
        ) else {
            return
        }
        guard let hostPid = ProcessTreeHostWalker.resolveHost(
            startingProcessId: pid,
            processes: processes,
            selfProcessId: selfProcessId
        ) else {
            return
        }
        activateHost(hostPid)
    }
}
