import Darwin
import Foundation

struct FastFileMetadata: Equatable {
    var size: UInt64
    var modifiedAt: Date

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
            )
        )
    }
}
