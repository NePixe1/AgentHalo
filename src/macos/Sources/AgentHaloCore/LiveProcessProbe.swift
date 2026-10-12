import Darwin
import Foundation

public struct LiveProcess: Equatable, Sendable {
    public var processId: Int32
    public var name: String
    public var startedAt: Date?

    public init(processId: Int32, name: String, startedAt: Date?) {
        self.processId = processId
        self.name = name
        self.startedAt = startedAt
    }
}

/// Limited process query (`PROC_PIDTBSDINFO`). Exit checks that need a full
/// process handle can fail with access denied on a still-running agent.
public enum LiveProcessProbe {
    public static let startTimeTolerance: TimeInterval = 5

    public static func processes() -> [LiveProcess] {
        let requested = proc_listallpids(nil, 0)
        guard requested > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(requested) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }

        var result: [LiveProcess] = []
        result.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if let process = lookup(pid) {
                result.append(process)
            }
        }
        return result
    }

    public static func lookup(_ pid: Int32) -> LiveProcess? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard read == size else { return nil }
        let comm = cString(info.pbi_comm)
        let name = comm.isEmpty ? cString(info.pbi_name) : comm
        let startedAt: Date?
        if info.pbi_start_tvsec > 0 {
            startedAt = Date(
                timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            )
        } else {
            startedAt = nil
        }
        return LiveProcess(
            processId: Int32(info.pbi_pid),
            name: name,
            startedAt: startedAt
        )
    }

    /// True when `pid` is still the process that started at `expected`.
    public static func matchesStart(
        _ process: LiveProcess?,
        expected: Date,
        tolerance: TimeInterval = startTimeTolerance
    ) -> Bool {
        guard let startedAt = process?.startedAt else { return false }
        return abs(startedAt.timeIntervalSince(expected)) <= tolerance
    }

    /// Last write wins. `proc_listallpids` can repeat a pid while the table changes.
    public static func indexed(_ processes: [LiveProcess]) -> [Int32: LiveProcess] {
        var byPid: [Int32: LiveProcess] = [:]
        byPid.reserveCapacity(processes.count)
        for process in processes {
            byPid[process.processId] = process
        }
        return byPid
    }

    public static func isNamed(_ process: LiveProcess, _ name: String) -> Bool {
        let base = URL(fileURLWithPath: process.name).lastPathComponent
        return base.caseInsensitiveCompare(name) == .orderedSame
    }

    private static func cString<T>(_ value: T) -> String {
        var copy = value
        return withUnsafeBytes(of: &copy) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
