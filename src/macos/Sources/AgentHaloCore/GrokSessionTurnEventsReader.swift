import Foundation

/// Terminal outcomes from Grok session `events.jsonl` (`turn_ended`).
///
/// Esc / Ctrl+C cancel skips Stop hooks entirely (see Grok hooks docs). The
/// durable signal is `turn_ended` with `outcome: "cancelled"`.
public enum GrokSessionTurnEndOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed
    case other(String)

    public init(raw: String) {
        switch raw.lowercased() {
        case "completed", "complete", "success", "ok":
            self = .completed
        case "cancelled", "canceled", "interrupted", "aborted":
            self = .cancelled
        case "error", "failed", "failure":
            self = .failed
        default:
            self = .other(raw)
        }
    }
}

public struct GrokSessionTurnEnd: Equatable, Sendable {
    public var endedAt: Date
    public var outcome: GrokSessionTurnEndOutcome

    public init(endedAt: Date, outcome: GrokSessionTurnEndOutcome) {
        self.endedAt = endedAt
        self.outcome = outcome
    }
}

/// Permission lifecycle lines from Grok session `events.jsonl`.
///
/// Auto mode still emits `permission_requested` / `permission_resolved` with
/// `wait_ms ≈ 0`. Real user prompts have multi-second `wait_ms`. The hook-only
/// `Notification:permission_prompt` cannot distinguish these; these events can.
public struct GrokPermissionUpdate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case requested(toolName: String)
        case resolved(toolName: String, decision: String, waitMs: Int)
    }

    public var at: Date
    public var kind: Kind

    public init(at: Date, kind: Kind) {
        self.at = at
        self.kind = kind
    }
}

/// One poll of a session `events.jsonl` tail.
public struct GrokSessionEventsDelta: Equatable, Sendable {
    public var turnEnd: GrokSessionTurnEnd?
    public var permissionUpdates: [GrokPermissionUpdate]

    public init(turnEnd: GrokSessionTurnEnd? = nil, permissionUpdates: [GrokPermissionUpdate] = []) {
        self.turnEnd = turnEnd
        self.permissionUpdates = permissionUpdates
    }

    public var isEmpty: Bool {
        turnEnd == nil && permissionUpdates.isEmpty
    }
}

/// Incrementally tails `events.jsonl` for turn ends and permission lifecycle.
///
/// Stateful per session path so the (often multi‑hundred‑KB) phase stream is not
/// fully re-read every poll. First open seeks near EOF and only catch-up scans
/// a short tail for an already-active turn that was cancelled while Halo was
/// mid-poll or just starting.
public final class GrokSessionTurnEventsReader {
    private struct TailState {
        var offset: UInt64 = 0
        var pending = ""
        var lastModified: Date?
        var sawFile = false
    }

    /// How much history to scan on first attach so a cancel that landed just
    /// before we subscribed still surfaces. Large enough for a long tool burst
    /// of `phase_changed` lines; small enough for the 0.3s activity poll.
    private static let firstAttachTailByteLimit: UInt64 = 256 * 1024

    private var tails: [String: TailState] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Consume newly appended `events.jsonl` bytes.
    public func poll(eventsURL: URL) -> GrokSessionEventsDelta {
        let key = eventsURL.path
        var state = tails[key] ?? TailState()
        defer { tails[key] = state }

        let meta = FastFileMetadata.read(eventsURL)
        let size = meta?.size ?? 0
        let mtime = meta?.modifiedAt

        if size == 0 || !fileManager.fileExists(atPath: eventsURL.path) {
            state = TailState()
            return GrokSessionEventsDelta()
        }

        let mtimeChanged = mtime != nil && state.lastModified != nil && mtime != state.lastModified
        let truncated = size < state.offset || (mtimeChanged && size <= state.offset)
        if truncated {
            state = TailState()
        }

        let isFirstAttach = !state.sawFile
        state.sawFile = true
        state.lastModified = mtime

        let readFrom: UInt64
        if isFirstAttach {
            readFrom = size > Self.firstAttachTailByteLimit
                ? size - Self.firstAttachTailByteLimit
                : 0
            state.offset = readFrom
            state.pending = ""
        } else if size <= state.offset {
            return GrokSessionEventsDelta()
        } else {
            readFrom = state.offset
        }

        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else {
            return GrokSessionEventsDelta()
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: readFrom)
            let data = try handle.readToEnd() ?? Data()
            state.offset = size
            guard let chunk = String(data: data, encoding: .utf8) else {
                return GrokSessionEventsDelta()
            }

            let text = state.pending + chunk
            let complete = text.hasSuffix("\n")
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !complete {
                state.pending = lines.popLast() ?? ""
            } else {
                state.pending = ""
            }

            // On first attach we may start mid-line; drop that partial fragment.
            if isFirstAttach, readFrom > 0, !lines.isEmpty {
                lines.removeFirst()
            }

            var latest: GrokSessionTurnEnd?
            var lastStartedAt: Date?
            var permissions: [GrokPermissionUpdate] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                let type = string(root["type"])
                let at = parseDate(string(root["ts"]))
                    ?? parseDate(string(root["timestamp"]))
                    ?? Date()
                switch type {
                case "turn_started":
                    lastStartedAt = at
                case "turn_ended":
                    let outcome = GrokSessionTurnEndOutcome(raw: string(root["outcome"]))
                    let end = GrokSessionTurnEnd(endedAt: at, outcome: outcome)
                    // Prefer a cancel/fail that is not already superseded by a newer start.
                    if let lastStartedAt, lastStartedAt > at {
                        continue
                    }
                    latest = end
                case "permission_requested":
                    permissions.append(
                        GrokPermissionUpdate(
                            at: at,
                            kind: .requested(toolName: string(root["tool_name"]))
                        )
                    )
                case "permission_resolved":
                    let waitMs: Int
                    if let n = root["wait_ms"] as? Int {
                        waitMs = n
                    } else if let n = root["wait_ms"] as? Double {
                        waitMs = Int(n)
                    } else if let n = root["wait_ms"] as? NSNumber {
                        waitMs = n.intValue
                    } else {
                        waitMs = Int(string(root["wait_ms"])) ?? 0
                    }
                    permissions.append(
                        GrokPermissionUpdate(
                            at: at,
                            kind: .resolved(
                                toolName: string(root["tool_name"]),
                                decision: string(root["decision"]),
                                waitMs: waitMs
                            )
                        )
                    )
                default:
                    break
                }
            }
            return GrokSessionEventsDelta(turnEnd: latest, permissionUpdates: permissions)
        } catch {
            return GrokSessionEventsDelta()
        }
    }

    public func reset() {
        tails.removeAll()
    }

    public func drop(eventsURL: URL) {
        tails.removeValue(forKey: eventsURL.path)
    }

    private func string(_ value: Any?) -> String {
        if let value {
            return String(describing: value)
        }
        return ""
    }

    private func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
