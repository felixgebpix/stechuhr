import XCTest
@testable import StechuhrCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func t(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
private func span(_ a: Double, _ b: Double) -> TimeSpan { TimeSpan(t(a), t(b)) }
private let day = span(-600, 600)

private func seg(_ key: String, _ a: Double, _ b: Double, app: String = "Figma", title: String = "", noise: Bool = false) -> Segment {
    Segment(key: key, span: span(a, b), app: app, title: title, isNoise: noise)
}

final class SpansTests: XCTestCase {
    func testUnionIntersectSubtract() {
        XCTAssertEqual(Spans.union([span(0, 10), span(5, 20), span(30, 40)]), [span(0, 20), span(30, 40)])
        XCTAssertEqual(Spans.intersect([span(0, 20)], [span(10, 30)]), [span(10, 20)])
        XCTAssertEqual(Spans.subtract([span(0, 30)], [span(10, 20)]), [span(0, 10), span(20, 30)])
        XCTAssertEqual(Spans.total([span(0, 10), span(5, 15)]), 15 * 60)
    }

    func testBlocks() {
        let blocks = Spans.blocks([span(0, 10), span(11, 20), span(40, 50)], maxGap: 120)
        XCTAssertEqual(blocks, [span(0, 20), span(40, 50)])
    }
}

final class AttributionTests: XCTestCase {
    func testNoiseBetweenSameProjectIsAbsorbed() {
        let rules = [Rule(id: 1, projectId: 7, conditions: [RuleCondition(.app, .equals, "Figma")])]
        let segs = [seg("a", 0, 10), seg("n", 10, 10.1, app: "Slack", noise: true), seg("b", 10.1, 20)]
        let out = Attribution.attribute(segs, assignments: [:], rules: rules)
        XCTAssertEqual(out[1].projectId, 7)
        XCTAssertEqual(out[1].source, .absorbedNoise)
    }

    func testShortSwitchBetweenProjectsKeepsOwnAssignment() {
        // A 1-minute switch is not noise: it keeps its own project instead of being swallowed.
        let rules = [Rule(id: 1, projectId: 7, conditions: [RuleCondition(.title, .contains, "DFA")])]
        let segs = [seg("a", 0, 10, title: "DFA"), seg("x", 10, 11, app: "Mail", title: "Andere"), seg("b", 11, 20, title: "DFA")]
        let out = Attribution.attribute(segs, assignments: ["x": 9], rules: rules)
        XCTAssertEqual(out.map(\.projectId), [7, 9, 7])
    }

    func testNoiseBetweenDifferentProjectsIsIgnored() {
        let segs = [seg("a", 0, 10), seg("n", 10, 10.1, noise: true), seg("b", 10.1, 20)]
        let out = Attribution.attribute(segs, assignments: ["a": 1, "b": 2], rules: [])
        XCTAssertEqual(out[1].source, .ignoredNoise)
        XCTAssertFalse(out[1].counts)
    }

    func testManualBeatsRuleAndNoProjectClears() {
        let rules = [Rule(id: 1, projectId: 7, conditions: [RuleCondition(.app, .equals, "Figma")])]
        let out = Attribution.attribute([seg("a", 0, 10)], assignments: ["a": Attribution.noProject], rules: rules)
        XCTAssertNil(out[0].projectId)
        XCTAssertEqual(out[0].source, .manual)
    }
}

final class ClaudeSessionTests: XCTestCase {
    func ev(_ s: String, _ name: String, _ m: Double, cwd: String = "/r/app", type: String? = nil) -> ClaudeEvent {
        ClaudeEvent(sessionId: s, event: name, ts: t(m), cwd: cwd, notificationType: type)
    }

    func testPromptToStopIsWork_WaitingIsNot() {
        let events = [
            ev("s", "SessionStart", 0), ev("s", "UserPromptSubmit", 1), ev("s", "PermissionRequest", 5),
            ev("s", "PostToolUse", 8), ev("s", "Stop", 12), ev("s", "UserPromptSubmit", 30),
            ev("s", "Notification", 40, type: "idle_prompt"), ev("s", "SessionEnd", 50),
        ]
        let runs = ClaudeSessions.runs(from: events, day: day, now: t(100), staleAfter: 3600)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].work.map(\.span), [span(1, 5), span(8, 12), span(30, 40)])
    }

    func testOpenTurnRunsUntilNow() {
        let runs = ClaudeSessions.runs(from: [ev("s", "UserPromptSubmit", 0)], day: day, now: t(20), staleAfter: 3600)
        XCTAssertEqual(runs[0].work.first?.span, span(0, 20))
        XCTAssertEqual(runs[0].work.first?.isOpen, true)
    }

    func testStaleTurnEndsAtLastEvent() {
        let events = [ev("s", "UserPromptSubmit", 0), ev("s", "PostToolUse", 10)]
        let runs = ClaudeSessions.runs(from: events, day: day, now: t(500), staleAfter: 3600)
        XCTAssertEqual(runs[0].work.first?.span, span(0, 10))
        XCTAssertEqual(runs[0].work.first?.isOpen, false)
    }
}

