import Foundation
import SwiftUI
import StechuhrCore

@MainActor
final class AppModel: ObservableObject {
    static weak var shared: AppModel?
    let db: Database

    @Published var settings: AppSettings
    @Published var projects: [Project] = []
    @Published var rules: [Rule] = []
    @Published var folders: [FolderMapping] = []
    @Published var day: Date = Calendar.current.startOfDay(for: Date())
    @Published private(set) var report: DayReport?
    /// Without Accessibility permission only app names are recorded, no window titles.
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published var hookServerError: String?
    @Published private(set) var lastHookEvent: Date?
    /// Selected foreground snippets (shared by timeline and activity list).
    @Published var selection: Set<String> = []
    @Published var colorByProject = true
    @Published var page: Page? = .day
    /// Rules proposed from repeated manual assignments.
    @Published private(set) var suggestions: [RuleSuggestion] = []
    /// Projects proposed from folders (e.g. git repos in ~/repos).
    @Published private(set) var projectSuggestions: [ProjectSuggestion] = []

    private var recorder: ActivityRecorder?
    private var hookServer: HookServer?
    private var timer: Timer?

    init() {
        do {
            db = try Database()
        } catch {
            fatalError("Stechuhr: \(error)")
        }
        settings = db.loadSettings()
        reloadConfig()
        AppModel.shared = self
        installHookHelper()
        HookInbox.drain(into: db)
        startHookServer()
        lastHookEvent = (try? db.lastClaudeEvent())?.ts
        startRecorder()
        refreshSuggestions()
        refreshProjectSuggestions()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        recompute()
    }

