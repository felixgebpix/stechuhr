import Foundation

public enum AssignmentSource: Hashable, Sendable {
    case manual, rule
    /// Document path inside a folder mapped to a project.
    case folder
    /// Project name or keyword found in title / URL / path.
    case keyword(String)
    /// Terminal or Claude app showing a Claude Code session that works in a project folder.
    case claudeSession
    /// Tool app (Claude, GitKraken, …) without own hint – took the project of the surrounding work.
    case context
    /// Covered by a confirmed time entry.
    case entry
    /// Keywords of several projects match – left unassigned on purpose.
    case ambiguous([Int64])
    /// Short switch absorbed into the surrounding project.
    case absorbedNoise
    /// Short switch between different projects – ignored entirely.
    case ignoredNoise
    case none

    /// The snippet itself says which project it belongs to (as opposed to inheriting it).
    public var isOwnSignal: Bool {
        switch self {
        case .manual, .rule, .folder, .keyword, .claudeSession: true
        default: false
        }
    }
}

public struct AttributedSegment: Identifiable, Hashable, Sendable {
    public var segment: Segment
    public var projectId: Int64?
    public var source: AssignmentSource

    public var id: String { segment.key }
    public var counts: Bool { source != .ignoredNoise }
}

/// Order: manual → rule → folder (document path) → keyword → Claude session (terminal) → tool context → none.
public enum Attribution {
    public static let noProject: Int64 = 0

    public struct Context {
        public var folders: [FolderMapping] = []
        public var keywords: KeywordMatcher?
        /// Project for a terminal/Claude snippet from the Claude Code session it shows.
        public var claudeHint: ((Segment) -> Int64?)?
        public var toolApps: Set<String> = []
        public var inheritWindow: TimeInterval = 300

        public init(folders: [FolderMapping] = [], keywords: KeywordMatcher? = nil, claudeHint: ((Segment) -> Int64?)? = nil,
                    toolApps: Set<String> = [], inheritWindow: TimeInterval = 300) {
            self.folders = folders
            self.keywords = keywords
            self.claudeHint = claudeHint
            self.toolApps = Set(toolApps.map { $0.lowercased() })
            self.inheritWindow = inheritWindow
        }
    }

    public static func attribute(_ segments: [Segment], assignments: [String: Int64], rules: [Rule],
                                 keywords: KeywordMatcher? = nil) -> [AttributedSegment] {
        attribute(segments, assignments: assignments, rules: rules, context: Context(keywords: keywords))
    }