final class DayReportTests: XCTestCase {
    func testOverlapBillableAndTerminalDedupe() {
        let p = Project(id: 1, name: "DFA", colorHex: "#f00", claudeBillable: true)
        let q = Project(id: 2, name: "Intern", colorHex: "#0f0", claudeBillable: false)
        let segs = [
            seg("fig", 0, 30, app: "Figma", title: "DFA Screens"),
            seg("term", 30, 40, app: "Terminal", title: "✳ app — claude"),  // looking at the session itself
            seg("mail", 40, 60, app: "Mail", title: "Inbox"),
        ]
        let events = [
            ClaudeEvent(sessionId: "s", event: "UserPromptSubmit", ts: t(10), cwd: "/r/app"),
            ClaudeEvent(sessionId: "s", event: "Stop", ts: t(50), cwd: "/r/app"),
            ClaudeEvent(sessionId: "u", event: "UserPromptSubmit", ts: t(0), cwd: "/elsewhere/tool"),
            ClaudeEvent(sessionId: "u", event: "Stop", ts: t(5), cwd: "/elsewhere/tool"),
        ]
        let report = DayReport.build(
            day: day, segments: segs, assignments: ["fig": 1, "term": 1, "mail": 2], rules: [], projects: [p, q],
            manualTasks: [BackgroundEntry(projectId: 2, span: span(45, 70))], claudeEvents: events,
            folders: [FolderMapping(path: "/r", projectId: 1)], settings: AppSettings(), now: t(100))

        let dfa = report.stats.first { $0.projectId == 1 }!
        XCTAssertEqual(dfa.foreground, 40 * 60)
        // Claude worked 10–50, minus 30–40 in which the terminal showing it was in front.
        XCTAssertEqual(dfa.claude, 30 * 60)
        XCTAssertEqual(dfa.claudeInteractive, 10 * 60)
        // Overlap with my own DFA work: 10–30.
        XCTAssertEqual(dfa.overlap, 20 * 60)
        XCTAssertEqual(dfa.billable, 50 * 60)  // 0–50 wall clock

        let intern = report.stats.first { $0.projectId == 2 }!
        XCTAssertEqual(intern.foreground, 20 * 60)
        XCTAssertEqual(intern.manualBackground, 25 * 60)
        XCTAssertEqual(intern.overlap, 15 * 60)

        XCTAssertEqual(report.unmappedFolders["/elsewhere/tool"], 5 * 60)
        XCTAssertGreaterThan(report.doubleCounted, 0)
        XCTAssertEqual(report.wallClock, 70 * 60)
    }

    func testBlocksCountFragmentation() {
        let segs = [seg("a", 0, 10), seg("b", 10, 15, app: "Mail"), seg("c", 15, 20), seg("d", 60, 70)]
        let report = DayReport.build(day: day, segments: segs, assignments: ["a": 1, "c": 1, "d": 1, "b": 2], rules: [],
                                     projects: [Project(id: 1, name: "P", colorHex: "#000"), Project(id: 2, name: "Q", colorHex: "#111")],
                                     manualTasks: [], claudeEvents: [], folders: [], settings: AppSettings(), now: t(100))
        let p = report.stats.first { $0.projectId == 1 }!
        XCTAssertEqual(p.blockCount, 3)
        XCTAssertEqual(p.longestBlock, 10 * 60)
    }
}

