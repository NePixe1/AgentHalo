import Foundation

public struct SessionReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot
    private var inFlightTools = 0
    private var workingVisibleUntil: Date?
    private var liveTracking: Bool

    public init(filePath: String, now: Date = Date(), liveTracking: Bool = true) {
        self.snapshot = SessionSnapshot(
            threadId: Self.threadId(from: filePath),
            projectName: "Codex",
            workingDirectory: "",
            state: .idle,
            action: "Ready",
            lastEventAt: now,
            completedAt: nil,
            active: false
        )
        self.liveTracking = liveTracking
    }

    public mutating func consume(jsonLine: String, now: Date = Date()) {
        guard let data = jsonLine.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let topType = root.string("type")
        let payload = root.dictionary("payload")
        let eventAt = Self.parseDate(root.string("timestamp")) ?? now
        snapshot.lastEventAt = eventAt

        if topType == "session_meta", let payload {
            let cwd = payload.string("cwd")
            if !cwd.isEmpty {
                snapshot.workingDirectory = cwd
                snapshot.projectName = URL(fileURLWithPath: cwd).lastPathComponent
                if snapshot.projectName.isEmpty {
                    snapshot.projectName = cwd
                }
            }
            let id = payload.string("id")
            if !id.isEmpty {
                snapshot.threadId = id
            }
            return
        }

        guard let payload else {
            return
        }

        let payloadType = payload.string("type")
        if topType == "event_msg" {
            reduceEvent(payloadType.lowercased(), eventAt: eventAt, now: now)
        } else if topType == "response_item" {
            reduceResponse(payloadType.lowercased(), payload: payload, now: now)
        }
    }

    public mutating func setLiveTracking(_ value: Bool) {
        liveTracking = value
    }

    public mutating func applyWorkingVisibility(now: Date = Date()) {
        if snapshot.active,
           inFlightTools == 0,
           snapshot.state == .working,
           let until = workingVisibleUntil,
           now >= until {
            workingVisibleUntil = nil
            snapshot.state = .thinking
            snapshot.action = "Reviewing result"
        }
    }

    private mutating func reduceEvent(_ type: String, eventAt: Date, now: Date) {
        if type == "task_started" || type == "user_message" {
            inFlightTools = 0
            workingVisibleUntil = nil
            snapshot.active = true
            snapshot.state = .thinking
            snapshot.action = "Planning"
        } else if type == "task_complete" {
            inFlightTools = 0
            workingVisibleUntil = nil
            snapshot.active = false
            snapshot.state = .done
            snapshot.action = "Complete"
            snapshot.completedAt = eventAt
        } else if type == "agent_message" || type.hasSuffix("_end") {
            if type.hasSuffix("_end"), inFlightTools > 0 {
                inFlightTools -= 1
            }
            applyActiveThinkingOrWorking(now: now)
        } else if type.contains("approval") || type.contains("request_user") || type.contains("needs_input") {
            snapshot.active = true
            snapshot.state = .attention
            snapshot.action = "Needs you"
        } else if ["turn_aborted", "turn_failed", "task_failed", "task_cancelled", "task_interrupted", "fatal_error"].contains(type) {
            snapshot.active = false
            snapshot.state = .error
            snapshot.action = "Interrupted"
        } else if type.hasSuffix("_begin") || type.hasSuffix("_start") {
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = Self.friendlyAction(type)
        }
    }

    private mutating func reduceResponse(_ type: String, payload: [String: Any], now: Date) {
        if type == "function_call" {
            let name = payload.string("name")
            snapshot.active = true
            if name == "request_user_input" {
                snapshot.state = .attention
                snapshot.action = "Needs you"
            } else {
                inFlightTools += 1
                extendWorkingVisibility(seconds: 2.2, now: now)
                snapshot.state = .working
                snapshot.action = Self.friendlyAction(name)
            }
        } else if type == "web_search_call" || type == "tool_search_call" || type.hasSuffix("_call") {
            inFlightTools += 1
            extendWorkingVisibility(seconds: 2.2, now: now)
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = Self.friendlyAction(type)
        } else if type == "function_call_output" || type == "tool_search_output" || type.hasSuffix("_output") {
            if inFlightTools > 0 {
                inFlightTools -= 1
            }
            if snapshot.active {
                if inFlightTools > 0 {
                    snapshot.state = .working
                } else if liveTracking {
                    extendWorkingVisibility(seconds: 1.8, now: now)
                    snapshot.state = .working
                    snapshot.action = "Reviewing result"
                } else {
                    snapshot.state = .thinking
                    snapshot.action = "Reviewing result"
                }
            }
        } else if type == "reasoning" {
            applyActiveThinkingOrWorking(now: now)
        }
    }

    private mutating func applyActiveThinkingOrWorking(now: Date) {
        guard snapshot.active else {
            return
        }
        if inFlightTools > 0 {
            snapshot.state = .working
        } else if let until = workingVisibleUntil, now < until {
            snapshot.state = .working
            snapshot.action = "Reviewing result"
        } else {
            snapshot.state = .thinking
            snapshot.action = "Thinking"
        }
    }

    private mutating func extendWorkingVisibility(seconds: TimeInterval, now: Date) {
        guard liveTracking else {
            return
        }
        let candidate = now.addingTimeInterval(seconds)
        if workingVisibleUntil == nil || candidate > workingVisibleUntil! {
            workingVisibleUntil = candidate
        }
    }

    private static func threadId(from filePath: String) -> String {
        let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        if name.count >= 36 {
            let suffix = String(name.suffix(36))
            if UUID(uuidString: suffix) != nil {
                return suffix
            }
        }
        return name
    }

    private static func parseDate(_ value: String) -> Date? {
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

    private static func friendlyAction(_ raw: String) -> String {
        let value = raw.lowercased()
        if value.contains("shell") || value.contains("command") {
            return "Running command"
        }
        if value.contains("apply_patch") || value.contains("edit") || value.contains("write") {
            return "Editing files"
        }
        if value.contains("web_search") || value.contains("search_query") {
            return "Searching"
        }
        if value.contains("tool_search") {
            return "Finding a tool"
        }
        if value.contains("browser") {
            return "Using browser"
        }
        if value.contains("image") {
            return "Working with image"
        }
        if value.contains("plan") {
            return "Updating plan"
        }
        return "Executing"
    }
}

fileprivate extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        if let value = self[key] {
            return String(describing: value)
        }
        return ""
    }

    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }
}