    public static func attribute(_ segments: [Segment], assignments: [String: Int64], rules: [Rule],
                                 context: Context) -> [AttributedSegment] {
        let rules = rules.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
        var out = segments.map { seg -> AttributedSegment in
            if let p = assignments[seg.key] {
                return AttributedSegment(segment: seg, projectId: p == noProject ? nil : p, source: .manual)
            }
            if seg.isNoise { return AttributedSegment(segment: seg, projectId: nil, source: .ignoredNoise) }
            if let r = rules.first(where: { $0.matches(seg) }) {
                return AttributedSegment(segment: seg, projectId: r.projectId, source: .rule)
            }
            if let path = seg.path, let pid = FolderMapping.project(for: path, in: context.folders) {
                return AttributedSegment(segment: seg, projectId: pid, source: .folder)
            }
            switch context.keywords?.match(seg) ?? .none {
            case .match(let pid, let term): return AttributedSegment(segment: seg, projectId: pid, source: .keyword(term))
            case .ambiguous(let ids): return AttributedSegment(segment: seg, projectId: nil, source: .ambiguous(ids))
            case .none: break
            }
            if let pid = context.claudeHint?(seg) {
                return AttributedSegment(segment: seg, projectId: pid, source: .claudeSession)
            }
            return AttributedSegment(segment: seg, projectId: nil, source: .none)
        }

        // Tool apps take the project of the nearest snippet with its own signal (previous preferred).
        // Two linear passes instead of searching around every snippet – days have thousands of snippets.
        let isAnchor: (Int) -> Bool = { out[$0].source.isOwnSignal && out[$0].projectId != nil }
        var prevAnchor = [Int?](repeating: nil, count: out.count)
        var nextAnchor = [Int?](repeating: nil, count: out.count)
        var last: Int?
        for i in out.indices {
            prevAnchor[i] = last
            if isAnchor(i) { last = i }
        }
        last = nil
        for i in out.indices.reversed() {
            nextAnchor[i] = last
            if isAnchor(i) { last = i }
        }
        for i in out.indices where out[i].source == .none && context.toolApps.contains(out[i].segment.app.lowercased()) {
            let seg = out[i].segment
            let prev = prevAnchor[i].flatMap { seg.span.start.timeIntervalSince(out[$0].segment.span.end) <= context.inheritWindow ? $0 : nil }
            let next = nextAnchor[i].flatMap { out[$0].segment.span.start.timeIntervalSince(seg.span.end) <= context.inheritWindow ? $0 : nil }
            if let src = prev ?? next {
                out[i].projectId = out[src].projectId
                out[i].source = .context
            }
        }

        // Noise inherits the project only if the snippets before and after belong to the same project.
        var prevReal = [Int?](repeating: nil, count: out.count)
        var nextReal = [Int?](repeating: nil, count: out.count)
        last = nil
        for i in out.indices {
            prevReal[i] = last
            if out[i].source != .ignoredNoise { last = i }
        }
        last = nil
        for i in out.indices.reversed() {
            nextReal[i] = last
            if out[i].source != .ignoredNoise { last = i }
        }
        for i in out.indices where out[i].source == .ignoredNoise {
            if let prev = prevReal[i], let next = nextReal[i], let p = out[prev].projectId, out[next].projectId == p {
                out[i].projectId = p
                out[i].source = .absorbedNoise
            }
        }
        return out
    }

    /// Confirmed time entries win over automatic attribution – except for snippets that clearly belong to another project.
    public static func apply(entries: [TimeEntry], to segments: [AttributedSegment]) -> [AttributedSegment] {
        guard !entries.isEmpty else { return segments }
        return segments.map { s in
            let mid = s.segment.span.start.addingTimeInterval(s.segment.duration / 2)
            guard let e = entries.first(where: { $0.span.start <= mid && mid < $0.span.end }) else { return s }
            if s.source.isOwnSignal, let p = s.projectId, p != e.projectId { return s }
            var t = s
            t.projectId = e.projectId
            t.source = .entry
            return t
        }
    }
}

/// A block of time that probably belongs together, offered for one-click confirmation.
public struct BlockSuggestion: Identifiable, Hashable, Sendable {
    public var span: TimeSpan
    /// nil: work without a recognizable project – needs a project picked.
    public var projectId: Int64?
    /// Time in which snippets of this project were actually in front.
    public var activeTime: TimeInterval
    public var title: String
    public var apps: [String]

    public var id: String { "\(Int(span.start.timeIntervalSince1970))-\(projectId ?? -1)" }
}

public enum BlockSuggester {
    /// Groups the day into project blocks. Gaps up to `gap` are bridged; blocks shorter than `minLength` are dropped.
    /// Where blocks of different projects overlap (interleaved work), the one with more active time wins.
    public static func suggest(_ segments: [AttributedSegment], entries: [TimeEntry], gap: TimeInterval,
                               minLength: TimeInterval) -> [BlockSuggestion] {
        let covered = Spans.union(entries.map(\.span))
        let open = segments.filter { $0.counts && $0.source != .entry }
        func active(_ segs: [AttributedSegment], in spans: [TimeSpan]) -> TimeInterval {
            Spans.total(Spans.intersect(segs.map(\.segment.span), spans))
        }
        var candidates: [(span: TimeSpan, pid: Int64?, segs: [AttributedSegment], active: TimeInterval)] = []
        for (pid, segs) in Dictionary(grouping: open, by: \.projectId) {
            let sorted = segs.sorted { $0.segment.span.start < $1.segment.span.start }
            var i = 0
            for block in Spans.blocks(sorted.map(\.segment.span), maxGap: gap) {
                // Blocks come in time order, so the snippets inside can be collected with one moving index.
                var inside: [AttributedSegment] = []
                while i < sorted.count && sorted[i].segment.span.start < block.end {
                    inside.append(sorted[i])
                    i += 1
                }
                guard block.duration >= minLength else { continue }
                candidates.append((block, pid, inside, active(inside, in: [block])))
            }
        }
        candidates.sort { $0.active > $1.active }

        var taken = covered
        var out: [BlockSuggestion] = []
        for c in candidates {
            for piece in Spans.subtract([c.span], taken) where piece.duration >= minLength {
                let segs = c.segs.filter { piece.overlaps($0.segment.span) }
                let activeTime = active(segs, in: [piece])
                // Mostly idle pieces are not worth proposing.
                guard activeTime >= minLength / 2 else { continue }
                out.append(BlockSuggestion(span: piece, projectId: c.pid, activeTime: activeTime,
                                           title: title(for: segs), apps: topApps(segs)))
                taken = Spans.union(taken + [piece])
            }
        }
        return out.sorted { $0.span.start < $1.span.start }
    }

