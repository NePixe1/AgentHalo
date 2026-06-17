import Foundation

/// Merges Claude Code Hook-source snapshots with transcript-source snapshots into a
/// single deterministic list, keyed by `threadId`.
///
/// **Source precedence:**
/// - Hook is authoritative for completion: a hook snapshot in `.done` or `.error` is
///   never overridden, even by a later transcript reactivation.
/// - Missed-Stop safety net: when the hook is still active and the transcript has an
///   explicit completion strictly newer than the last hook event, the transcript wins.
/// - Otherwise the hook snapshot wins.
///
/// **Crash safety:** duplicate `threadId`s within a single source (resume / multi-window
/// scenarios) are collapsed last-write-wins by `lastEventAt` rather than crashing the tick.
public enum ClaudeStatusSourceMerger {
    /// Merge hook and transcript snapshots into a single list, sorted newest-first.
    ///
    /// - Parameter now: Reserved for future timeout-based pruning. Currently unused;
    ///   kept in the signature so callers and tests remain stable when timeout policy is
    ///   added later. A default of `Date()` lets callers omit it.
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

        // Order-within-tie when `lastEventAt` is equal is unspecified; downstream
        // aggregation must not rely on it.
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

    /// On equal `lastEventAt`, prefer `rhs` (the later-arriving entry) so duplicate-keyed
    /// merge becomes "last write wins".
    private static func newerByEventTime(_ lhs: SessionSnapshot, _ rhs: SessionSnapshot) -> SessionSnapshot {
        rhs.lastEventAt >= lhs.lastEventAt ? rhs : lhs
    }
}
