import Foundation

/// When Stechuhr should ask "Woran arbeitest du gerade?".
public enum ContextPrompt: Hashable, Sendable {
    /// For a while now, nothing tells which project the current work belongs to.
    case unclear(since: Date, candidates: [Int64])
    /// Back after being away (no input) – what happened in between?
    case away(span: TimeSpan, candidates: [Int64])

    public var candidates: [Int64] {
        switch self {
        case .unclear(_, let c), .away(_, let c): c
        }
    }
}

public enum ContextPrompter {
    /// Unclear = only snippets without any project hint (or with ambiguous keywords) since the last clear one,
    /// for at least `minDuration`, and you are active right now. Tool apps that inherited their project count as clear.
    public static func unclear(segments: [AttributedSegment], now: Date, minDuration: TimeInterval) -> Date? {
        let counted = segments.filter { $0.source != .ignoredNoise }.sorted { $0.segment.span.start < $1.segment.span.start }
        guard let last = counted.last, now.timeIntervalSince(last.segment.span.end) < 90 else { return nil }
        var since: Date?
        var unsure: TimeInterval = 0
        var previousStart = now
        for s in counted.reversed() {
            if !isUnclear(s.source) { break }
            // A long gap means you were away – that is a different question.
            if previousStart.timeIntervalSince(s.segment.span.end) > 600 { break }
            unsure += s.segment.duration
            since = s.segment.span.start
            previousStart = s.segment.span.start
        }
        guard let since, unsure >= minDuration, now.timeIntervalSince(since) >= minDuration else { return nil }
        return since
    }

    static func isUnclear(_ source: AssignmentSource) -> Bool {
        switch source {
        case .none, .ambiguous: true
        default: false
        }
    }

    /// Returns the away period if you just came back (within `returnedWithin`) after at least `threshold` without input,
    /// and nothing else (time entry, background task) already explains it.
    public static func away(events: [RecordedEvent], covered: [TimeSpan], now: Date, threshold: TimeInterval,
                            returnedWithin: TimeInterval = 180) -> TimeSpan? {
        let sorted = events.sorted { $0.span.start < $1.span.start }
        guard sorted.count >= 2 else { return nil }
        let back = sorted[sorted.count - 1], before = sorted[sorted.count - 2]
        guard now.timeIntervalSince(back.span.start) <= returnedWithin else { return nil }
        let gap = TimeSpan(before.span.end, back.span.start)
        guard gap.duration >= threshold else { return nil }
        let explained = Spans.total(Spans.intersect([gap], covered))
        return explained < gap.duration / 2 ? gap : nil
    }

    /// Most likely projects: ambiguous matches first, then what you worked on recently (by time), at most `limit`.
    public static func candidates(segments: [AttributedSegment], entries: [TimeEntry], before: Date,
                                  lookback: TimeInterval = 2 * 3600, limit: Int = 4) -> [Int64] {
        var out: [Int64] = []
        for s in segments.reversed() where s.segment.span.end <= before.addingTimeInterval(1) {
            if case .ambiguous(let ids) = s.source { for id in ids where !out.contains(id) { out.append(id) } }
            if !isUnclear(s.source) { break }
        }
        var weight: [Int64: TimeInterval] = [:]
        let from = before.addingTimeInterval(-lookback)
        for s in segments where s.segment.span.end > from && s.segment.span.start < before {
            if let p = s.projectId { weight[p, default: 0] += s.segment.duration }
        }
        for e in entries where e.span.end > from { weight[e.projectId, default: 0] += e.span.duration }
        for (id, _) in weight.sorted(by: { $0.value > $1.value }) where !out.contains(id) { out.append(id) }
        return Array(out.prefix(limit))
    }
}

/// A time entry that keeps growing while you continue working (after answering a prompt or "Ich arbeite jetzt an …").
public enum RunningEntry {
    /// New end of the entry and whether it keeps running.
    /// It stops after `foreignAfter` of work that clearly belongs to another project (short glances don't count),
    /// or after a break longer than `awayAfter`.
    /// `stopOnForeign: false` for timers you started yourself: they only end when you switch, stop or are away.
    public static func extend(_ entry: TimeEntry, segments: [AttributedSegment], now: Date,
                              foreignAfter: TimeInterval, awayAfter: TimeInterval,
                              stopOnForeign: Bool = true) -> (end: Date, running: Bool) {
        let after = segments.filter { $0.counts && $0.segment.span.end > entry.span.end }
            .sorted { $0.segment.span.start < $1.segment.span.start }
        var end = entry.span.end
        var lastActivity = entry.span.end
        var foreignTime: TimeInterval = 0
        for s in after {
            if s.segment.span.start.timeIntervalSince(lastActivity) > awayAfter { return (end, false) }
            lastActivity = max(lastActivity, s.segment.span.end)
            if stopOnForeign, s.source.isOwnSignal, s.projectId != entry.projectId {
                foreignTime += s.segment.duration
                if foreignTime >= foreignAfter { return (end, false) }
            } else {
                foreignTime = 0
                end = max(end, s.segment.span.end)
            }
        }
        if now.timeIntervalSince(lastActivity) > awayAfter { return (end, false) }
        return (end, true)
    }
}