final class SegmenterTests: XCTestCase {
    func testRecordedEventsBecomeSegments() {
        let events = [
            RecordedEvent(id: 1, span: span(-700, 5), app: "Figma", title: "DFA Screens"),
            RecordedEvent(id: 2, span: span(5, 15), app: "Google Chrome", title: "x", url: "https://www.figma.com/file/1", pageTitle: "DFA"),
            RecordedEvent(id: 3, span: span(15, 15.1), app: "Slack", title: "Chat"),
        ]
        let segs = Segmenter.segments(from: events, day: day, noiseThreshold: 12)
        XCTAssertEqual(segs.map(\.key), ["e1", "e2", "e3"])
        XCTAssertEqual(segs[0].span.start, day.start)  // clipped to the day
        XCTAssertEqual(segs[1].domain, "figma.com")
        XCTAssertEqual(segs[1].displayTitle, "DFA")
        XCTAssertEqual(segs.map(\.isNoise), [false, false, true])
    }
}

final class MiscTests: XCTestCase {
    func testFolderMappingLongestPrefix() {
        let m = [FolderMapping(path: "/r", projectId: 1), FolderMapping(path: "/r/client", projectId: 2)]
        XCTAssertEqual(FolderMapping.project(for: "/r/client/sub", in: m), 2)
        XCTAssertEqual(FolderMapping.project(for: "/r/other", in: m), 1)
        XCTAssertNil(FolderMapping.project(for: "/rx", in: m))
    }

    func testHTTPParseWaitsForBody() {
        let partial = Data("POST /v1/claude-code/events HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8)
        XCTAssertNil(HTTPRequest.parse(partial))
        let full = Data("POST /v1/claude-code/events HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcd".utf8)
        XCTAssertEqual(HTTPRequest.parse(full)?.body, Data("abcd".utf8))
    }

    func testDatabaseRoundTripAndInbox() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        let id = try db.save(Project(name: "DFA", colorHex: "#123456"))
        try db.save(Rule(projectId: id, conditions: [RuleCondition(.app, .equals, "Figma")]))
        try db.assign(["k"], day: "2026-10-11", projectId: id)
        XCTAssertEqual(try db.assignments(day: "2026-10-11"), ["k": id])
        XCTAssertEqual(try db.rules().first?.conditions.first?.value, "Figma")

        let inbox = dir.appendingPathComponent("claude-events.jsonl")
        let line = #"{"uuid":"u1","ts":1800000000,"session_id":"s","hook_event_name":"Stop","cwd":"/r"}"#
        try (line + "\n" + line + "\n").write(to: inbox, atomically: true, encoding: .utf8)
        XCTAssertEqual(HookInbox.drain(into: db, file: inbox), 2)
        XCTAssertEqual(try db.claudeEventCount(), 1)  // duplicate uuid ignored
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))

        let rid = try db.insertRecorded(RecordedEvent(span: span(0, 0), app: "Figma", title: "DFA"))
        try db.extendRecorded(id: rid, to: t(10))
        let rec = try db.recorded(overlapping: span(5, 6))
        XCTAssertEqual(rec.first?.span, span(0, 10))
    }
}

final class KeywordTests: XCTestCase {
    let dfa = Project(id: 1, name: "DFA", colorHex: "#f00", keywords: ["Deutsche Fachagentur", "dfa-website"])
    let kx = Project(id: 2, name: "Kunde X", colorHex: "#0f0", keywords: ["kundex"])

    func testWholeWordsOnly() {
        let m = KeywordMatcher(projects: [dfa, kx])
        XCTAssertEqual(m.match(["Figma – DFA Startseite"]), .match(projectId: 1, term: "DFA"))
        XCTAssertEqual(m.match(["https://github.com/firma/dfa-website/pull/3"]), .match(projectId: 1, term: "DFA"))
        XCTAssertEqual(m.match(["Schadfall Übersicht", "DFAX"]), .none)
        XCTAssertEqual(m.match(["Mail – deutsche fachagentur Angebot"]), .match(projectId: 1, term: "Deutsche Fachagentur"))
    }