    static func title(for segs: [AttributedSegment]) -> String {
        var weight: [String: TimeInterval] = [:]
        for s in segs {
            let seg = s.segment
            let label: String
            if let d = seg.domain { label = seg.pageTitle.map { "\($0) (\(d))" } ?? d }
            else if let p = seg.path { label = (p as NSString).lastPathComponent }
            else if !seg.title.isEmpty && seg.title != seg.app { label = seg.title }
            else { continue }
            weight[label, default: 0] += seg.duration
        }
        return weight.max { $0.value < $1.value }?.key ?? ""
    }

    static func topApps(_ segs: [AttributedSegment]) -> [String] {
        var weight: [String: TimeInterval] = [:]
        for s in segs { weight[s.segment.app, default: 0] += s.segment.duration }
        return weight.sorted { $0.value > $1.value }.prefix(4).map(\.key)
    }
}

public struct ProjectDayStats: Identifiable, Hashable, Sendable {
    /// nil = not assigned
    public var projectId: Int64?
    public var foreground: TimeInterval = 0
    /// Part of the foreground time covered by confirmed time entries.
    public var confirmed: TimeInterval = 0
    public var manualBackground: TimeInterval = 0
    public var claude: TimeInterval = 0
    /// Union of manual and Claude background time.
    public var background: TimeInterval = 0
    /// Background time during which I was working on the same project in the foreground.
    public var overlap: TimeInterval = 0
    /// Extra time from several Claude sessions running at once for this project.
    public var claudeParallel: TimeInterval = 0
    /// Time in which I interacted with the session myself in the terminal (not counted as background).
    public var claudeInteractive: TimeInterval = 0
    public var billable: TimeInterval = 0
    public var blockCount: Int = 0
    public var longestBlock: TimeInterval = 0

    public var id: Int64 { projectId ?? -1 }
    /// Foreground + background, counting overlap twice.
    public var trackSum: TimeInterval { foreground + background }
    /// Wall-clock time touched by this project.
    public var wallClock: TimeInterval { foreground + background - overlap }
}

/// A Claude work span after removing time in which the terminal showing this session was in front.
public struct EffectiveClaudeSpan: Hashable, Sendable {
    public var sessionId: String
    public var span: TimeSpan
    public var projectId: Int64?
    public var cwd: String
    public var isOpen: Bool
}

public struct DayReport: Sendable {
    public var day: TimeSpan
    public var segments: [AttributedSegment]
    public var runs: [ClaudeRun]
    public var claudeSpans: [EffectiveClaudeSpan]
    public var manualTasks: [BackgroundEntry]
    public var entries: [TimeEntry]
    public var suggestions: [BlockSuggestion]
    public var stats: [ProjectDayStats]
    /// Σ (foreground + background) over all projects.
    public var trackSum: TimeInterval
    /// Wall-clock time in which anything was tracked.
    public var wallClock: TimeInterval
    public var doubleCounted: TimeInterval { max(0, trackSum - wallClock) }
    public var billableSum: TimeInterval
    public var billableWallClock: TimeInterval
    public var noiseIgnored: TimeInterval
    /// Claude Code working folders without a project mapping.
    public var unmappedFolders: [String: TimeInterval]

