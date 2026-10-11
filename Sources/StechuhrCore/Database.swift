import Foundation
import SQLite3

public enum StechuhrPaths {
    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Stechuhr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    public static var database: URL { supportDir.appendingPathComponent("stechuhr.sqlite") }
    /// Fallback inbox the hook helper appends to when the app is not running.
    public static var hookInbox: URL { supportDir.appendingPathComponent("claude-events.jsonl") }
    public static var hookBinary: URL { supportDir.appendingPathComponent("bin/stechuhr-hook") }
    public static let hookPort: UInt16 = 47600
}

public enum DatabaseError: Error { case sqlite(String) }

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin SQLite wrapper. Not thread-safe – use from one actor.
public final class Database {
    private var db: OpaquePointer?

    public init(url: URL = StechuhrPaths.database) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw DatabaseError.sqlite("Datenbank konnte nicht geöffnet werden: \(url.path)")
        }
        // Recorder and UI use separate connections; wait briefly instead of failing on a lock.
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try migrate()
        try addColumnIfMissing("projects", "keywords", "TEXT NOT NULL DEFAULT '[]'")
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS projects(
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL,
            bg_billable INTEGER NOT NULL DEFAULT 1, cc_billable INTEGER NOT NULL DEFAULT 1,
            archived INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS rules(
            id INTEGER PRIMARY KEY, project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            conditions TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 100);
        CREATE TABLE IF NOT EXISTS assignments(
            segment_key TEXT PRIMARY KEY, day TEXT NOT NULL, project_id INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS assignments_day ON assignments(day);
        CREATE TABLE IF NOT EXISTS background_tasks(
            id INTEGER PRIMARY KEY, project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            start REAL NOT NULL, end REAL NOT NULL, note TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS claude_events(
            uuid TEXT PRIMARY KEY, session_id TEXT NOT NULL, event TEXT NOT NULL, ts REAL NOT NULL,
            cwd TEXT NOT NULL, notification_type TEXT, source TEXT, reason TEXT, agent_id TEXT, session_title TEXT);
        CREATE INDEX IF NOT EXISTS claude_events_ts ON claude_events(ts);
        CREATE TABLE IF NOT EXISTS folder_mappings(
            id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE,
            project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS foreground_events(
            id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, app TEXT NOT NULL,
            bundle_id TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', url TEXT, page_title TEXT);
        CREATE INDEX IF NOT EXISTS foreground_events_start ON foreground_events(start);
        """)
    }

    private func addColumnIfMissing(_ table: String, _ column: String, _ type: String) throws {
        var exists = false
        try run("SELECT name FROM pragma_table_info('\(table)')") { s in
            if self.text(s, 0) == column { exists = true }
        }
        if !exists { try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
    }

    // MARK: - Low level

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unbekannt"
            sqlite3_free(err)
            throw DatabaseError.sqlite(msg)
        }
    }

    public enum Value {
        case int(Int64), double(Double), text(String), null
    }

    @discardableResult
    private func run(_ sql: String, _ params: [Value] = [], row: ((OpaquePointer) -> Void)? = nil) throws -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row?(stmt!) }
            else if rc == SQLITE_DONE { break }
            else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, i))
    }

    private func opt(_ s: String?) -> Value { s.map { .text($0) } ?? .null }

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    // MARK: - Projects

    public func projects() throws -> [Project] {
        var out: [Project] = []
        try run("SELECT id, name, color, bg_billable, cc_billable, archived, keywords FROM projects ORDER BY archived, name COLLATE NOCASE") { s in
            let keywords = (try? JSONDecoder().decode([String].self, from: Data((self.text(s, 6) ?? "[]").utf8))) ?? []
            out.append(Project(id: sqlite3_column_int64(s, 0), name: self.text(s, 1) ?? "", colorHex: self.text(s, 2) ?? "#888888",
                               backgroundBillable: sqlite3_column_int(s, 3) != 0, claudeBillable: sqlite3_column_int(s, 4) != 0,
                               archived: sqlite3_column_int(s, 5) != 0, keywords: keywords))
        }
        return out
    }

    @discardableResult
    public func save(_ p: Project) throws -> Int64 {
        let keywords = String(decoding: (try? JSONEncoder().encode(p.keywords)) ?? Data("[]".utf8), as: UTF8.self)
        let params: [Value] = [.text(p.name), .text(p.colorHex), .int(p.backgroundBillable ? 1 : 0),
                               .int(p.claudeBillable ? 1 : 0), .int(p.archived ? 1 : 0), .text(keywords)]
        if p.id == 0 {
            return try run("INSERT INTO projects(name, color, bg_billable, cc_billable, archived, keywords) VALUES (?,?,?,?,?,?)", params)
        }
        try run("UPDATE projects SET name=?, color=?, bg_billable=?, cc_billable=?, archived=?, keywords=? WHERE id=?", params + [.int(p.id)])
        return p.id
    }

    public func deleteProject(_ id: Int64) throws {
        try transaction {
            try run("DELETE FROM assignments WHERE project_id=?", [.int(id)])
            try run("DELETE FROM projects WHERE id=?", [.int(id)])
        }
    }

    // MARK: - Rules

    public func rules() throws -> [Rule] {
        var out: [Rule] = []
        try run("SELECT id, project_id, conditions, priority FROM rules ORDER BY priority, id") { s in
            let conds = (try? JSONDecoder().decode([RuleCondition].self, from: Data((self.text(s, 2) ?? "[]").utf8))) ?? []
            out.append(Rule(id: sqlite3_column_int64(s, 0), projectId: sqlite3_column_int64(s, 1),
                            conditions: conds, priority: Int(sqlite3_column_int(s, 3))))
        }
        return out
    }

    @discardableResult
    public func save(_ r: Rule) throws -> Int64 {
        let json = String(decoding: try JSONEncoder().encode(r.conditions), as: UTF8.self)
        if r.id == 0 {
            return try run("INSERT INTO rules(project_id, conditions, priority) VALUES (?,?,?)",
                           [.int(r.projectId), .text(json), .int(Int64(r.priority))])
        }
        try run("UPDATE rules SET project_id=?, conditions=?, priority=? WHERE id=?",
                [.int(r.projectId), .text(json), .int(Int64(r.priority)), .int(r.id)])
        return r.id
    }

    public func deleteRule(_ id: Int64) throws { try run("DELETE FROM rules WHERE id=?", [.int(id)]) }

    // MARK: - Manual assignments

    public func assignments(day: String) throws -> [String: Int64] {
        var out: [String: Int64] = [:]
        try run("SELECT segment_key, project_id FROM assignments WHERE day=?", [.text(day)]) { s in
            out[self.text(s, 0) ?? ""] = sqlite3_column_int64(s, 1)
        }
        return out
    }

    /// `projectId == nil` removes the manual assignment (rules apply again).
    public func assign(_ keys: [String], day: String, projectId: Int64?) throws {
        try transaction {
            for k in keys {
                if let projectId {
                    try run("INSERT INTO assignments(segment_key, day, project_id) VALUES (?,?,?) ON CONFLICT(segment_key) DO UPDATE SET project_id=excluded.project_id",
                            [.text(k), .text(day), .int(projectId)])
                } else {
                    try run("DELETE FROM assignments WHERE segment_key=?", [.text(k)])
                }
            }
        }
    }

    /// Manually assigned recorded snippets (with project) since a date – input for rule suggestions.
    public func manualSamples(since: Date) throws -> [(event: RecordedEvent, projectId: Int64, day: String)] {
        var out: [(RecordedEvent, Int64, String)] = []
        try run("""
            SELECT f.id, f.start, f.end, f.app, f.bundle_id, f.title, f.url, f.page_title, a.project_id, a.day
            FROM assignments a JOIN foreground_events f ON a.segment_key = 'e' || f.id
            WHERE f.start >= ? AND a.project_id != 0
            """, [.double(since.timeIntervalSince1970)]) { s in
            let e = RecordedEvent(id: sqlite3_column_int64(s, 0),
                                  span: TimeSpan(Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                                 Date(timeIntervalSince1970: sqlite3_column_double(s, 2))),
                                  app: self.text(s, 3) ?? "", bundleId: self.text(s, 4) ?? "", title: self.text(s, 5) ?? "",
                                  url: self.text(s, 6), pageTitle: self.text(s, 7))
            out.append((e, sqlite3_column_int64(s, 8), self.text(s, 9) ?? ""))
        }
        return out
    }

    public func dismissedSuggestions() -> Set<String> {
        var raw = "[]"
        _ = try? run("SELECT value FROM settings WHERE key='dismissedSuggestions'") { s in raw = self.text(s, 0) ?? "[]" }
        return Set((try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? [])
    }

    public func dismissSuggestion(_ id: String) throws {
        var all = dismissedSuggestions()
        all.insert(id)
        let json = String(decoding: try JSONEncoder().encode(all.sorted()), as: UTF8.self)
        try run("INSERT INTO settings(key, value) VALUES ('dismissedSuggestions', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(json)])
    }

    // MARK: - Background tasks

    public func backgroundTasks(overlapping span: TimeSpan) throws -> [BackgroundEntry] {
        var out: [BackgroundEntry] = []
        try run("SELECT id, project_id, start, end, note FROM background_tasks WHERE start < ? AND end > ? ORDER BY start",
                [.double(span.end.timeIntervalSince1970), .double(span.start.timeIntervalSince1970)]) { s in
            out.append(BackgroundEntry(id: sqlite3_column_int64(s, 0), projectId: sqlite3_column_int64(s, 1),
                                      span: TimeSpan(Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                                                     Date(timeIntervalSince1970: sqlite3_column_double(s, 3))),
                                      note: self.text(s, 4) ?? ""))
        }
        return out
    }

    @discardableResult
    public func save(_ t: BackgroundEntry) throws -> Int64 {
        let params: [Value] = [.int(t.projectId), .double(t.span.start.timeIntervalSince1970),
                               .double(t.span.end.timeIntervalSince1970), .text(t.note)]
        if t.id == 0 {
            return try run("INSERT INTO background_tasks(project_id, start, end, note) VALUES (?,?,?,?)", params)
        }
        try run("UPDATE background_tasks SET project_id=?, start=?, end=?, note=? WHERE id=?", params + [.int(t.id)])
        return t.id
    }

    public func deleteBackgroundTask(_ id: Int64) throws { try run("DELETE FROM background_tasks WHERE id=?", [.int(id)]) }

    // MARK: - Claude Code events

    public func insert(_ e: ClaudeEvent) throws {
        try run("""
            INSERT OR IGNORE INTO claude_events(uuid, session_id, event, ts, cwd, notification_type, source, reason, agent_id, session_title)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [.text(e.uuid), .text(e.sessionId), .text(e.event), .double(e.ts.timeIntervalSince1970), .text(e.cwd),
                  opt(e.notificationType), opt(e.source), opt(e.reason), opt(e.agentId), opt(e.sessionTitle)])
    }

    /// All events of sessions that were active in the span (including their earlier events, for context).
    public func claudeEvents(around span: TimeSpan) throws -> [ClaudeEvent] {
        var out: [ClaudeEvent] = []
        let lookback = span.start.addingTimeInterval(-24 * 3600).timeIntervalSince1970
        try run("""
            SELECT uuid, session_id, event, ts, cwd, notification_type, source, reason, agent_id, session_title
            FROM claude_events WHERE ts >= ? AND ts < ? ORDER BY ts
            """, [.double(lookback), .double(span.end.timeIntervalSince1970)]) { s in
            out.append(ClaudeEvent(uuid: self.text(s, 0) ?? "", sessionId: self.text(s, 1) ?? "", event: self.text(s, 2) ?? "",
                                   ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)), cwd: self.text(s, 4) ?? "",
                                   notificationType: self.text(s, 5), source: self.text(s, 6), reason: self.text(s, 7),
                                   agentId: self.text(s, 8), sessionTitle: self.text(s, 9)))
        }
        return out
    }

    public struct FolderUsage: Hashable, Sendable {
        public var cwd: String
        public var lastSeen: Date
        public var sessions: Int
    }

    /// Working folders seen in Claude Code events since `since`.
    public func claudeFolders(since: Date) throws -> [FolderUsage] {
        var out: [FolderUsage] = []
        try run("""
            SELECT cwd, MAX(ts), COUNT(DISTINCT session_id) FROM claude_events
            WHERE ts >= ? GROUP BY cwd ORDER BY MAX(ts) DESC
            """, [.double(since.timeIntervalSince1970)]) { s in
            out.append(FolderUsage(cwd: self.text(s, 0) ?? "", lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                   sessions: Int(sqlite3_column_int64(s, 2))))
        }
        return out
    }

    public func lastClaudeEvent() throws -> ClaudeEvent? {
        try claudeEvents(around: TimeSpan(Date(), Date().addingTimeInterval(1))).last
    }

    public func claudeEventCount() throws -> Int {
        var n = 0
        try run("SELECT COUNT(*) FROM claude_events") { s in n = Int(sqlite3_column_int64(s, 0)) }
        return n
    }

    // MARK: - Folder mappings

    public func folderMappings() throws -> [FolderMapping] {
        var out: [FolderMapping] = []
        try run("SELECT id, path, project_id FROM folder_mappings ORDER BY path") { s in
            out.append(FolderMapping(id: sqlite3_column_int64(s, 0), path: self.text(s, 1) ?? "", projectId: sqlite3_column_int64(s, 2)))
        }
        return out
    }

    public func save(_ m: FolderMapping) throws {
        try run("INSERT INTO folder_mappings(path, project_id) VALUES (?,?) ON CONFLICT(path) DO UPDATE SET project_id=excluded.project_id",
                [.text(m.path), .int(m.projectId)])
    }

    public func deleteFolderMapping(_ id: Int64) throws { try run("DELETE FROM folder_mappings WHERE id=?", [.int(id)]) }

    // MARK: - Recorded foreground activity

    @discardableResult
    public func insertRecorded(_ e: RecordedEvent) throws -> Int64 {
        try run("INSERT INTO foreground_events(start, end, app, bundle_id, title, url, page_title) VALUES (?,?,?,?,?,?,?)",
                [.double(e.span.start.timeIntervalSince1970), .double(e.span.end.timeIntervalSince1970), .text(e.app),
                 .text(e.bundleId), .text(e.title), opt(e.url), opt(e.pageTitle)])
    }

    public func extendRecorded(id: Int64, to end: Date) throws {
        try run("UPDATE foreground_events SET end=? WHERE id=?", [.double(end.timeIntervalSince1970), .int(id)])
    }

    public func recorded(overlapping span: TimeSpan) throws -> [RecordedEvent] {
        var out: [RecordedEvent] = []
        try run("""
            SELECT id, start, end, app, bundle_id, title, url, page_title FROM foreground_events
            WHERE start < ? AND end > ? ORDER BY start
            """, [.double(span.end.timeIntervalSince1970), .double(span.start.timeIntervalSince1970)]) { s in
            out.append(RecordedEvent(id: sqlite3_column_int64(s, 0),
                                     span: TimeSpan(Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                                    Date(timeIntervalSince1970: sqlite3_column_double(s, 2))),
                                     app: self.text(s, 3) ?? "", bundleId: self.text(s, 4) ?? "", title: self.text(s, 5) ?? "",
                                     url: self.text(s, 6), pageTitle: self.text(s, 7)))
        }
        return out
    }

    // MARK: - Settings

    public func loadSettings() -> AppSettings {
        var s = AppSettings()
        var values: [String: String] = [:]
        _ = try? run("SELECT key, value FROM settings") { st in values[self.text(st, 0) ?? ""] = self.text(st, 1) }
        if let v = values["noiseThreshold"].flatMap(Double.init) { s.noiseThreshold = v }
        if let v = values["blockGap"].flatMap(Double.init) { s.blockGap = v }
        if let v = values["claudeStaleAfter"].flatMap(Double.init) { s.claudeStaleAfter = v }
        if let v = values["idleThreshold"].flatMap(Double.init) { s.idleThreshold = v }
        if let v = values["terminalApps"] { s.terminalApps = v.split(separator: "\n").map(String.init) }
        return s
    }

    public func save(_ s: AppSettings) throws {
        let values = [
            "noiseThreshold": String(s.noiseThreshold), "blockGap": String(s.blockGap),
            "claudeStaleAfter": String(s.claudeStaleAfter), "idleThreshold": String(s.idleThreshold),
            "terminalApps": s.terminalApps.joined(separator: "\n"),
        ]
        try transaction {
            for (k, v) in values {
                try run("INSERT INTO settings(key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(k), .text(v)])
            }
        }
    }
}
