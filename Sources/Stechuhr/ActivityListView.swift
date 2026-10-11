import SwiftUI
import StechuhrCore

/// Activities grouped by content: [project →] app → window title, browser → domain → page, document app → folder → file.
struct ActivityNode: Identifiable, Hashable {
    enum Level: Hashable { case project, app, title, domain, page, folder, file }

    var id: String
    var level: Level
    var title: String
    var app: String
    var domain: String?
    /// Folder or file path for .folder / .file
    var path: String?
    var duration: TimeInterval = 0
    var keys: [String] = []
    var projectIds: Set<Int64?> = []
    var ambiguous = false
    var keywords: Set<String> = []
    var children: [ActivityNode]?

    var icon: String {
        switch level {
        case .project: "folder.fill"
        case .app: "app.dashed"
        case .title: "macwindow"
        case .domain: "globe"
        case .page: "doc.richtext"
        case .folder: "folder"
        case .file: "doc"
        }
    }

    /// Rule conditions that describe this group (optionally narrowed by the current search).
    func ruleConditions(search: String) -> [RuleCondition] {
        let s = search.trimmingCharacters(in: .whitespaces)
        switch level {
        case .project:
            return []
        case .app:
            var c = [RuleCondition(.app, .equals, app)]
            if !s.isEmpty, !app.localizedCaseInsensitiveContains(s) { c.append(RuleCondition(.title, .contains, s)) }
            return c
        case .title:
            return [RuleCondition(.app, .equals, app), RuleCondition(.title, .equals, title)]
        case .domain:
            var c = [RuleCondition(.domain, .equals, domain ?? title)]
            if !s.isEmpty, !(domain ?? "").localizedCaseInsensitiveContains(s) { c.append(RuleCondition(.title, .contains, s)) }
            return c
        case .page:
            return [RuleCondition(.domain, .equals, domain ?? ""), RuleCondition(.title, .equals, title)]
        case .folder:
            return [RuleCondition(.path, .prefix, Self.tilde(path ?? ""))]
        case .file:
            return [RuleCondition(.path, .equals, path ?? "")]
        }
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Builds the tree. `projectName` is only used when grouping by project.
    static func build(_ segments: [AttributedSegment], byProject: Bool, projectName: (Int64?) -> String) -> [ActivityNode] {
        final class Box {
            var node: ActivityNode
            var children: [String: Box] = [:]
            var order: [String] = []
            init(_ node: ActivityNode) { self.node = node }
        }
        let root = Box(ActivityNode(id: "", level: .app, title: "", app: ""))

        for s in segments {
            let seg = s.segment
            var path: [(String, ActivityNode)] = []
            func add(_ comp: String, _ level: Level, _ title: String, domain: String? = nil, path p: String? = nil) {
                let id = (path.last?.1.id ?? "") + "\u{1F}" + comp
                path.append((comp, ActivityNode(id: id, level: level, title: title, app: seg.app, domain: domain, path: p)))
            }
            if byProject { add("p\(s.projectId ?? -1)", .project, projectName(s.projectId)) }
            add("a" + seg.app, .app, seg.app)
            if seg.isWeb, let domain = seg.domain {
                add("d" + domain, .domain, domain, domain: domain)
                let t = seg.displayTitle.isEmpty ? (seg.url ?? "") : seg.displayTitle
                add("t" + t, .page, t, domain: domain)
            } else if let file = seg.path {
                let folder = (file as NSString).deletingLastPathComponent
                add("f" + folder, .folder, tilde(folder), path: folder)
                add("n" + file, .file, (file as NSString).lastPathComponent, path: file)
            } else {
                let t = seg.title.isEmpty ? "(ohne Titel)" : seg.title
                add("t" + t, .title, t)
            }

            var box = root
            for (comp, template) in path {
                if box.children[comp] == nil {
                    box.children[comp] = Box(template)
                    box.order.append(comp)
                }
                box = box.children[comp]!
                box.node.duration += seg.duration
                box.node.keys.append(s.id)
                box.node.projectIds.insert(s.projectId)
                if case .ambiguous = s.source { box.node.ambiguous = true }
                if case .keyword(let term) = s.source { box.node.keywords.insert(term) }
            }
        }

        func finish(_ box: Box) -> [ActivityNode] {
            box.order.compactMap { box.children[$0] }.map { child -> ActivityNode in
                var n = child.node
                let kids = finish(child)
                n.children = kids.isEmpty ? nil : kids
                return n
            }
            .sorted { $0.duration > $1.duration }
        }
        return finish(root)
    }
}

struct ActivityListView: View {
    @EnvironmentObject var model: AppModel
    let report: DayReport
    var onNewProject: (Set<String>, [[RuleCondition]]?) -> Void