    func testAmbiguousIsNotAssigned() {
        let m = KeywordMatcher(projects: [dfa, kx])
        XCTAssertEqual(m.match(["DFA × Kunde X Abstimmung"]), .ambiguous([1, 2]))
        let out = Attribution.attribute([seg("a", 0, 10, app: "Mail", title: "DFA × Kunde X")], assignments: [:], rules: [], keywords: m)
        XCTAssertNil(out[0].projectId)
        XCTAssertEqual(out[0].source, .ambiguous([1, 2]))
    }

    func testRulesBeatKeywords() {
        let m = KeywordMatcher(projects: [dfa, kx])
        let rules = [Rule(id: 1, projectId: 2, conditions: [RuleCondition(.app, .equals, "Figma")])]
        let out = Attribution.attribute([seg("a", 0, 10, title: "DFA")], assignments: [:], rules: rules, keywords: m)
        XCTAssertEqual(out[0].projectId, 2)
    }

    func testFolderByKeyword() {
        let m = KeywordMatcher(projects: [dfa, kx])
        let home = NSHomeDirectory()
        XCTAssertEqual(FolderResolution.resolve(home + "/repos/dfa-website/app", folders: [], keywords: m), .keyword(1, term: "DFA"))
        XCTAssertEqual(FolderResolution.resolve(home + "/repos/dfa-website", folders: [FolderMapping(path: home + "/repos", projectId: 2)], keywords: m), .mapping(2))
        XCTAssertEqual(FolderResolution.resolve(home + "/repos/timetracker", folders: [], keywords: m), .none)
    }
}

final class SuggestionTests: XCTestCase {
    func sample(_ key: String, _ app: String, _ title: String, project: Int64, day: String, minutes: Double = 10) -> RuleSuggester.Sample {
        RuleSuggester.Sample(segment: seg(key, 0, minutes, app: app, title: title), projectId: project, day: day)
    }

    func testSuggestsConsistentManualAssignments() {
        let samples = [
            sample("1", "Slack", "#kunde-x", project: 2, day: "d1"),
            sample("2", "Slack", "#kunde-x", project: 2, day: "d2"),
            sample("3", "Slack", "#kunde-x", project: 2, day: "d2"),
            sample("4", "Slack", "#dfa", project: 1, day: "d1"),
        ]
        let s = RuleSuggester.suggest(from: samples, rules: [], dismissed: [])
        // "Slack" alone is not consistent (3:1 < 90 %), but Slack + "#kunde-x" is.
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].projectId, 2)
        XCTAssertEqual(s[0].conditions, [RuleCondition(.app, .equals, "Slack"), RuleCondition(.title, .equals, "#kunde-x")])

        XCTAssertTrue(RuleSuggester.suggest(from: samples, rules: [], dismissed: [s[0].id]).isEmpty)
        let covered = [Rule(id: 1, projectId: 2, conditions: s[0].conditions)]
        XCTAssertTrue(RuleSuggester.suggest(from: samples, rules: covered, dismissed: []).isEmpty)
    }

    func testPrefersGeneralPattern() {
        let samples = (1...4).map { sample("\($0)", "Figma", "Screen \($0)", project: 1, day: "d\($0)") }
        let s = RuleSuggester.suggest(from: samples, rules: [], dismissed: [])
        XCTAssertEqual(s.map(\.conditions), [[RuleCondition(.app, .equals, "Figma")]])
    }
}

final class HookSecurityTests: XCTestCase {
    func testParsesHeadersLowercased() {
        let raw = Data("POST /v1/claude-code/events HTTP/1.1\r\nHost: 127.0.0.1:47600\r\nX-Stechuhr-Token: abc\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let req = HTTPRequest.parse(raw)
        XCTAssertEqual(req?.headers["x-stechuhr-token"], "abc")
        XCTAssertEqual(req?.headers["host"], "127.0.0.1:47600")
    }

    func testTokenComparison() {
        XCTAssertTrue(HookToken.matches("abcd", "abcd"))
        XCTAssertFalse(HookToken.matches("abce", "abcd"))
        XCTAssertFalse(HookToken.matches(nil, "abcd"))
        XCTAssertFalse(HookToken.matches("abc", "abcd"))
    }

    func testTokenFileIsPrivateAndStable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = HookToken.loadOrCreate(at: url)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(HookToken.loadOrCreate(at: url), a)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }
}

