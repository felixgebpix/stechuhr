import Foundation

/// Half-open time interval [start, end).
public struct TimeSpan: Hashable, Codable, Sendable {
    public var start: Date
    public var end: Date

    public init(_ start: Date, _ end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var isEmpty: Bool { end <= start }

    public func clamped(to other: TimeSpan) -> TimeSpan? {
        let s = max(start, other.start), e = min(end, other.end)
        return e > s ? TimeSpan(s, e) : nil
    }

    public func overlaps(_ other: TimeSpan) -> Bool {
        start < other.end && other.start < end
    }
}

/// Set operations on lists of time spans. All results are sorted and non-overlapping.
public enum Spans {
    public static func union(_ spans: [TimeSpan]) -> [TimeSpan] {
        let sorted = spans.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var out: [TimeSpan] = []
        for s in sorted {
            if let last = out.last, s.start <= last.end {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }

    public static func intersect(_ a: [TimeSpan], _ b: [TimeSpan]) -> [TimeSpan] {
        let a = union(a), b = union(b)
        var i = 0, j = 0
        var out: [TimeSpan] = []
        while i < a.count && j < b.count {
            let s = max(a[i].start, b[j].start), e = min(a[i].end, b[j].end)
            if e > s { out.append(TimeSpan(s, e)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return out
    }

    /// a minus b
    public static func subtract(_ a: [TimeSpan], _ b: [TimeSpan]) -> [TimeSpan] {
        let b = union(b)
        var out: [TimeSpan] = []
        for span in union(a) {
            var cursor = span.start
            for cut in b where cut.end > cursor && cut.start < span.end {
                if cut.start > cursor { out.append(TimeSpan(cursor, cut.start)) }
                cursor = max(cursor, cut.end)
                if cursor >= span.end { break }
            }
            if cursor < span.end { out.append(TimeSpan(cursor, span.end)) }
        }
        return out
    }

    public static func total(_ spans: [TimeSpan]) -> TimeInterval {
        union(spans).reduce(0) { $0 + $1.duration }
    }

    /// Merges spans whose gap is at most `gap` into blocks.
    public static func blocks(_ spans: [TimeSpan], maxGap gap: TimeInterval) -> [TimeSpan] {
        var out: [TimeSpan] = []
        for s in union(spans) {
            if let last = out.last, s.start.timeIntervalSince(last.end) <= gap {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }
}
