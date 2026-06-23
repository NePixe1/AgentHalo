import Foundation

/// Normalizes Claude Code hook-source snapshots into a single deterministic list,
/// keyed by `threadId`.
///
/// **Source precedence:**
/// - Hook status remains authoritative whenever at least one hook snapshot exists.
/// - Transcript snapshots are a fallback only when hook data is unavailable, so stale
///   chat records cannot override a hook completion or permission state.
///
/// **Crash safety:** duplicate `threadId`s within a single source (resume / multi-window
/// scenarios) are collapsed last-write-wins by `lastEventAt` rather than crashing the tick.
public enum ClaudeStatusSourceMerger {
    /// Return the authoritative source as a de-duplicated list, sorted newest-first.
    public static func merge(
        hookSnapshots: [SessionSnapshot],
        transcriptSnapshots: [SessionSnapshot],
        now _: Date = Date()
    ) -> [SessionSnapshot] {
        let authoritative = hookSnapshots.isEmpty ? transcriptSnapshots : hookSnapshots
        // Use uniquingKeysWith so duplicate threadIds (resume / multi-window) cannot crash
        // the tick. On collision, keep the snapshot with the newer lastEventAt.
        let snapshotsByThread = Dictionary(
            authoritative.map { ($0.threadId, $0) },
            uniquingKeysWith: { Self.newerByEventTime($0, $1) }
        )

        // Order-within-tie when `lastEventAt` is equal is unspecified; downstream
        // aggregation must not rely on it.
        return snapshotsByThread.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// On equal `lastEventAt`, prefer `rhs` (the later-arriving entry) so duplicate-keyed
    /// merge becomes "last write wins".
    private static func newerByEventTime(_ lhs: SessionSnapshot, _ rhs: SessionSnapshot) -> SessionSnapshot {
        rhs.lastEventAt >= lhs.lastEventAt ? rhs : lhs
    }
}