final class BlockTests: XCTestCase {
    let p1 = Project(id: 1, name: "Stechuhr", colorHex: "#f00")
    let p2 = Project(id: 2, name: "DFA", colorHex: "#0f0")

    func testToolAppsInheritSurroundingProject() {
        let segs = [
            seg("a", 0, 5, app: "Waterfox", title: "Stechuhr – Docs"),
            seg("b", 5, 6, app: "GitKraken", title: "GitKraken Desktop"),
            seg("c", 6, 8, app: "Signal", title: "Chat"),
        ]
        var settings = AppSettings()
        settings.toolApps = ["GitKraken"]
        let r = DayReport.build(day: day, segments: segs, assignments: [:], rules: [], projects: [p1], manualTasks: [],
                                claudeEvents: [], folders: [], settings: settings, now: t(100))
        XCTAssertEqual(r.segments.map(\.projectId), [1, 1, nil])  // Signal is no tool → stays unassigned
        XCTAssertEqual(r.segments[1].source, .context)
    }

    func testClaudeWindowTakesProjectOfItsSession() {
        let home = NSHomeDirectory()
        let events = [ClaudeEvent(sessionId: "s", event: "UserPromptSubmit", ts: t(0), cwd: home + "/repos/stechuhr"),
                      ClaudeEvent(sessionId: "s", event: "Stop", ts: t(30), cwd: home + "/repos/stechuhr")]
        let r = DayReport.build(day: day, segments: [seg("c", 5, 10, app: "Claude", title: "Claude")], assignments: [:], rules: [],
                                projects: [p1], manualTasks: [], claudeEvents: events, folders: [], settings: AppSettings(), now: t(100))
        XCTAssertEqual(r.segments[0].projectId, 1)
        XCTAssertEqual(r.segments[0].source, .claudeSession)
    }

    func testEntryCoversToolsButNotOtherProjects() {
        let segs = [
            seg("a", 0, 20, app: "Waterfox", title: "Stechuhr"),
            seg("m", 20, 25, app: "Mail", title: "DFA Angebot"),  // own signal for DFA
            seg("x", 25, 30, app: "Signal", title: "Chat"),        // no signal
            seg("b", 30, 50, app: "Waterfox", title: "Stechuhr"),
        ]
        let entry = TimeEntry(projectId: 1, span: span(0, 60))
        let r = DayReport.build(day: day, segments: segs, assignments: [:], rules: [], projects: [p1, p2], manualTasks: [],
                                claudeEvents: [], folders: [], settings: AppSettings(), now: t(100), entries: [entry])
        let s1 = r.stats.first { $0.projectId == 1 }!
        XCTAssertEqual(s1.foreground, 55 * 60)   // 0–60 minus DFA mail 20–25
        XCTAssertEqual(s1.confirmed, 55 * 60)
        XCTAssertEqual(r.stats.first { $0.projectId == 2 }!.foreground, 5 * 60)
        XCTAssertEqual(r.segments[2].source, .entry)
        XCTAssertTrue(r.suggestions.isEmpty)
    }

    func testSuggestionsBridgeInterleavedWork() {
        // Stechuhr work with short tool switches and a 3-minute pause → one block.
        let segs = [
            seg("a", 0, 10, app: "Waterfox", title: "Stechuhr"),
            seg("b", 10, 11, app: "GitKraken", title: ""),
            seg("c", 14, 30, app: "Waterfox", title: "Stechuhr"),
            seg("d", 60, 62, app: "Waterfox", title: "Stechuhr"),   // too short alone
        ]
        var settings = AppSettings()
        settings.toolApps = ["GitKraken"]
        let r = DayReport.build(day: day, segments: segs, assignments: [:], rules: [], projects: [p1], manualTasks: [],
                                claudeEvents: [], folders: [], settings: settings, now: t(100))
        XCTAssertEqual(r.suggestions.map(\.span), [span(0, 30)])
        XCTAssertEqual(r.suggestions.first?.projectId, 1)
        XCTAssertEqual(r.suggestions.first?.title, "Stechuhr")
    }

