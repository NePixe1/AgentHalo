import Foundation

public enum ClaudeContextUsageConstants {
    /// 时钟偏移容忍度（30 秒）
    /// 允许轻微的系统时钟不同步
    public static let clockSkewTolerance: TimeInterval = 30

    /// 工作状态可见性延长时间（1.8 秒）
    /// 防止 UI 状态快速闪烁
    public static let workingVisibilityExtension: TimeInterval = 1.8
}
