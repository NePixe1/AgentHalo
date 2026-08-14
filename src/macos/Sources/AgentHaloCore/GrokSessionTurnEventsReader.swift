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
    /// `cancellation_category` from events.jsonl (e.g. `mid_turn_abort`,
    /// `permission_rejected`).
    public var cancellationCategory: String
    /// `cancellation_context.trigger` (e.g. `esc`, `send_now`).
    public var cancellationTrigger: String

    public init(
        endedAt: Date,
        outcome: GrokSessionTurnEndOutcome,
        cancellationCategory: String = "",
        cancellationTrigger: String = ""
    ) {
        self.endedAt = endedAt
        self.outcome = outcome
        self.cancellationCategory = cancellationCategory
        self.cancellationTrigger = cancellationTrigger
    }

    /// Steer / Sent now aborts the current turn only to immediately start another.
    /// Those must not paint the red fault ring (unlike pure Esc interrupt).
    public var isSteerLikeCancel: Bool {
        guard outcome == .cancelled else { return false }
        switch cancellationTrigger.lowercased() {
        case "send_now", "steer", "redirect", "queued_send":
            return true
        default:
            return false
        }
    }
}

/// A `turn_started` line from session `events.jsonl`.
///
/// Grok marks steer redirects with `redirect_kind` (`cancel_then_send`,
/// `queued_after_cancel`). A start after a cancel supersedes the fault ring.
public struct GrokSessionTurnStart: Equatable, Sendable {
    public var startedAt: Date
    public var redirectKind: String

    public init(startedAt: Date, redirectKind: String = "") {
        self.startedAt = startedAt
        self.redirectKind = redirectKind
    }

    public var isSteerRedirect: Bool {
        switch redirectKind.lowercased() {
        case "cancel_then_send", "queued_after_cancel":
            return true
        default:
            return false
        }
    }
}

/// Latest durable turn boundary observed for one Grok session.
///
/// `active_sessions.json` is a process-presence registry and can omit a still
/// running conversation when Grok Build has multiple sessions in one process.
/// This per-session evidence lets activity monitoring distinguish that case
/// from an old hook snapshot whose turn has actually ended.
public struct GrokSessionTurnState: Equatable, Sendable {
    public var lastStartedAt: Date?
    public var lastEndedAt: Date?

    public init(lastStartedAt: Date? = nil, lastEndedAt: Date? = nil) {
        self.lastStartedAt = lastStartedAt
        self.lastEndedAt = lastEndedAt
    }

    public var isOpen: Bool {
        guard let lastStartedAt else { return false }
        guard let lastEndedAt else { return true }
        return lastStartedAt >= lastEndedAt
    }

    public var latestBoundaryAt: Date? {
        switch (lastStartedAt, lastEndedAt) {
        case (.some(let started), .some(let ended)):
            return max(started, ended)
        case (.some(let started), .none):
            return started
        case (.none, .some(let ended)):
            return ended
        case (.none, .none):
            return nil
        }
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
    public var turnStart: GrokSessionTurnStart?
    public var permissionUpdates: [GrokPermissionUpdate]

    public init(
        turnEnd: GrokSessionTurnEnd? = nil,
        turnStart: GrokSessionTurnStart? = nil,
        permissionUpdates: [GrokPermissionUpdate] = []
    ) {
        self.turnEnd = turnEnd
        self.turnStart = turnStart
        self.permissionUpdates = permissionUpdates
    }

    public var isEmpty: Bool {
        turnEnd == nil && turnStart == nil && permissionUpdates.isEmpty
    }
}

/// Incrementally tails `events.jsonl` for turn ends and permission lifecycle.
///
/// Stateful per session path so the (often multi‑hundred‑KB) phase stream is not
/// fully re-read every poll. First attach walks backward from EOF until the
/// latest `turn_started` is found so a long `phase_changed` burst cannot hide
/// the current turn boundary.
public final class GrokSessionTurnEventsReader {
    private struct TailState {
        var offset: UInt64 = 0
        var pending = ""
        var lastModified: Date?
        var sawFile = false
        var lastStartedAt: Date?
        var lastEndedAt: Date?
    }

    private static let firstAttachChunkBytes: UInt64 = 64 * 1024

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