    func testDocumentPathInMappedFolder() {
        let home = NSHomeDirectory()
        var s = seg("f", 0, 10, app: "Vorschau", title: "Angebot.pdf")
        s.path = home + "/Kunden/DFA/Angebot.pdf"
        let out = Attribution.attribute([s], assignments: [:], rules: [],
                                        context: .init(folders: [FolderMapping(path: "~/Kunden/DFA", projectId: 2)]))
        XCTAssertEqual(out[0].projectId, 2)
        XCTAssertEqual(out[0].source, .folder)
        XCTAssertTrue(RuleCondition(.path, .prefix, "~/Kunden").matches(s))
        XCTAssertTrue(RuleCondition(.title, .suffix, ".pdf").matches(s))
    }
}

final class ProjectSuggesterTests: XCTestCase {
    func testGroupsClonesAndPrefixes() {
        let c = [
            ProjectSuggester.Candidate(path: "/r/timetracker", remote: "felix/stechuhr"),
            ProjectSuggester.Candidate(path: "/r/stechuhr", remote: "felix/stechuhr"),
            ProjectSuggester.Candidate(path: "/r/appmarsch", remote: "felix/appmarsch"),
            ProjectSuggester.Candidate(path: "/r/appmarsch-vergleich"),
            ProjectSuggester.Candidate(path: "/r/padi-abrechnung", remote: "felix/padi-abrechnung"),
            ProjectSuggester.Candidate(path: "/r/known"),
        ]
        let s = ProjectSuggester.suggest(c, projects: [Project(id: 9, name: "Known", colorHex: "#000")], folders: [])
        XCTAssertEqual(s.map(\.name), ["appmarsch", "padi-abrechnung", "stechuhr"])
        XCTAssertEqual(s.first { $0.name == "stechuhr" }?.folders, ["/r/stechuhr", "/r/timetracker"])
        XCTAssertEqual(s.first { $0.name == "appmarsch" }?.folders.count, 2)
    }

    func testNormalizeRemote() {
        XCTAssertEqual(ProjectSuggester.normalize(remote: "https://github.com/Felix/Stechuhr.git"), "felix/stechuhr")
        XCTAssertEqual(ProjectSuggester.normalize(remote: "git@github.com:felix/app.git"), "felix/app")
    }
}

final class ContextPrompterTests: XCTestCase {
    func a(_ key: String, _ s: Double, _ e: Double, _ pid: Int64?, _ source: AssignmentSource) -> AttributedSegment {
        AttributedSegment(segment: seg(key, s, e), projectId: pid, source: source)
    }

    func testAsksAfterThreeMinutesOfUnclearWork() {
        let segs = [a("1", 0, 20, 1, .keyword("DFA")), a("2", 20, 22, nil, .none), a("3", 22, 24, nil, .ambiguous([1, 2]))]
        XCTAssertEqual(ContextPrompter.unclear(segments: segs, now: t(24), minDuration: 180), t(20))
        // Only 2 minutes so far → not yet.
        XCTAssertNil(ContextPrompter.unclear(segments: Array(segs.prefix(2)), now: t(22), minDuration: 180))
        // Inherited tool context is clear enough.
        XCTAssertNil(ContextPrompter.unclear(segments: [a("1", 0, 20, 1, .keyword("DFA")), a("2", 20, 30, 1, .context)], now: t(30), minDuration: 180))
        // Not active right now → no question.
        XCTAssertNil(ContextPrompter.unclear(segments: segs, now: t(40), minDuration: 180))
        XCTAssertEqual(ContextPrompter.candidates(segments: segs, entries: [], before: t(24)), [1, 2])
    }