    var dayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }

    var daySpan: TimeSpan {
        TimeSpan(day, Calendar.current.date(byAdding: .day, value: 1, to: day)!)
    }

    var isToday: Bool { Calendar.current.isDateInToday(day) }

    func project(_ id: Int64?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    var activeProjects: [Project] { projects.filter { !$0.archived } }

    /// The report for today, independent of the day shown in the window (for the menu bar).
    var todayReport: DayReport? { isToday ? report : nil }

    var workingClaudeSessions: [EffectiveClaudeSpan] {
        guard isToday, let r = report else { return [] }
        var seen = Set<String>()
        return r.claudeSpans.filter { $0.isOpen && seen.insert($0.sessionId).inserted }
    }

    // MARK: - Loading

    private func tick() {
        HookInbox.drain(into: db)
        accessibilityGranted = Permissions.accessibilityGranted
        if isToday { recompute() }
    }

    private func startRecorder() {
        do {
            let r = try ActivityRecorder()
            r.idleThreshold = settings.idleThreshold
            r.start()
            recorder = r
        } catch {
            NSLog("Stechuhr: Aufzeichnung konnte nicht starten: \(error)")
        }
        if !accessibilityGranted { Permissions.requestAccessibility() }
    }

    /// Closes the currently open foreground record, e.g. before quitting.
    func flushRecorder() { recorder?.flush() }

    func reloadConfig() {
        projects = (try? db.projects()) ?? []
        rules = (try? db.rules()) ?? []
        folders = (try? db.folderMappings()) ?? []
    }

    func setDay(_ d: Date) {
        day = Calendar.current.startOfDay(for: d)
        selection = []
        recompute()
    }

    func recompute() {
        let recorded = (try? db.recorded(overlapping: daySpan)) ?? []
        let segments = Segmenter.segments(from: recorded, day: daySpan, noiseThreshold: settings.noiseThreshold)
        report = DayReport.build(
            day: daySpan, segments: segments,
            assignments: (try? db.assignments(day: dayKey)) ?? [:],
            rules: rules, projects: projects,
            manualTasks: (try? db.backgroundTasks(overlapping: daySpan)) ?? [],
            claudeEvents: (try? db.claudeEvents(around: daySpan)) ?? [],
            folders: folders, settings: settings, now: Date(),
            entries: (try? db.timeEntries(overlapping: daySpan)) ?? [])
        let valid = Set(report?.segments.map(\.id) ?? [])
        selection = selection.filter(valid.contains)
    }

    // MARK: - Hooks

    private func startHookServer() {
        let server = HookServer(token: HookToken.loadOrCreate()) { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        do {
            try server.start()
            hookServer = server
        } catch {
            hookServerError = "Empfang für Claude-Code-Ereignisse konnte nicht starten (Port \(StechuhrPaths.hookPort)): \(error.localizedDescription)"
        }
    }

    private func receive(_ event: ClaudeEvent) {
        try? db.insert(event)
        lastHookEvent = event.ts
        if isToday { recompute() }
    }

    /// Copies the bundled `stechuhr-hook` helper to a stable location that the Claude Code hooks point to.
    private func installHookHelper() {
        let candidates = [
            Bundle.main.url(forResource: "stechuhr-hook", withExtension: nil),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("stechuhr-hook"),
        ].compactMap { $0 }
        let fm = FileManager.default
        guard let source = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { return }
        let target = StechuhrPaths.hookBinary
        if let a = try? Data(contentsOf: source), let b = try? Data(contentsOf: target), a == b { return }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = target.appendingPathExtension("new")
        try? fm.removeItem(at: tmp)
        guard (try? fm.copyItem(at: source, to: tmp)) != nil else { return }
        _ = try? fm.replaceItemAt(target, withItemAt: tmp)
        if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: tmp, to: target) }
    }

    var hookHelperInstalled: Bool { FileManager.default.isExecutableFile(atPath: StechuhrPaths.hookBinary.path) }
    var hookServerRunning: Bool { hookServer != nil }

    // MARK: - Assignments

    func assign(_ keys: Set<String>, to projectId: Int64?) {
        guard !keys.isEmpty else { return }
        try? db.assign(Array(keys), day: dayKey, projectId: projectId)
        recompute()
        refreshSuggestions()
    }

    // MARK: - Learning from manual assignments

    func refreshSuggestions() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let rows = (try? db.manualSamples(since: Date().addingTimeInterval(-30 * 86400))) ?? []
        var samples: [RuleSuggester.Sample] = []
        for row in rows {
            guard let seg = Segmenter.segments(from: [row.event], day: row.event.span, noiseThreshold: 0).first else { continue }
            samples.append(RuleSuggester.Sample(segment: seg, projectId: row.projectId, day: row.day))
        }
        let active = Set(activeProjects.map(\.id))
        suggestions = RuleSuggester.suggest(from: samples, rules: rules, dismissed: db.dismissedSuggestions())
            .filter { active.contains($0.projectId) }
    }

    func accept(_ s: RuleSuggestion) {
        addRule(s.conditions, projectId: s.projectId)
    }

    func dismiss(_ s: RuleSuggestion) {
        try? db.dismissSuggestion(s.id)
        refreshSuggestions()
    }

    var keywordMatcher: KeywordMatcher { KeywordMatcher(projects: projects) }

    func resolve(folder cwd: String) -> FolderResolution {
        FolderResolution.resolve(cwd, folders: folders, keywords: keywordMatcher)
    }

    /// Short German explanation of why a snippet has its project.
    func explain(_ s: AttributedSegment) -> String {
        switch s.source {
        case .manual: return s.projectId == nil ? "von Hand: kein Projekt" : "von Hand zugewiesen"
        case .rule: return "per Regel"
        case .keyword(let term): return "per Stichwort „\(term)“"
        case .folder: return "per Ordner (Dateipfad)"
        case .claudeSession: return "per Claude-Code-Session"
        case .context: return "aus dem Umfeld (Werkzeug-App)"
        case .entry: return "per Zeiteintrag"
        case .ambiguous(let ids): return "mehrdeutig: " + ids.compactMap { project($0)?.name }.joined(separator: ", ")
        case .absorbedNoise: return "kurzer Wechsel, eingerechnet"
        case .ignoredNoise: return "Rauschen, ignoriert"
        case .none: return "nicht zugeordnet"
        }
    }

    func addRule(_ conditions: [RuleCondition], projectId: Int64) {
        _ = try? db.save(Rule(projectId: projectId, conditions: conditions))
        rules = (try? db.rules()) ?? []
        recompute()
        refreshSuggestions()
    }

    func save(_ rule: Rule) {
        _ = try? db.save(rule)
        rules = (try? db.rules()) ?? []
        recompute()
    }

    func deleteRule(_ id: Int64) {
        try? db.deleteRule(id)
        rules = (try? db.rules()) ?? []
        recompute()
        refreshSuggestions()
    }

    // MARK: - Projects

    @discardableResult
    func save(_ project: Project) -> Int64 {
        let id = (try? db.save(project)) ?? 0
        reloadConfig()
        recompute()
        return id
    }

    func deleteProject(_ id: Int64) {
        try? db.deleteProject(id)
        reloadConfig()
        recompute()
    }

    @discardableResult
    func newProject(named name: String) -> Int64 {
        let palette = ["#E5484D", "#F76B15", "#FFC53D", "#46A758", "#12A594", "#0090FF", "#3E63DD", "#8E4EC6", "#D6409F", "#978365"]
        return save(Project(name: name, colorHex: palette[projects.count % palette.count]))
    }

    // MARK: - Time entries

    func save(_ entry: TimeEntry) {
        _ = try? db.save(entry)
        recompute()
    }

    func deleteTimeEntry(_ id: Int64) {
        try? db.deleteTimeEntry(id)
        recompute()
    }

    func accept(_ block: BlockSuggestion, projectId: Int64? = nil) {
        guard let pid = projectId ?? block.projectId else { return }
        save(TimeEntry(projectId: pid, span: block.span, title: block.title))
    }

    /// Confirms all suggestions that already have a project.
    func acceptAllBlocks() {
        for b in report?.suggestions ?? [] where b.projectId != nil {
            _ = try? db.save(TimeEntry(projectId: b.projectId!, span: b.span, title: b.title))
        }
        recompute()
    }

    /// A time entry spanning the selected snippets, with the most frequent project preselected.
    func entryFromSelection() -> TimeEntry? {
        let sel = report?.segments.filter { selection.contains($0.id) } ?? []
        guard let start = sel.map(\.segment.span.start).min(), let end = sel.map(\.segment.span.end).max() else { return nil }
        var weight: [Int64: TimeInterval] = [:]
        for s in sel { if let p = s.projectId { weight[p, default: 0] += s.segment.duration } }
        let pid = weight.max { $0.value < $1.value }?.key ?? activeProjects.first?.id ?? 0
        return TimeEntry(projectId: pid, span: TimeSpan(start, end))
    }

    // MARK: - Project suggestions

    func refreshProjectSuggestions() {
        let roots = settings.projectRoots
        let claudeFolders = recentClaudeFolders().map(\.cwd)
        let projects = projects, folders = folders
        Task.detached {
            let candidates = ProjectSuggester.scan(roots: roots, claudeFolders: claudeFolders)
            let result = ProjectSuggester.suggest(candidates, projects: projects, folders: folders)
            await MainActor.run { self.projectSuggestions = result }
        }
    }

    func create(_ suggestions: [ProjectSuggestion]) {
        for s in suggestions {
            let id = newProject(named: s.name)
            if !s.keywords.isEmpty, var p = project(id) {
                p.keywords = s.keywords
                _ = try? db.save(p)
            }
            for f in s.folders { try? db.save(FolderMapping(path: f, projectId: id)) }
        }
        reloadConfig()
        recompute()
        refreshProjectSuggestions()
    }

    /// Finder drop: one folder → project named after it; several → one project named after their common parent.
    func createProject(fromFolders urls: [URL]) {
        let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !dirs.isEmpty else { return }
        let name: String
        if dirs.count == 1 {
            name = dirs[0].lastPathComponent
        } else {
            let parents = Set(dirs.map { $0.deletingLastPathComponent().path })
            name = parents.count == 1 ? URL(fileURLWithPath: parents.first!).lastPathComponent : dirs[0].lastPathComponent
        }
        create([ProjectSuggestion(name: name, folders: dirs.map(\.path), keywords: [], reason: "Finder")])
    }

    // MARK: - Background tasks

    func save(_ task: BackgroundEntry) {
        _ = try? db.save(task)
        recompute()
    }

    func deleteBackgroundTask(_ id: Int64) {
        try? db.deleteBackgroundTask(id)
        recompute()
    }

    // MARK: - Folders

    func map(folder: String, to projectId: Int64) {
        try? db.save(FolderMapping(path: folder, projectId: projectId))
        folders = (try? db.folderMappings()) ?? []
        recompute()
        refreshProjectSuggestions()
    }

    func deleteFolderMapping(_ id: Int64) {
        try? db.deleteFolderMapping(id)
        folders = (try? db.folderMappings()) ?? []
        recompute()
    }

    func recentClaudeFolders() -> [Database.FolderUsage] {
        (try? db.claudeFolders(since: Date().addingTimeInterval(-60 * 24 * 3600))) ?? []
    }

    // MARK: - Settings

    func save(_ s: AppSettings) {
        settings = s
        try? db.save(s)
        recorder?.idleThreshold = s.idleThreshold
        recompute()
        refreshProjectSuggestions()
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func duration(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 60 { return "\(m) min" }
        return String(format: "%d:%02d h", m / 60, m % 60)
    }

    static func time(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    /// Stable color per app name for "color by app" mode.
    static func forName(_ name: String) -> Color {
        var h: UInt64 = 5381
        for b in name.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.45, brightness: 0.8)
    }
}
