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
