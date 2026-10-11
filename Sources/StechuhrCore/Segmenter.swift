import Foundation

/// One foreground snippet: a contiguous period in one window (or one browser tab).
/// Every snippet keeps its own project assignment.
public struct Segment: Identifiable, Hashable, Sendable {
    /// Stable key used to persist manual assignments.
    public var key: String
    public var span: TimeSpan
    public var app: String
    public var title: String
    public var url: String?
    public var domain: String?
    public var pageTitle: String?
    /// Path of the document shown in the window, if the app exposes it.
    public var path: String?
    public var isNoise: Bool = false

    public var id: String { key }
    public var isWeb: Bool { url != nil }
    public var displayTitle: String {
        if let pageTitle { return pageTitle }
        if title.isEmpty, let path { return (path as NSString).lastPathComponent }
        return title
    }
    public var duration: TimeInterval { span.duration }

    public init(key: String, span: TimeSpan, app: String, title: String, url: String? = nil,
                domain: String? = nil, pageTitle: String? = nil, path: String? = nil, isNoise: Bool = false) {
        self.key = key
        self.span = span
        self.app = app
        self.title = title
        self.url = url
        self.domain = domain
        self.pageTitle = pageTitle
        self.path = path
        self.isNoise = isNoise
    }
}

public enum Segmenter {
    public static func domain(of url: String) -> String? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Builds foreground snippets for one day from recorded events.
    public static func segments(from events: [RecordedEvent], day: TimeSpan, noiseThreshold: TimeInterval) -> [Segment] {
        let events = events.sorted { $0.span.start < $1.span.start }
        var out: [Segment] = []
        for (i, e) in events.enumerated() {
            var span = e.span
            // Defensive: if two records overlap, the later one wins.
            if i + 1 < events.count, events[i + 1].span.start < span.end {
                span.end = max(span.start, events[i + 1].span.start)
            }
            guard let clipped = span.clamped(to: day) else { continue }
            let url = (e.url?.isEmpty ?? true) ? nil : e.url
            out.append(Segment(key: "e\(e.id)", span: clipped, app: e.app, title: e.title, url: url,
                               domain: url.map { domain(of: $0) ?? $0 },
                               pageTitle: (e.pageTitle?.isEmpty ?? true) ? nil : e.pageTitle,
                               path: (e.path?.isEmpty ?? true) ? nil : e.path,
                               isNoise: clipped.duration < noiseThreshold))
        }
        return out
    }
}
