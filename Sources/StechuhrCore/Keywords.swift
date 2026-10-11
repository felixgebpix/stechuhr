import Foundation

/// Matches project names and keywords as whole words in window titles, URLs and folder paths.
public struct KeywordMatcher: Sendable {
    struct Term: Sendable {
        var projectId: Int64
        var text: String
        var normalized: String
    }

    private let terms: [Term]

    public init(projects: [Project]) {
        var terms: [Term] = []
        for p in projects where !p.archived {
            var seen = Set<String>()
            for raw in [p.name] + p.keywords {
                let text = raw.trimmingCharacters(in: .whitespaces)
                let n = Self.normalize(text)
                // Very short terms ("QA", "X") would match far too much.
                guard n.count >= 3 || (n.count == 2 && text == text.uppercased()), seen.insert(n).inserted else { continue }
                terms.append(Term(projectId: p.id, text: text, normalized: n))
            }
        }
        self.terms = terms
    }

    public enum Result: Hashable, Sendable {
        case none
        case match(projectId: Int64, term: String)
        case ambiguous([Int64])
    }

    public func match(_ haystacks: [String]) -> Result {
        let hay = haystacks.map(Self.normalize)
        var hits: [Int64: String] = [:]
        for t in terms where hits[t.projectId] == nil {
            if hay.contains(where: { Self.containsWord(t.normalized, in: $0) }) { hits[t.projectId] = t.text }
        }
        switch hits.count {
        case 0: return .none
        case 1: return .match(projectId: hits.first!.key, term: hits.first!.value)
        default: return .ambiguous(hits.keys.sorted())
        }
    }

    public func match(_ segment: Segment) -> Result {
        match([segment.app, segment.title, segment.pageTitle ?? "", segment.url ?? ""])
    }

    /// Folder names below the home directory, e.g. ~/repos/acme-website → "repos/acme-website".
    public func match(folder cwd: String) -> Result {
        let home = NSHomeDirectory()
        let rel = cwd.hasPrefix(home) ? String(cwd.dropFirst(home.count)) : cwd
        return match([rel])
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }

    /// Case-/diacritic-insensitive search where the match is not part of a longer word.
    static func containsWord(_ needle: String, in hay: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchRange = hay.startIndex..<hay.endIndex
        while let r = hay.range(of: needle, range: searchRange) {
            let before = r.lowerBound == hay.startIndex ? nil : hay[hay.index(before: r.lowerBound)]
            let after = r.upperBound == hay.endIndex ? nil : hay[r.upperBound]
            let isWordChar: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
            if !isWordChar(before) && !isWordChar(after) { return true }
            searchRange = hay.index(after: r.lowerBound)..<hay.endIndex
        }
        return false
    }
}

/// How a Claude Code working folder got its project.
public enum FolderResolution: Hashable, Sendable {
    case mapping(Int64)
    case keyword(Int64, term: String)
    case ambiguous([Int64])
    case none

    public var projectId: Int64? {
        switch self {
        case .mapping(let id), .keyword(let id, _): id
        default: nil
        }
    }

    /// Explicit mappings win; otherwise project names / keywords in the folder path.
    public static func resolve(_ cwd: String, folders: [FolderMapping], keywords: KeywordMatcher) -> FolderResolution {
        if let id = FolderMapping.project(for: cwd, in: folders) { return .mapping(id) }
        switch keywords.match(folder: cwd) {
        case .match(let id, let term): return .keyword(id, term: term)
        case .ambiguous(let ids): return .ambiguous(ids)
        case .none: return .none
        }
    }
}

/// A rule Stechuhr proposes because you assigned similar snippets by hand several times.
public struct RuleSuggestion: Identifiable, Hashable, Sendable {
    public var projectId: Int64
    public var conditions: [RuleCondition]
    /// Number of manually assigned snippets this rule would have covered.
    public var count: Int
    public var duration: TimeInterval
    public var days: Int

    public var id: String { Self.signature(conditions, projectId) }

    public static func signature(_ conditions: [RuleCondition], _ projectId: Int64) -> String {
        conditions.map { "\($0.field.rawValue)|\($0.match.rawValue)|\($0.value.lowercased())" }.joined(separator: "&") + "→\(projectId)"
    }
}

public enum RuleSuggester {
    public struct Sample: Sendable {
        public var segment: Segment
        public var projectId: Int64
        public var day: String

        public init(segment: Segment, projectId: Int64, day: String) {
            self.segment = segment
            self.projectId = projectId
            self.day = day
        }
    }

    /// Proposes rules from manual assignments: at least `minCount` snippets on at least 2 days (or `minCount` on one day
    /// with enough time), ≥ 90 % of them going to the same project, and not already handled by an existing rule.
    public static func suggest(from samples: [Sample], rules: [Rule], dismissed: Set<String>, minCount: Int = 3) -> [RuleSuggestion] {
        // Snippets that an existing rule already sends to the same project teach nothing new.
        let open = samples.filter { s in !rules.contains { $0.projectId == s.projectId && $0.matches(s.segment) } }

        // Candidate patterns from general to specific.
        func candidates(_ seg: Segment) -> [[RuleCondition]] {
            var out: [[RuleCondition]] = []
            if let d = seg.domain, !d.isEmpty {
                out.append([RuleCondition(.domain, .equals, d)])
                if let t = seg.pageTitle, !t.isEmpty { out.append([RuleCondition(.domain, .equals, d), RuleCondition(.title, .equals, t)]) }
            } else {
                out.append([RuleCondition(.app, .equals, seg.app)])
                if !seg.title.isEmpty { out.append([RuleCondition(.app, .equals, seg.app), RuleCondition(.title, .equals, seg.title)]) }
            }
            return out
        }

        struct Bucket {
            var conditions: [RuleCondition]
            var byProject: [Int64: (count: Int, duration: TimeInterval, days: Set<String>, keys: Set<String>)] = [:]
        }
        var buckets: [String: Bucket] = [:]
        for s in open {
            for c in candidates(s.segment) {
                let sig = RuleSuggestion.signature(c, 0)
                var b = buckets[sig] ?? Bucket(conditions: c)
                var e = b.byProject[s.projectId] ?? (0, 0, [], [])
                e.count += 1
                e.duration += s.segment.duration
                e.days.insert(s.day)
                e.keys.insert(s.segment.key)
                b.byProject[s.projectId] = e
                buckets[sig] = b
            }
        }

        var accepted: [(RuleSuggestion, Set<String>)] = []
        // General patterns first, so that specific ones already covered by them are skipped.
        for b in buckets.values.sorted(by: { $0.conditions.count < $1.conditions.count }) {
            let total = b.byProject.values.reduce(0) { $0 + $1.count }
            guard let (pid, best) = b.byProject.max(by: { $0.value.count < $1.value.count }) else { continue }
            guard best.count >= minCount, Double(best.count) / Double(total) >= 0.9 else { continue }
            guard best.days.count >= 2 || best.duration >= 30 * 60 else { continue }
            let suggestion = RuleSuggestion(projectId: pid, conditions: b.conditions, count: best.count,
                                            duration: best.duration, days: best.days.count)
            guard !dismissed.contains(suggestion.id) else { continue }
            if accepted.contains(where: { $0.0.projectId == pid && best.keys.isSubset(of: $0.1) }) { continue }
            accepted.append((suggestion, best.keys))
        }
        return accepted.map(\.0).sorted { $0.duration > $1.duration }
    }
}