    public static func build(day: TimeSpan, segments: [Segment], assignments: [String: Int64], rules: [Rule],
                             projects: [Project], manualTasks: [BackgroundEntry], claudeEvents: [ClaudeEvent],
                             folders: [FolderMapping], settings: AppSettings, now: Date,
                             entries: [TimeEntry] = []) -> DayReport {
        let keywords = KeywordMatcher(projects: projects)
        let runs = ClaudeSessions.runs(from: claudeEvents, day: day, now: now, staleAfter: settings.claudeStaleAfter)
        let terminals = Set(settings.terminalApps.map { $0.lowercased() })
        let runProject: (ClaudeRun) -> Int64? = { run in
            FolderResolution.resolve(run.cwd, folders: folders, keywords: keywords).projectId
        }

        // Which Claude Code session does a terminal/Claude window show – if it can be told for sure?
        func shownRun(_ seg: Segment) -> ClaudeRun? {
            guard terminals.contains(seg.app.lowercased()) else { return nil }
            let open = runs.filter { $0.sessionSpan.overlaps(seg.span) }
            if let byTitle = open.first(where: { showsSession(seg.title, run: $0) }) { return byTitle }
            // You submitted a prompt while this window was in front.
            let typed = open.filter { r in
                r.prompts.contains { $0 >= seg.span.start.addingTimeInterval(-2) && $0 <= seg.span.end.addingTimeInterval(5) }
            }
            if typed.count == 1 { return typed[0] }
            return open.count == 1 ? open[0] : nil
        }

        // Project of a terminal/Claude window. Works with many parallel sessions (e.g. several worktrees of one repo).
        func claudeProject(_ seg: Segment) -> Int64? {
            guard terminals.contains(seg.app.lowercased()) else { return nil }
            if let run = shownRun(seg), let p = runProject(run) { return p }
            let open = runs.filter { $0.sessionSpan.overlaps(seg.span) }
            let projects = Set(open.compactMap(runProject))
            if projects.count == 1 { return projects.first }
            // Otherwise: the session you prompted most recently (within 30 minutes).
            let recent = open.compactMap { r -> (Date, ClaudeRun)? in
                r.prompts.filter { $0 <= seg.span.end.addingTimeInterval(5) && $0 >= seg.span.start.addingTimeInterval(-1800) }
                    .max().map { ($0, r) }
            }
            return recent.max { $0.0 < $1.0 }.flatMap { runProject($0.1) }
        }

        let context = Attribution.Context(folders: folders, keywords: keywords,
                                          claudeHint: { seg in claudeProject(seg) },
                                          toolApps: Set(settings.toolApps), inheritWindow: settings.inheritWindow)
        let automatic = Attribution.attribute(segments, assignments: assignments, rules: rules, context: context)
        let dayEntries = entries.compactMap { e -> TimeEntry? in
            guard let c = e.span.clamped(to: day) else { return nil }
            var e = e
            e.span = c
            return e
        }
        let attributed = Attribution.apply(entries: dayEntries, to: automatic)
        let suggestions = BlockSuggester.suggest(attributed, entries: dayEntries, gap: settings.suggestionGap,
                                                 minLength: settings.minSuggestion)

        let tasks = manualTasks.compactMap { t -> BackgroundEntry? in
            guard let c = t.span.clamped(to: day) else { return nil }
            var t = t
            t.span = c
            return t
        }

        // Terminal time that shows a session is my own foreground time, not background work.
        var claudeSpans: [EffectiveClaudeSpan] = []
        var interactiveBySession: [String: [TimeSpan]] = [:]
        for run in runs {
            let shown = attributed.filter { $0.counts && shownRun($0.segment)?.sessionId == run.sessionId }.map(\.segment.span)
            for w in run.work {
                interactiveBySession[run.sessionId, default: []] += Spans.intersect([w.span], shown)
                for rest in Spans.subtract([w.span], shown) {
                    claudeSpans.append(EffectiveClaudeSpan(sessionId: run.sessionId, span: rest,
                                                           projectId: FolderResolution.resolve(w.cwd, folders: folders, keywords: keywords).projectId,
                                                           cwd: w.cwd, isOpen: w.isOpen))
                }
            }
        }

        var unmapped: [String: TimeInterval] = [:]
        for c in claudeSpans where c.projectId == nil { unmapped[c.cwd, default: 0] += c.span.duration }

        let projectById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var ids = Set<Int64?>()
        attributed.filter(\.counts).forEach { ids.insert($0.projectId) }
        tasks.forEach { ids.insert($0.projectId) }
        claudeSpans.forEach { ids.insert($0.projectId) }
        dayEntries.forEach { ids.insert($0.projectId) }

        // Snippets that clearly belong to another project are cut out of an entry.
        func entrySpans(_ pid: Int64?) -> [TimeSpan] {
            guard let pid else { return [] }
            let mine = dayEntries.filter { $0.projectId == pid }.map(\.span)
            let foreign = attributed.filter { $0.counts && $0.projectId != pid && $0.source.isOwnSignal }.map(\.segment.span)
            return Spans.subtract(mine, foreign)
        }

        var stats: [ProjectDayStats] = []
        var allTracked: [TimeSpan] = []
        var allBillable: [TimeSpan] = []
        var trackSum: TimeInterval = 0
        var billableSum: TimeInterval = 0
        for pid in ids {
            let confirmed = entrySpans(pid)
            let fg = Spans.union(attributed.filter { $0.counts && $0.projectId == pid }.map(\.segment.span) + confirmed)
            let manual = tasks.filter { $0.projectId == pid }.map(\.span)
            let cc = claudeSpans.filter { $0.projectId == pid }.map(\.span)
            let bg = Spans.union(manual + cc)
            var s = ProjectDayStats(projectId: pid)
            s.foreground = Spans.total(fg)
            s.confirmed = Spans.total(confirmed)
            s.manualBackground = Spans.total(manual)
            s.claude = Spans.total(cc)
            s.claudeParallel = cc.reduce(0) { $0 + $1.duration } - s.claude
            s.background = Spans.total(bg)
            s.overlap = Spans.total(Spans.intersect(fg, bg))
            let sessionIds = Set(claudeSpans.filter { $0.projectId == pid }.map(\.sessionId))
            s.claudeInteractive = sessionIds.reduce(0) { $0 + Spans.total(interactiveBySession[$1] ?? []) }

            // Unassigned time is never billable.
            if let pid, let project = projectById[pid] {
                var billable = fg
                if project.backgroundBillable { billable += manual }
                if project.claudeBillable { billable += cc }
                s.billable = Spans.total(billable)
                allBillable += billable
            }
            let blocks = Spans.blocks(fg, maxGap: settings.blockGap)
            s.blockCount = blocks.count
            s.longestBlock = blocks.map(\.duration).max() ?? 0

            stats.append(s)
            allTracked += fg + bg
            trackSum += s.trackSum
            billableSum += s.billable
        }
        stats.sort { a, b in
            if (a.projectId == nil) != (b.projectId == nil) { return b.projectId == nil }
            return a.trackSum > b.trackSum
        }

        return DayReport(day: day, segments: attributed, runs: runs, claudeSpans: claudeSpans, manualTasks: tasks,
                         entries: dayEntries, suggestions: suggestions,
                         stats: stats, trackSum: trackSum, wallClock: Spans.total(allTracked),
                         billableSum: billableSum, billableWallClock: Spans.total(allBillable),
                         noiseIgnored: attributed.filter { !$0.counts }.reduce(0) { $0 + $1.segment.duration },
                         unmappedFolders: unmapped)
    }

    static func showsSession(_ windowTitle: String, run: ClaudeRun) -> Bool {
        let folder = run.folderName
        if folder.count >= 3, windowTitle.localizedCaseInsensitiveContains(folder) { return true }
        if let t = run.title, t.count >= 3, windowTitle.localizedCaseInsensitiveContains(t) { return true }
        return false
    }
}
