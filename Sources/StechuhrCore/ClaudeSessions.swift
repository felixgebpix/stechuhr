import Foundation

/// One Claude Code hook event as received from the hook helper.
/// Prompt texts and assistant messages are deliberately never stored.
public struct ClaudeEvent: Codable, Hashable, Sendable {
    public var uuid: String
    public var sessionId: String
    public var event: String
    public var ts: Date
    public var cwd: String
    public var notificationType: String?
    public var source: String?
    public var reason: String?
    public var agentId: String?
    public var sessionTitle: String?

    enum CodingKeys: String, CodingKey {
        case uuid, ts, cwd, source, reason
        case sessionId = "session_id"
        case event = "hook_event_name"
        case notificationType = "notification_type"
        case agentId = "agent_id"
        case sessionTitle = "session_title"
    }

    public init(uuid: String = UUID().uuidString, sessionId: String, event: String, ts: Date, cwd: String,
                notificationType: String? = nil, source: String? = nil, reason: String? = nil,
                agentId: String? = nil, sessionTitle: String? = nil) {
        self.uuid = uuid
        self.sessionId = sessionId
        self.event = event
        self.ts = ts
        self.cwd = cwd
        self.notificationType = notificationType
        self.source = source
        self.reason = reason
        self.agentId = agentId
        self.sessionTitle = sessionTitle
    }

    /// Decodes the payload written by `stechuhr-hook` (ts in epoch seconds).
    public static func decode(_ data: Data) throws -> ClaudeEvent {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(ClaudeEvent.self, from: data)
    }
}

/// A period in which Claude was working (prompt submitted → Stop / waiting for input).
public struct ClaudeWorkSpan: Hashable, Sendable {
    public var span: TimeSpan
    public var cwd: String
    /// Still running right now.
    public var isOpen: Bool
}

public struct ClaudeRun: Identifiable, Hashable, Sendable {
    public var sessionId: String
    public var title: String?
    public var cwd: String
    /// From first to last event (or SessionEnd) – the session is "open" in this window.
    public var sessionSpan: TimeSpan
    public var work: [ClaudeWorkSpan]
    /// When you submitted prompts in this session – tells which of several open sessions you were looking at.
    public var prompts: [Date] = []

    public var id: String { sessionId }
    public var folderName: String { (cwd as NSString).lastPathComponent }
}

public enum ClaudeSessions {
    static let waitingNotifications: Set<String> = ["permission_prompt", "idle_prompt", "elicitation_dialog"]
    static let activityEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart"]

    /// Turns raw hook events into working periods per session, clipped to `day`.
    public static func runs(from events: [ClaudeEvent], day: TimeSpan, now: Date, staleAfter: TimeInterval) -> [ClaudeRun] {
        let bySession = Dictionary(grouping: events, by: \.sessionId)
        var runs: [ClaudeRun] = []

        for (sessionId, evs) in bySession {
            let evs = evs.sorted { $0.ts < $1.ts }
            guard let first = evs.first, let last = evs.last else { continue }
            var work: [ClaudeWorkSpan] = []
            var openStart: Date?
            var openCwd = first.cwd
            var lastSeen = first.ts
            var ended = false
            var title: String?

            func close(at t: Date) {
                if let s = openStart { work.append(ClaudeWorkSpan(span: TimeSpan(s, t), cwd: openCwd, isOpen: false)) }
                openStart = nil
            }

            for e in evs {
                if let t = e.sessionTitle, !t.isEmpty { title = t }
                // A turn that went silent for too long (crash, killed terminal) ends at its last sign of life.
                if openStart != nil, e.ts.timeIntervalSince(lastSeen) > staleAfter { close(at: lastSeen) }
                lastSeen = e.ts
                switch e.event {
                case "UserPromptSubmit":
                    if openStart == nil { openStart = e.ts; openCwd = e.cwd }
                    ended = false
                case "Stop", "StopFailure":
                    close(at: e.ts)
                case "SessionEnd":
                    close(at: e.ts)
                    ended = true
                case "SessionStart":
                    // Resuming after a crash: the previous turn ended at the last known event.
                    if openStart != nil { close(at: e.ts) }
                    ended = false
                case "PermissionRequest":
                    close(at: e.ts)
                case "Notification":
                    if let t = e.notificationType, waitingNotifications.contains(t) { close(at: e.ts) }
                default:
                    // Tool activity after a permission prompt means Claude is working again.
                    if activityEvents.contains(e.event), openStart == nil, !ended {
                        openStart = e.ts
                        openCwd = e.cwd
                    }
                }
            }
            if let s = openStart {
                let deadline = lastSeen.addingTimeInterval(staleAfter)
                let isOpen = now < deadline
                work.append(ClaudeWorkSpan(span: TimeSpan(s, isOpen ? now : lastSeen), cwd: openCwd, isOpen: isOpen))
            }

            let clippedWork = work.compactMap { w -> ClaudeWorkSpan? in
                guard let c = w.span.clamped(to: day) else { return nil }
                return ClaudeWorkSpan(span: c, cwd: w.cwd, isOpen: w.isOpen)
            }
            let sessionEnd = (openStart != nil && !ended) ? max(now, last.ts) : last.ts
            let sessionSpan = TimeSpan(first.ts, min(sessionEnd, day.end))
            guard !clippedWork.isEmpty || sessionSpan.overlaps(day) else { continue }
            runs.append(ClaudeRun(sessionId: sessionId, title: title, cwd: last.cwd,
                                  sessionSpan: sessionSpan.clamped(to: day) ?? sessionSpan, work: clippedWork,
                                  prompts: evs.filter { $0.event == "UserPromptSubmit" && $0.agentId == nil }.map(\.ts)))
        }
        return runs.sorted { ($0.work.first?.span.start ?? $0.sessionSpan.start) < ($1.work.first?.span.start ?? $1.sessionSpan.start) }
    }
}