    @State private var search = ""
    @State private var onlyUnassigned = false
    @State private var showNoise = false
    @State private var listSelection: Set<String> = []
    @AppStorage("activityByProject") private var byProject = true

    private var filtered: [AttributedSegment] {
        let s = search.trimmingCharacters(in: .whitespaces)
        return report.segments.filter { a in
            if !showNoise && a.source == .ignoredNoise { return false }
            if onlyUnassigned && a.projectId != nil { return false }
            guard !s.isEmpty else { return true }
            let seg = a.segment
            return [seg.app, seg.title, seg.domain ?? "", seg.url ?? "", seg.pageTitle ?? "", seg.path ?? ""].contains { $0.localizedCaseInsensitiveContains(s) }
        }
    }

    var body: some View {
        let segments = filtered
        let nodes = ActivityNode.build(segments, byProject: byProject) { id in
            id == nil ? "Nicht zugeordnet" : (model.project(id)?.name ?? "–")
        }
        let index = Self.index(nodes)
        VStack(spacing: 0) {
            HStack {
                TextField("Filtern, z. B. „DFA“", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("", selection: $byProject) {
                    Text("Nach Projekt").tag(true)
                    Text("Nach App").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("Nur nicht zugeordnete", isOn: $onlyUnassigned).toggleStyle(.checkbox)
                Toggle("Rauschen zeigen", isOn: $showNoise).toggleStyle(.checkbox)
                Spacer()
                if !search.isEmpty {
                    let keys = Set(segments.map(\.id))
                    Menu("Alle \(segments.count) Treffer zuweisen") {
                        assignMenu(keys: keys, ruleConditions: nil)
                    }
                    .fixedSize()
                }
            }
            .padding(8)
            List(nodes, children: \.children, selection: $listSelection) { node in
                row(node)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let selected = ids.compactMap { index[$0] }
                let keys = Set(selected.flatMap(\.keys))
                if !keys.isEmpty {
                    Menu("Zuweisen an") { assignMenu(keys: keys, ruleConditions: nil) }
                    let conditions = selected.map { $0.ruleConditions(search: search) }.filter { !$0.isEmpty }
                    if !conditions.isEmpty {
                        Menu("Zuweisen und Regel erstellen") {
                            assignMenu(keys: keys, ruleConditions: conditions)
                        }
                    }
                    Divider()
                    Button("Kein Projekt") { model.assign(keys, to: Attribution.noProject) }
                    Button("Manuelle Zuordnung entfernen (Regeln gelten wieder)") { model.assign(keys, to: nil) }
                }
            }
            .onChange(of: listSelection) { _, ids in
                model.selection = Set(ids.compactMap { index[$0] }.flatMap(\.keys))
            }
        }
    }

    @ViewBuilder
    private func assignMenu(keys: Set<String>, ruleConditions: [[RuleCondition]]?) -> some View {
        ForEach(model.activeProjects) { p in
            Button {
                model.assign(keys, to: p.id)
                ruleConditions?.forEach { model.addRule($0, projectId: p.id) }
            } label: {
                Label(p.name, systemImage: "circle.fill")
            }
        }
        Divider()
        Button("Neues Projekt …") { onNewProject(keys, ruleConditions) }
    }

    private func row(_ node: ActivityNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.icon).foregroundStyle(.secondary).frame(width: 16)
            Text(node.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if node.ambiguous {
                Text("mehrdeutig").font(.caption2).foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().stroke(.orange.opacity(0.6)))
                    .help("Stichwörter mehrerer Projekte passen. Bitte von Hand zuweisen oder eine Regel anlegen.")
            }
            if node.level != .project { ProjectBadges(ids: node.projectIds) }
            Text(Fmt.duration(node.duration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .help(node.keywords.isEmpty ? node.title : "\(node.title)\nzugeordnet per Stichwort: \(node.keywords.sorted().joined(separator: ", "))")
    }

    static func index(_ nodes: [ActivityNode]) -> [String: ActivityNode] {
        var out: [String: ActivityNode] = [:]
        func walk(_ n: [ActivityNode]) {
            for x in n {
                out[x.id] = x
                walk(x.children ?? [])
            }
        }
        walk(nodes)
        return out
    }
}

struct ProjectBadges: View {
    @EnvironmentObject var model: AppModel
    let ids: Set<Int64?>

    var body: some View {
        let projects = ids.compactMap { model.project($0) }.sorted { $0.name < $1.name }
        HStack(spacing: 3) {
            ForEach(projects.prefix(3)) { p in
                Text(p.name)
                    .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(hex: p.colorHex).opacity(0.25), in: Capsule())
            }
            if projects.count > 3 { Text("+\(projects.count - 3)").font(.caption2) }
            if ids.contains(nil) {
                Text("offen").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().stroke(.secondary.opacity(0.5)))
            }
        }
    }
}
