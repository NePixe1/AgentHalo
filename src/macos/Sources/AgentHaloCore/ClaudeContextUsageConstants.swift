import Foundation

public enum ClaudeContextUsageConstants {
    /// Claude status-line snapshots are useful only for the currently active
    /// session. Keeping a short freshness window prevents a long-idle process
    /// from presenting context values captured before compaction or restart.
    public static let snapshotMaxAge: TimeInterval = 300

    /// 时钟偏移容忍度（30 秒）
    /// 允许轻微的系统时钟不同步
    public static let clockSkewTolerance: TimeInterval = 30

    /// 工作状态可见性延长时间（1.8 秒）
    /// 防止 UI 状态快速闪烁
    public static let workingVisibilityExtension: TimeInterval = 1.8

    // MARK: - On-disk contexts GC (layout v2 cache/claude-contexts)

    /// Prefer deleting snapshots whose payload `updatedAt` (or mtime) is older.
    public static let diskMaxAge: TimeInterval = 24 * 60 * 60

    /// Soft cap on retained session snapshot files.
    public static let maxFiles: Int = 40

    /// Files younger than this are never deleted solely for the count cap.
    public static let minRetainAge: TimeInterval = 10 * 60

    /// Opportunistic prune after write is throttled per process.
    public static let pruneThrottle: TimeInterval = 60
}