    func testAwayAfterReturn() {
        let ev = [RecordedEvent(id: 1, span: span(0, 10), app: "A", title: ""), RecordedEvent(id: 2, span: span(40, 41), app: "A", title: "")]
        XCTAssertEqual(ContextPrompter.away(events: ev, covered: [], now: t(41), threshold: 900), span(10, 40))
        XCTAssertNil(ContextPrompter.away(events: ev, covered: [span(10, 40)], now: t(41), threshold: 900))
        XCTAssertNil(ContextPrompter.away(events: ev, covered: [], now: t(50), threshold: 900))  // returned too long ago
    }
}

final class RangeAndPerformanceTests: XCTestCase {
    func testCSVUsesGermanFormatAndEscapes() {
        let p = Project(id: 1, name: "DFA; Relaunch", colorHex: "#000")
        let r = DayReport.build(day: day, segments: [seg("a", 0, 75, title: "x")], assignments: ["a": 1], rules: [], projects: [p],
                                manualTasks: [], claudeEvents: [], folders: [], settings: AppSettings(), now: t(100),
                                entries: [TimeEntry(projectId: 1, span: span(0, 90), title: "Konzept \"v2\"")])
        let csv = CSVExport.projectDays([r]) { $0 == 1 ? p.name : "nicht zugeordnet" }
        XCTAssertTrue(csv.contains("\"DFA; Relaunch\";1,50;1,50"), csv)
        let entries = CSVExport.entries([r]) { _ in p.name }
        XCTAssertTrue(entries.contains("\"Konzept \"\"v2\"\"\""), entries)
        let sum = RangeReport.aggregate([r, r])
        XCTAssertEqual(sum.first?.foreground, 2 * 90 * 60)
    }

    func testFullDayStaysFast() {
        // ~ a long day: 6000 snippets, 20 projects with keywords, tool apps in between.
        let projects = (1...20).map { Project(id: Int64($0), name: "Projekt\($0)", colorHex: "#000", keywords: ["kunde\($0)"]) }
        var segs: [Segment] = []
        for i in 0..<6000 {
            let s = Double(i) * 0.15
            let app = i % 3 == 0 ? "GitKraken" : "Waterfox"
            segs.append(seg("s\(i)", s, s + 0.14, app: app, title: i % 7 == 0 ? "kunde\(i % 20 + 1) Angebot" : "Seite \(i)"))
        }
        var settings = AppSettings()
        settings.toolApps = ["GitKraken"]
        let start = Date()
        let r = DayReport.build(day: day, segments: segs, assignments: [:], rules: [], projects: projects, manualTasks: [],
                                claudeEvents: [], folders: [], settings: settings, now: t(1000))
        XCTAssertFalse(r.segments.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
}

final class RunningEntryTests: XCTestCase {
    func a(_ key: String, _ s: Double, _ e: Double, _ pid: Int64?, _ source: AssignmentSource) -> AttributedSegment {
        AttributedSegment(segment: seg(key, s, e), projectId: pid, source: source)
    }
    let entry = TimeEntry(projectId: 1, span: span(0, 10))

    func testShortGlanceDoesNotStop() {
        let segs = [a("1", 10, 20, nil, .none), a("2", 20, 20.5, 2, .keyword("DFA")), a("3", 20.5, 30, nil, .none)]
        let r = RunningEntry.extend(entry, segments: segs, now: t(30), foreignAfter: 180, awayAfter: 900)
        XCTAssertEqual(r.end, t(30))
        XCTAssertTrue(r.running)
    }

    func testLongForeignWorkStops() {
        let segs = [a("1", 10, 20, nil, .none), a("2", 20, 25, 2, .keyword("DFA"))]
        let r = RunningEntry.extend(entry, segments: segs, now: t(25), foreignAfter: 180, awayAfter: 900)
        XCTAssertEqual(r.end, t(20))
        XCTAssertFalse(r.running)
    }

    func testBreakStops() {
        let segs = [a("1", 10, 20, nil, .none), a("2", 50, 60, nil, .none)]
        let r = RunningEntry.extend(entry, segments: segs, now: t(60), foreignAfter: 180, awayAfter: 900)
        XCTAssertEqual(r.end, t(20))
        XCTAssertFalse(r.running)
    }
}
