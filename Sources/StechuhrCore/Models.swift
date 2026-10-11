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
    case app, title, domain, url, path

    public var label: String {
        switch self {
        case .app: "App"
        case .title: "Titel"
        case .domain: "Domain"
        case .url: "URL"
        case .path: "Dateipfad"
        }
    }
}

public enum RuleMatch: String, Codable, CaseIterable, Sendable {
    case equals, contains, prefix, suffix, regex

    public var label: String {
        switch self {
        case .equals: "ist"
        case .contains: "enthält"
        case .prefix: "beginnt mit"
        case .suffix: "endet mit"
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
        case .path: candidate = segment.path ?? ""
        }
        switch match {
        case .equals:
            return candidate.caseInsensitiveCompare(value) == .orderedSame
        case .contains:
            return !value.isEmpty && candidate.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .prefix:
            let v = field == .path ? (value as NSString).expandingTildeInPath : value
            return !v.isEmpty && candidate.range(of: v, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        case .suffix:
            return !value.isEmpty && candidate.range(of: value, options: [.caseInsensitive, .diacriticInsensitive, .anchored, .backwards]) != nil
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

/// A confirmed block of time for one project ("Zeiteintrag"). Inside its span, every snippet without
/// its own, different project counts for this project – short switches to tools no longer fragment the day.
public struct TimeEntry: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var projectId: Int64
    public var span: TimeSpan
    public var title: String

    public init(id: Int64 = 0, projectId: Int64, span: TimeSpan, title: String = "") {
        self.id = id
        self.projectId = projectId
        self.span = span
        self.title = title
    }
}

/// A folder → project mapping (Claude Code working folders and document paths). Subfolders are included.
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
        let expanded = (path as NSString).expandingTildeInPath
        let base = expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
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
    /// Apps that are tools rather than projects: without their own hint they take the project of the surrounding work.
    public var toolApps: [String] = ["Claude", "Terminal", "iTerm2", "Ghostty", "WezTerm", "Warp", "GitKraken", "Tower", "Fork",
                                     "GitHub Desktop", "Sourcetree", "Finder", "Systemeinstellungen", "System Settings",
                                     "1Password", "Bitwarden", "MacPass", "Stechuhr", "Code", "Cursor", "Xcode", "Vorschau", "Preview"]
    /// How far (in time) a tool app looks for the surrounding project.
    public var inheritWindow: TimeInterval = 300
    /// Block suggestions: gaps up to this length stay in one block.
    public var suggestionGap: TimeInterval = 300
    /// Block suggestions shorter than this are not proposed.
    public var minSuggestion: TimeInterval = 300
    /// Ask "Woran arbeitest du gerade?" when the project is unclear for a while.
    public var askWhenUnclear = true
    public var unclearAfter: TimeInterval = 180
    /// Ask what happened while you were away.
    public var askAfterAway = true
    public var awayThreshold: TimeInterval = 900
    /// Minimum time between two questions.
    public var promptCooldown: TimeInterval = 600
    /// Folders scanned for project suggestions (e.g. ~/repos).
    public var projectRoots: [String] = ["~/repos"]

    public init() {}
}
