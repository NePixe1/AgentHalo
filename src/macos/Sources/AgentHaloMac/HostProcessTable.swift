import AppKit
import Darwin
import AgentHaloCore

enum HostProcessTable {
    static func live() -> [Int32: HostProcessRecord] {
        let requested = proc_listallpids(nil, 0)
        guard requested > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(requested) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [:] }

        var table: [Int32: HostProcessRecord] = [:]
        table.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
            }
            guard read == size else { continue }
            let comm = processCString(info.pbi_comm)
            let name = comm.isEmpty ? processCString(info.pbi_name) : comm
            let processId = Int32(info.pbi_pid)
            let isRegularApp = NSRunningApplication(processIdentifier: processId)?
                .activationPolicy == .regular
            table[processId] = HostProcessRecord(
                processId: processId,
                parentProcessId: Int32(info.pbi_ppid),
                name: name,
                isRegularApp: isRegularApp
            )
        }
        return table
    }

    private static func processCString<T>(_ value: T) -> String {
        var copy = value
        return withUnsafeBytes(of: &copy) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
