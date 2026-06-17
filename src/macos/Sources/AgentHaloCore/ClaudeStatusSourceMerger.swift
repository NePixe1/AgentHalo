import Foundation

public enum ClaudeStatusSourceMerger {
    public static func merge(
        hookSnapshots: [SessionSnapshot],
        transcriptSnapshots: [SessionSnapshot],
        now: Date = Date()
    ) -> [SessionSnapshot] {
        // Use uniquingKeysWith so duplicate threadIds (resume / multi-window) cannot crash
        // the tick. On collision, keep the snapshot with the newer lastEventAt.
        let hooksByThread = Dictionary(
            hookSnapshots.map { ($0.threadId, $0) },
            uniquingKeysWith: { Self.newerByEventTime($0, $1) }
        )
        let transcriptsByThread = Dictionary(
            transcriptSnapshots.map { ($0.threadId, $0) },
            uniquingKeysWith: { Self.newerByEventTime($0, $1) }
        )
        let threadIds = Set(hooksByThread.keys).union(transcriptsByThread.keys)

        return threadIds.compactMap { threadId in
            choose(hook: hooksByThread[threadId], transcript: transcriptsByThread[threadId])
        }
        .sorted { $0.lastEventAt > $1.lastEventAt }
    }

    private static func choose(hook: SessionSnapshot?, transcript: SessionSnapshot?) -> SessionSnapshot? {
        guard let hook else { return transcript }
        guard let transcript else { return hook }

        // Hook completion is authoritative — even a stale transcript reactivation cannot revive it.
        if hook.state == .done || hook.state == .error {
            return hook
        }

        // Safety net: if hook is still working but transcript already has an explicit completion
        // strictly newer than the last hook event, the Stop hook was missed. Trust the transcript.
        if hook.active,
           transcript.state == .done,
           let completedAt = transcript.completedAt,
           completedAt > hook.lastEventAt {
            return transcript
        }

        return hook
    }

    private static func newerByEventTime(_ lhs: SessionSnapshot, _ rhs: SessionSnapshot) -> SessionSnapshot {
        rhs.lastEventAt >= lhs.lastEventAt ? rhs : lhs
    }
}
