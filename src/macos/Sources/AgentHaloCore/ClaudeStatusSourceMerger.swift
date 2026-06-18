import Foundation

/// Normalizes Claude Code hook-source snapshots into a single deterministic list,
/// keyed by `threadId`.
///
/// **Source precedence:**
/// - Hook status is the only UI authority for Claude Code focus.
/// - Transcript snapshots are deliberately ignored; transcripts are chat records, not
///   lifecycle records, and can leave old sessions falsely active.
///
/// **Crash safety:** duplicate `threadId`s within a single source (resume / multi-window
/// scenarios) are collapsed last-write-wins by `lastEventAt` rather than crashing the tick.
public enum ClaudeStatusSourceMerger {
    /// Return hook snapshots as a de-duplicated list, sorted newest-first.
    ///
    /// `transcriptSnapshots` and `now` are kept in the signature so existing callers and
    /// tests remain source-compatible while the display policy is hook-only.
    public static func merge(
        hookSnapshots: [SessionSnapshot],
        transcriptSnapshots _: [SessionSnapshot],
        now _: Date = Date()
    ) -> [SessionSnapshot] {
        // Use uniquingKeysWith so duplicate threadIds (resume / multi-window) cannot crash
        // the tick. On collision, keep the snapshot with the newer lastEventAt.
        let hooksByThread = Dictionary(
            hookSnapshots.map { ($0.threadId, $0) },
            uniquingKeysWith: { Self.newerByEventTime($0, $1) }
        )

        // Order-within-tie when `lastEventAt` is equal is unspecified; downstream
        // aggregation must not rely on it.
        return hooksByThread.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// On equal `lastEventAt`, prefer `rhs` (the later-arriving entry) so duplicate-keyed
    /// merge becomes "last write wins".
    private static func newerByEventTime(_ lhs: SessionSnapshot, _ rhs: SessionSnapshot) -> SessionSnapshot {
        rhs.lastEventAt >= lhs.lastEventAt ? rhs : lhs
    }
}
