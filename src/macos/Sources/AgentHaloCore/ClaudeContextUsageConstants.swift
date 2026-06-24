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
}
