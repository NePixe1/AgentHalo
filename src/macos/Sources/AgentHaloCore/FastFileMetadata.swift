import Darwin
import Foundation

struct FastFileMetadata: Equatable {
    var size: UInt64
    var modifiedAt: Date
    var isRegularFile: Bool

    static func read(_ url: URL) -> FastFileMetadata? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else {
            return nil
        }
        return FastFileMetadata(
            size: UInt64(max(0, info.st_size)),
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            isRegularFile: (info.st_mode & S_IFMT) == S_IFREG
        )
    }

    // Recursively collect (url, modifiedAt) for *.jsonl regular files under
    // `root` whose modification time is at or after `cutoff`. Uses POSIX
    // opendir/readdir, which returns entry names plus a d_type tag with NO
    // per-entry stat during enumeration; only *.jsonl files are stat()'d (once
    // each, to read mtime). This mirrors the Windows FindFirstFile approach and
    // avoids the heavy per-entry work of FileManager.enumerator(at:) (NSURL
    // allocation + extended-attribute parsing per entry) and
    // FileManager.subpaths(atPath:) (an lstat + NSPathStore2 allocation per
    // entry), which on a ~1500-entry projects tree dominated the 2s discovery
    // poll. Hidden entries (name begins with ".") are skipped to match the
    // original .skipsHiddenFiles behavior; `subagents` directories are skipped
    // when `skipSubagents` is true.
    static func discoverJsonlFiles(root: URL, cutoff: Date, skipSubagents: Bool) -> [(url: URL, modifiedAt: Date)] {
        var results: [(url: URL, modifiedAt: Date)] = []
        let rootPath = root.path(percentEncoded: false)
        walk(dir: rootPath, prefix: "", cutoff: cutoff, skipSubagents: skipSubagents, results: &results)
        return results
    }

    private static func walk(dir: String, prefix: String, cutoff: Date, skipSubagents: Bool, results: inout [(url: URL, modifiedAt: Date)]) {
        guard let directory = opendir(dir) else {
            return
        }
        defer {
            closedir(directory)
        }
        while let raw = readdir(directory) {
            var entry = raw.pointee
            let name = withUnsafeBytes(of: &entry.d_name) { buffer -> String in
                guard let base = buffer.baseAddress else {
                    return ""
                }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if name.isEmpty || name == "." || name == ".." || name.hasPrefix(".") {
                continue
            }
            let fullPath = dir + "/" + name
            let rel = prefix.isEmpty ? name : prefix + "/" + name
            switch entry.d_type {
            case UInt8(DT_DIR):
                if skipSubagents && name == "subagents" {
                    continue
                }
                walk(dir: fullPath, prefix: rel, cutoff: cutoff, skipSubagents: skipSubagents, results: &results)
            case UInt8(DT_UNKNOWN):
                var info = stat()
                if stat(fullPath, &info) == 0 {
                    let mode = info.st_mode & S_IFMT
                    if mode == S_IFDIR {
                        if skipSubagents && name == "subagents" {
                            continue
                        }
                        walk(dir: fullPath, prefix: rel, cutoff: cutoff, skipSubagents: skipSubagents, results: &results)
                    } else if mode == S_IFREG, name.hasSuffix(".jsonl") {
                        appendIfRecent(fullPath: fullPath, info: info, cutoff: cutoff, results: &results)
                    }
                }
            default:
                if name.hasSuffix(".jsonl") {
                    var info = stat()
                    if stat(fullPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                        appendIfRecent(fullPath: fullPath, info: info, cutoff: cutoff, results: &results)
                    }
                }
            }
        }
    }

    private static func appendIfRecent(fullPath: String, info: stat, cutoff: Date, results: inout [(url: URL, modifiedAt: Date)]) {
        let mtime = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        guard mtime >= cutoff else {
            return
        }
        results.append((URL(fileURLWithPath: fullPath), mtime))
    }
}
