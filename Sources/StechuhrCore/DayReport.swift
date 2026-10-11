import Foundation

public enum AssignmentSource: Hashable, Sendable {
    case manual, rule
    /// Short switch absorbed into the surrounding project.
    case absorbedNoise
    /// Short switch between different projects – ignored entirely.
    case ignoredNoise
    case none
}

public struct AttributedSegment: Identifiable, Hashable, Sendable {
    public var segment: Segment
    public var projectId: Int64?
    public var source: AssignmentSource

    public var id: String { segment.key }
    public var counts: Bool { source != .ignoredNoise }
}

/// Manual assignments: segment key → project id. `noProject` explicitly clears an assignment a rule would make.
public enum Attribution {
    public static let noProject: Int64 = 0

    public static func attribute(_ segments: [Segment], assignments: [String: Int64], rules: [Rule]) -> [AttributedSegment] {
        let rules = rules.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
        var out = segments.map { seg -> AttributedSegment in
            if let p = assignments[seg.key] {
                return AttributedSegment(segment: seg, projectId: p == noProject ? nil : p, source: .manual)
            }
            if seg.isNoise { return AttributedSegment(segment: seg, projectId: nil, source: .ignoredNoise) }
            if let r = rules.first(where: { $0.matches(seg) }) {
                return AttributedSegment(segment: seg, projectId: r.projectId, source: .rule)
            }
            return AttributedSegment(segment: seg, projectId: nil, source: .none)
        }
        // Noise inherits the project only if the snippets before and after belong to the same project.
        let real = out.indices.filter { out[$0].source != .ignoredNoise }
        for i in out.indices where out[i].source == .ignoredNoise {
            let prev = real.last { $0 < i }, next = real.first { $0 > i }
            if let prev, let next, let p = out[prev].projectId, out[next].projectId == p {
                out[i].projectId = p
                out[i].source = .absorbedNoise
            }
        }
        return out
    }
}

public struct ProjectDayStats: Identifiable, Hashable, Sendable {
    /// nil = not assigned
    public var projectId: Int64?
    public var foreground: TimeInterval = 0
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
                             folders: [FolderMapping], settings: AppSettings, now: Date) -> DayReport {
        let attributed = Attribution.attribute(segments, assignments: assignments, rules: rules)
        let runs = ClaudeSessions.runs(from: claudeEvents, day: day, now: now, staleAfter: settings.claudeStaleAfter)
        let tasks = manualTasks.compactMap { t -> BackgroundEntry? in
            guard let c = t.span.clamped(to: day) else { return nil }
            var t = t
            t.span = c
            return t
        }

        // Terminal time that shows a session is my own foreground time, not background work.
        let terminals = Set(settings.terminalApps.map { $0.lowercased() })
        let terminalSegs = attributed.filter { $0.counts && terminals.contains($0.segment.app.lowercased()) }
        var claudeSpans: [EffectiveClaudeSpan] = []
        var interactiveBySession: [String: [TimeSpan]] = [:]
        for run in runs {
            let shown = terminalSegs.filter { seg in
                guard run.sessionSpan.overlaps(seg.segment.span) else { return false }
                if showsSession(seg.segment.title, run: run) { return true }
                // Exactly one open session at that moment → the terminal must be showing it.
                let openRuns = runs.filter { $0.sessionSpan.overlaps(seg.segment.span) }
                return openRuns.count == 1 && !runs.contains { other in
                    other.sessionId != run.sessionId && showsSession(seg.segment.title, run: other)
                }
            }.map(\.segment.span)
            for w in run.work {
                let removed = Spans.intersect([w.span], shown)
                interactiveBySession[run.sessionId, default: []] += removed
                for rest in Spans.subtract([w.span], shown) {
                    claudeSpans.append(EffectiveClaudeSpan(sessionId: run.sessionId, span: rest,
                                                           projectId: FolderMapping.project(for: w.cwd, in: folders),
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

        var stats: [ProjectDayStats] = []
        var allTracked: [TimeSpan] = []
        var allBillable: [TimeSpan] = []
        var trackSum: TimeInterval = 0
        var billableSum: TimeInterval = 0
        for pid in ids {
            let fg = attributed.filter { $0.counts && $0.projectId == pid }.map(\.segment.span)
            let manual = tasks.filter { $0.projectId == pid }.map(\.span)
            let cc = claudeSpans.filter { $0.projectId == pid }.map(\.span)
            let bg = Spans.union(manual + cc)
            var s = ProjectDayStats(projectId: pid)
            s.foreground = Spans.total(fg)
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