        if isFirstAttach {
            let lines = collectFirstAttachRelevantLines(from: eventsURL, size: size)
            state.offset = size
            state.pending = ""
            return parseLines(lines, state: &state)
        }
        if size <= state.offset {
            return GrokSessionEventsDelta()
        }

        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else {
            return GrokSessionEventsDelta()
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: state.offset)
            let data = try handle.readToEnd() ?? Data()
            state.offset = size
            let chunk = String(decoding: data, as: UTF8.self)
            let text = state.pending + chunk
            let complete = text.hasSuffix("\n")
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !complete {
                state.pending = lines.popLast() ?? ""
            } else {
                state.pending = ""
            }
            return parseLines(lines, state: &state)
        } catch {
            return GrokSessionEventsDelta()
        }
    }

    private func collectFirstAttachRelevantLines(from eventsURL: URL, size: UInt64) -> [String] {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: eventsURL) else {
            return []
        }
        defer { try? handle.close() }

        var pos = size
        var suffix = ""
        var collected: [String] = []
        var foundStart = false

        while pos > 0 && !foundStart {
            let chunkStart = pos > Self.firstAttachChunkBytes ? pos - Self.firstAttachChunkBytes : 0
            do {
                try handle.seek(toOffset: chunkStart)
            } catch {
                break
            }
            let data = (try? handle.read(upToCount: Int(pos - chunkStart))) ?? Data()
            let chunk = String(decoding: data, as: UTF8.self)
            let text = chunk + suffix
            let completeText: String
            if chunkStart > 0 {
                if let newline = text.firstIndex(of: "\n") {
                    suffix = String(text[...newline])
                    completeText = String(text[text.index(after: newline)...])
                } else {
                    suffix = text
                    completeText = ""
                }
            } else {
                suffix = ""
                completeText = text
            }

            var lines = completeText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if pos == size, !text.hasSuffix("\n"), !lines.isEmpty {
                lines.removeLast()
            }

            var kept: [String] = []
            var chunkHasStart = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                guard !trimmed.isEmpty, Self.isRelevantTurnEventLine(trimmed) else {
                    continue
                }
                kept.append(trimmed)
                if trimmed.contains("turn_started") {
                    chunkHasStart = true
                }
            }
            collected.insert(contentsOf: kept, at: 0)
            foundStart = chunkHasStart
            pos = chunkStart
        }
        return collected
    }

    private static func isRelevantTurnEventLine(_ line: String) -> Bool {
        line.contains("turn_started")
            || line.contains("turn_ended")
            || line.contains("permission_requested")
            || line.contains("permission_resolved")
    }

    private func parseLines(_ lines: [String], state: inout TailState) -> GrokSessionEventsDelta {
        var latest: GrokSessionTurnEnd?
        var latestStart: GrokSessionTurnStart?
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
                if state.lastStartedAt.map({ at > $0 }) ?? true {
                    state.lastStartedAt = at
                }
                let redirectKind = string(root["redirect_kind"])
                // Only surface starts that carry a steer redirect_kind —
                // ordinary starts would make isEmpty false on every turn.
                if !redirectKind.isEmpty {
                    latestStart = GrokSessionTurnStart(
                        startedAt: at,
                        redirectKind: redirectKind
                    )
                }
                // Steer (cancel_then_send / queued_after_cancel) writes
                // turn_ended cancelled then turn_started in the same tail
                // chunk. A newer start supersedes any prior terminal end.
                if let end = latest, at >= end.endedAt {
                    latest = nil
                }
            case "turn_ended":
                let outcome = GrokSessionTurnEndOutcome(raw: string(root["outcome"]))
                let category = string(root["cancellation_category"])
                var trigger = ""
                if let ctx = root["cancellation_context"] as? [String: Any] {
                    trigger = string(ctx["trigger"])
                }
                let end = GrokSessionTurnEnd(
                    endedAt: at,
                    outcome: outcome,
                    cancellationCategory: category,
                    cancellationTrigger: trigger
                )
                if state.lastEndedAt.map({ at > $0 }) ?? true {
                    state.lastEndedAt = at
                }
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
        return GrokSessionEventsDelta(
            turnEnd: latest,
            turnStart: latestStart,
            permissionUpdates: permissions
        )
    }

    public func reset() {
        tails.removeAll()
    }

    public func turnState(eventsURL: URL) -> GrokSessionTurnState {
        guard let state = tails[eventsURL.path] else {
            return GrokSessionTurnState()
        }
        return GrokSessionTurnState(
            lastStartedAt: state.lastStartedAt,
            lastEndedAt: state.lastEndedAt
        )
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
