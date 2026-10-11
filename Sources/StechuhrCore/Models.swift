import Foundation

public struct Project: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var colorHex: String
    /// Whether manually marked background time counts towards the billable total.
    public var backgroundBillable: Bool
    /// Whether Claude Code background time counts towards the billable total.
    public var claudeBillable: Bool
    public var archived: Bool
    /// Extra words (besides the name) that identify this project in titles, URLs and folder names.
    public var keywords: [String]

    public init(id: Int64 = 0, name: String, colorHex: String, backgroundBillable: Bool = true,
                claudeBillable: Bool = true, archived: Bool = false, keywords: [String] = []) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.backgroundBillable = backgroundBillable
        self.claudeBillable = claudeBillable
        self.archived = archived
        self.keywords = keywords
    }
}

public enum RuleField: String, Codable, CaseIterable, Sendable {
    case app, title, domain, url

    public var label: String {
        switch self {
        case .app: "App"
        case .title: "Titel"
        case .domain: "Domain"
        case .url: "URL"
        }
    }
}

public enum RuleMatch: String, Codable, CaseIterable, Sendable {
    case equals, contains, regex

    public var label: String {
        switch self {
        case .equals: "ist"
        case .contains: "enthält"
        case .regex: "Regex"
        }
    }
}

public struct RuleCondition: Codable, Hashable, Sendable {
    public var field: RuleField
    public var match: RuleMatch
    public var value: String

    public init(_ field: RuleField, _ match: RuleMatch, _ value: String) {
        self.field = field
        self.match = match
        self.value = value
    }

    public func matches(_ segment: Segment) -> Bool {
        let candidate: String
        switch field {
        case .app: candidate = segment.app
        case .title: candidate = segment.displayTitle
        case .domain: candidate = segment.domain ?? ""
        case .url: candidate = segment.url ?? ""
        }
        switch match {
        case .equals:
            return candidate.caseInsensitiveCompare(value) == .orderedSame
        case .contains:
            return !value.isEmpty && candidate.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .regex:
            return candidate.range(of: value, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    public var summary: String { "\(field.label) \(match.label) „\(value)“" }
}

/// All conditions must match (AND).
public struct Rule: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var projectId: Int64
    public var conditions: [RuleCondition]
    /// Lower value wins.
    public var priority: Int

    public init(id: Int64 = 0, projectId: Int64, conditions: [RuleCondition], priority: Int = 100) {
        self.id = id
        self.projectId = projectId
        self.conditions = conditions
        self.priority = priority
    }

    public func matches(_ segment: Segment) -> Bool {
        !conditions.isEmpty && conditions.allSatisfy { $0.matches(segment) }
    }
}

/// A manually marked background period ("lief im Hintergrund für Projekt X").
public struct BackgroundEntry: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var projectId: Int64
    public var span: TimeSpan
    public var note: String

    public init(id: Int64 = 0, projectId: Int64, span: TimeSpan, note: String = "") {
        self.id = id
        self.projectId = projectId
        self.span = span
        self.note = note
    }
}

/// A Claude Code folder → project mapping. Subfolders are included.
public struct FolderMapping: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var path: String
    public var projectId: Int64

    public init(id: Int64 = 0, path: String, projectId: Int64) {
        self.id = id
        self.path = path
        self.projectId = projectId
    }

    public func covers(_ cwd: String) -> Bool {
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        return cwd == base || cwd.hasPrefix(base + "/")
    }

    /// Longest matching path wins.
    public static func project(for cwd: String, in mappings: [FolderMapping]) -> Int64? {
        mappings.filter { $0.covers(cwd) }.max { $0.path.count < $1.path.count }?.projectId
    }
}

public struct AppSettings: Sendable, Equatable {
    /// Foreground switches shorter than this are treated as noise.
    public var noiseThreshold: TimeInterval = 12
    /// Gaps up to this length still count as the same work block.
    public var blockGap: TimeInterval = 120
    /// An open Claude Code turn without any event for longer than this is considered stale.
    public var claudeStaleAfter: TimeInterval = 3600
    /// No keyboard/mouse input for this long counts as away.
    public var idleThreshold: TimeInterval = 180
    public var terminalApps: [String] = ["Terminal", "iTerm2", "Ghostty", "WezTerm", "Warp", "Alacritty", "kitty", "Hyper", "Tabby", "Claude"]

    public init() {}
}
