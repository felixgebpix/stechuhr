import Foundation

/// A project Stechuhr proposes from folders on disk (e.g. git repos in ~/repos) or Claude Code working folders.
public struct ProjectSuggestion: Identifiable, Hashable, Sendable {
    public var name: String
    public var folders: [String]
    public var keywords: [String]
    public var reason: String

    public var id: String { folders.sorted().joined(separator: "|") }

    public init(name: String, folders: [String], keywords: [String], reason: String) {
        self.name = name
        self.folders = folders
        self.keywords = keywords
        self.reason = reason
    }
}

public enum ProjectSuggester {
    public struct Candidate: Hashable, Sendable {
        public var path: String
        /// Normalized git remote ("owner/repo"), if any.
        public var remote: String?

        public init(path: String, remote: String? = nil) {
            self.path = path
            self.remote = remote
        }

        public var name: String { (path as NSString).lastPathComponent }
    }

    /// Folders directly inside the roots, plus the git roots of Claude Code working folders.
    public static func scan(roots: [String], claudeFolders: [String]) -> [Candidate] {
        let fm = FileManager.default
        var paths = Set<String>()
        for root in roots {
            let dir = (root as NSString).expandingTildeInPath
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where !item.hasPrefix(".") {
                var isDir: ObjCBool = false
                let p = (dir as NSString).appendingPathComponent(item)
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue, !p.hasSuffix(".worktrees") { paths.insert(p) }
            }
        }
        for cwd in claudeFolders { paths.insert(gitRoot(of: cwd) ?? cwd) }
        return paths.sorted().map { Candidate(path: $0, remote: remote(of: $0)) }
    }

    /// Groups candidates into project suggestions, skipping folders that already belong to a project.
    public static func suggest(_ candidates: [Candidate], projects: [Project], folders: [FolderMapping]) -> [ProjectSuggestion] {
        let keywords = KeywordMatcher(projects: projects)
        let open = candidates.filter {
            FolderResolution.resolve($0.path, folders: folders, keywords: keywords) == .none && !$0.name.isEmpty
        }

        var groups: [String: (name: String, items: [Candidate], reason: String)] = [:]
        // Same git remote → same project (e.g. two clones of one repo).
        for c in open {
            if let r = c.remote {
                let repo = String(r.split(separator: "/").last ?? Substring(c.name))
                groups["remote:\(r)", default: (repo, [], "gleiches Git-Repository (\(r))")].items.append(c)
            }
        }
        // Folders sharing a name prefix ("atlas", "atlas-vergleich") → one project.
        let rest = open.filter { $0.remote == nil || groups["remote:\($0.remote!)"]?.items.count == 1 }
        let byBase = Dictionary(grouping: rest) { base(of: $0.name) }
        for (b, items) in byBase where items.count > 1 && b.count >= 3 {
            for c in items { if let r = c.remote { groups.removeValue(forKey: "remote:\(r)") } }
            groups["base:\(b)"] = (b, items, "Ordner mit gleichem Namensanfang")
        }
        let grouped = Set(groups.values.flatMap { $0.items.map(\.path) })
        for c in open where !grouped.contains(c.path) {
            groups["single:\(c.path)"] = (c.name, [c], c.remote != nil ? "Git-Repository" : "Ordner")
        }

        let existing = Set(projects.map { $0.name.lowercased() })
        return groups.values.compactMap { g -> ProjectSuggestion? in
            guard !existing.contains(g.name.lowercased()) else { return nil }
            let names = Set(g.items.map(\.name)).subtracting([g.name]).sorted()
            return ProjectSuggestion(name: g.name, folders: g.items.map(\.path).sorted(), keywords: names, reason: g.reason)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func base(of name: String) -> String {
        name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).first.map(String.init)?.lowercased() ?? name.lowercased()
    }

    static func gitRoot(of path: String) -> String? {
        var p = path
        let fm = FileManager.default
        while p != "/" && !p.isEmpty {
            if fm.fileExists(atPath: (p as NSString).appendingPathComponent(".git")) { return p }
            p = (p as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Reads the "origin" (or first) remote URL from .git/config and normalizes it to "owner/repo".
    static func remote(of path: String) -> String? {
        let config = (path as NSString).appendingPathComponent(".git/config")
        guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("url =") }) else { return nil }
        return normalize(remote: String(line.split(separator: "=", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces))
    }

    static func normalize(remote url: String) -> String {
        var s = url.lowercased()
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        s = s.replacingOccurrences(of: ":", with: "/")
        let parts = s.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}
