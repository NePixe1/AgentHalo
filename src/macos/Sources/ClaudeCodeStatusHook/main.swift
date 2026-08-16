import AgentHaloCore
import Darwin
import Foundation

// MARK: - CLI entry

let event = CommandLine.arguments.dropFirst().first ?? ""

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let payload: [String: Any]
if stdinData.isEmpty {
    payload = [:]
} else {
    payload = (try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]) ?? [:]
}

// MARK: - Field extraction

func firstString(_ values: Any?...) -> String {
    for value in values {
        if let s = value as? String, !s.isEmpty {
            return s
        }
    }
    return ""
}

func nestedGet(_ obj: Any?, path: [String]) -> Any? {
    var cur = obj
    for key in path {
        guard let dict = cur as? [String: Any], let val = dict[key] else {
            return nil
        }
        cur = val
    }
    return cur
}

/// Map snake_case hook event names to PascalCase used by reducers.
/// Already-PascalCase names pass through unchanged.
func normalizeEventName(_ raw: String) -> String {
    let mapping: [String: String] = [
        "session_start": "SessionStart",
        "user_prompt_submit": "UserPromptSubmit",
        "pre_tool_use": "PreToolUse",
        "post_tool_use": "PostToolUse",
        "post_tool_use_failure": "PostToolUseFailure",
        "permission_denied": "PermissionDenied",
        "notification": "Notification",
        "stop": "Stop",
        "stop_failure": "StopFailure",
        "stop_cancelled": "StopCancelled",
        "session_end": "SessionEnd",
        "pre_compact": "PreCompact",
        "post_compact": "PostCompact",
    ]
    if let mapped = mapping[raw] {
        return mapped
    }
    if let mapped = mapping[raw.lowercased()] {
        return mapped
    }
    return raw
}

let env = ProcessInfo.processInfo.environment
let isGrok = !(env["GROK_SESSION_ID"] ?? "").isEmpty
    || !(env["GROK_HOOK_EVENT"] ?? "").isEmpty

let rawEventName = firstString(
    event,
    env["GROK_HOOK_EVENT"],
    payload["hookEventName"],
    payload["hook_event_name"],
    payload["event"],
    payload["eventName"]
)

let eventName = normalizeEventName(rawEventName)

guard !eventName.isEmpty else {
    exit(0)
}

let cwd = firstString(
    payload["cwd"],
    nestedGet(payload, path: ["workspace", "current_dir"]),
    nestedGet(payload, path: ["workspace", "cwd"]),
    FileManager.default.currentDirectoryPath
)

let sessionId = firstString(
    payload["session_id"],
    payload["sessionId"],
    payload["conversation_id"],
    env["GROK_SESSION_ID"],
    isGrok ? "grok-build" : "claude-code"
)

let toolName = firstString(
    payload["tool_name"],
    payload["toolName"],
    nestedGet(payload, path: ["tool", "name"])
)

let notificationType: String
if eventName == "Notification" {
    notificationType = firstString(
        payload["type"],
        payload["notification_type"],
        payload["notificationType"]
    )
} else {
    notificationType = ""
}

let errorText: String
if eventName == "StopFailure" || eventName == "PostToolUseFailure" {
    errorText = firstString(
        payload["error"],
        payload["error_text"],
        payload["errorText"],
        payload["tool_stderr"]
    )
} else {
    errorText = ""
}

// Grok: default | auto | plan | bypassPermissions (every hook event).
// Claude may emit acceptEdits / dontAsk / etc. — pass through as-is.
let permissionMode = firstString(
    payload["permission_mode"],
    payload["permissionMode"]
)

let promptId = firstString(
    payload["promptId"],
    payload["prompt_id"]
)

let subagentType = firstString(
    payload["subagentType"],
    payload["subagent_type"]
)

let reason = firstString(payload["reason"])

let cancelledBy = firstString(
    payload["cancelledBy"],
    payload["cancelled_by"]
)

let cancelTrigger = firstString(
    payload["cancelTrigger"],
    payload["cancel_trigger"]
)

let timestamp = firstString(
    payload["timestamp"],
    {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        return fmt.string(from: Date())
    }()
)

// MARK: - Build record

let source = isGrok ? "grok-hook" : "claude-hook"


var record: [String: Any?] = [
    "timestamp": timestamp,
    "event": eventName,
    "sessionId": sessionId,
    "cwd": cwd,
    "toolName": toolName.isEmpty ? nil : toolName,
    "notificationType": notificationType.isEmpty ? nil : notificationType,
    "errorText": errorText.isEmpty ? nil : errorText,
    "permissionMode": permissionMode.isEmpty ? nil : permissionMode,
    "promptId": promptId.isEmpty ? nil : promptId,
    "subagentType": subagentType.isEmpty ? nil : subagentType,
    "reason": reason.isEmpty ? nil : reason,
    "cancelledBy": cancelledBy.isEmpty ? nil : cancelledBy,
    "cancelTrigger": cancelTrigger.isEmpty ? nil : cancelTrigger,
    "source": source,
]

let recordData = try! JSONSerialization.data(
    withJSONObject: record,
    options: [.sortedKeys]
)
let recordLine = String(data: recordData, encoding: .utf8)! + "\n"

// MARK: - Write with flock and rotation

// Prefer $HOME so isolation tests and sandboxed launches resolve correctly;
// fall back to the platform home directory when HOME is unset.
let homeURL: URL = {
    if let home = env["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}()

let paths = AgentHaloPaths(homeDirectory: homeURL)
let statusURL = isGrok ? paths.grokStatusLog : paths.claudeStatusLog

// Create logs directory with 0o700
try? FileManager.default.createDirectory(
    at: paths.logsDirectory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
)

let statusFilePath = statusURL.path

// Always use open() — mixing FileHandle and POSIX fd risks the fd being
// closed when the FileHandle is deallocated by ARC.
let fd = open(statusFilePath, O_RDWR | O_CREAT, 0o600)
guard fd >= 0 else { exit(0) }

// Exclusive lock
guard flock(fd, LOCK_EX) == 0 else {
    close(fd)
    exit(0)
}

defer {
    flock(fd, LOCK_UN)
    close(fd)
}

// Rotation: if > 3 MB, keep last ~2 MB
let rotateTrigger: UInt64 = 3 * 1024 * 1024
let rotateKeep: UInt64 = 2 * 1024 * 1024

var statBuf = stat()
if fstat(fd, &statBuf) == 0 {
    let size = UInt64(statBuf.st_size)
    if size >= rotateTrigger {
        // Seek to size - keep, skip partial first line, read tail, rewrite.
        lseek(fd, off_t(size - rotateKeep), SEEK_SET)

        // Read the rotation region into a buffer.
        let readChunk = 4096
        var buf = [UInt8](repeating: 0, count: readChunk)
        var allBytes = [UInt8]()
        while true {
            let n = read(fd, &buf, readChunk)
            if n <= 0 { break }
            allBytes.append(contentsOf: buf[0..<n])
        }

        // Skip the first (possibly partial) line.
        if let nlIndex = allBytes.firstIndex(of: 0x0A) {
            let tail = allBytes[(nlIndex + 1)...]
            ftruncate(fd, 0)
            lseek(fd, 0, SEEK_SET)
            _ = tail.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress, tail.count)
            }
        } else {
            // No newline found in the kept region — truncate entirely.
            ftruncate(fd, 0)
            lseek(fd, 0, SEEK_SET)
        }
    }
}

// Append record
lseek(fd, 0, SEEK_END)
let lineBytes = [UInt8](recordLine.utf8)
_ = write(fd, lineBytes, lineBytes.count)
fsync(fd)

exit(0)
