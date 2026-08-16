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
        "notification": "Notification",
        "stop": "Stop",
        "stop_failure": "StopFailure",
        "session_end": "SessionEnd",
        "pre_compact": "PreCompact",
        "post_compact": "PostCompact",
        "pre_invocation": "PreInvocation",
        "post_invocation": "PostInvocation",
        "permission_request": "PermissionRequest",
        "permission_denied": "PermissionDenied",
    ]
    if let mapped = mapping[raw] {
        return mapped
    }
    if let mapped = mapping[raw.lowercased()] {
        return mapped
    }
    return raw
}

func firstWorkspacePath(_ payload: [String: Any]) -> String {
    let raw = payload["workspacePaths"] ?? payload["workspace_paths"]
    if let paths = raw as? [String], let first = paths.first, !first.isEmpty {
        return first
    }
    if let paths = raw as? [Any] {
        for item in paths {
            if let s = item as? String, !s.isEmpty {
                return s
            }
        }
    }
    return ""
}

/// CLI uses `.../antigravity-cli/`. Antigravity 2.0 desktop uses `.../antigravity/`.
/// The IDE uses `.../antigravity-ide/` and must not match.
func antigravityTranscriptMatch(_ transcript: String) -> Bool {
    if transcript.contains("/antigravity-ide/") {
        return false
    }
    return transcript.contains("/antigravity-cli/") || transcript.contains("/antigravity/")
}

func antigravityHookMatch(env: [String: String], payload: [String: Any]) -> Bool {
    if !(env["ANTIGRAVITY_AGENT"] ?? "").isEmpty { return true }
    if !(env["ANTIGRAVITY_TRAJECTORY_ID"] ?? "").isEmpty { return true }
    if !(env["ANTIGRAVITY_CONVERSATION_ID"] ?? "").isEmpty { return true }
    let transcript = firstString(
        payload["transcript_path"], payload["transcriptPath"],
        env["ANTIGRAVITY_TRANSCRIPT_PATH"]
    )
    return antigravityTranscriptMatch(transcript)
}

let env = ProcessInfo.processInfo.environment
let isGrok = !(env["GROK_SESSION_ID"] ?? "").isEmpty
    || !(env["GROK_HOOK_EVENT"] ?? "").isEmpty
let isAntigravity = !isGrok && antigravityHookMatch(env: env, payload: payload)

let rawEventName = firstString(
    event,
    env["GROK_HOOK_EVENT"],
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
    firstWorkspacePath(payload),
    FileManager.default.currentDirectoryPath
)

let sessionId: String
if isAntigravity {
    sessionId = firstString(
        env["ANTIGRAVITY_TRAJECTORY_ID"],
        env["ANTIGRAVITY_CONVERSATION_ID"],
        payload["session_id"],
        payload["sessionId"],
        payload["conversation_id"],
        payload["conversationId"],
        "antigravity"
    )
} else {
    sessionId = firstString(
        payload["session_id"],
        payload["sessionId"],
        payload["conversation_id"],
        env["GROK_SESSION_ID"],
        isGrok ? "grok-build" : "claude-code"
    )
}

let toolName = firstString(
    payload["tool_name"],
    payload["toolName"],
    nestedGet(payload, path: ["tool", "name"]),
    nestedGet(payload, path: ["toolCall", "name"])
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

// Claude/Grok only emit dedicated *Failure events. Antigravity registers
// Stop / PostToolUse and puts errorText / fatal on those events.
let capturesFailureFields = eventName == "StopFailure"
    || eventName == "PostToolUseFailure"
    || (isAntigravity && (eventName == "Stop" || eventName == "PostToolUse"))

let errorText: String
if capturesFailureFields {
    errorText = firstString(
        payload["error"],
        payload["error_text"],
        payload["errorText"],
        payload["tool_stderr"]
    )
} else {
    errorText = ""
}

let fatal: Bool
if isAntigravity && (eventName == "Stop" || eventName == "PostToolUse") {
    let value = payload["fatal"]
    if let value = value as? Bool {
        fatal = value
    } else if let value = value as? NSNumber {
        fatal = value != 0
    } else {
        switch firstString(value).lowercased() {
        case "true", "1", "yes":
            fatal = true
        default:
            fatal = false
        }
    }
} else {
    fatal = false
}

// Grok: default | auto | plan | bypassPermissions (every hook event).
// Claude may emit acceptEdits / dontAsk / etc. — pass through as-is.
let permissionMode = firstString(
    payload["permission_mode"],
    payload["permissionMode"]
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

let source = isGrok ? "grok-hook" : isAntigravity ? "antigravity-hook" : "claude-hook"


var record: [String: Any] = [
    "timestamp": timestamp,
    "event": eventName,
    "sessionId": sessionId,
    "cwd": cwd,
    "source": source,
]
if !toolName.isEmpty { record["toolName"] = toolName }
if !notificationType.isEmpty { record["notificationType"] = notificationType }
if !errorText.isEmpty { record["errorText"] = errorText }
if fatal { record["fatal"] = true }
if !permissionMode.isEmpty { record["permissionMode"] = permissionMode }

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
let statusURL = isGrok ? paths.grokStatusLog : isAntigravity ? paths.antigravityStatusLog : paths.claudeStatusLog

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
