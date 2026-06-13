import Foundation
import AgentHaloCore

final class InstanceLock {
    private var descriptor: Int32 = -1

    func acquire() -> Bool {
        let root = SettingsStore.defaultSettingsURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("instance.lock")
        descriptor = open(url.path(percentEncoded: false), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return false
        }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
