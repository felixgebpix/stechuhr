import SwiftUI
import StechuhrCore

/// Activities grouped by content: App → window title, browser → domain → page title.
struct ActivityNode: Identifiable, Hashable {
    enum Level: Hashable { case app, title, domain, page }

    var id: String
    var level: Level
    var title: String
    var app: String
    var domain: String?
    var duration: TimeInterval = 0
    var keys: [String] = []
    var projectIds: Set<Int64?> = []
    var children: [ActivityNode]?

    var icon: String {
        switch level {
        case .app: "app.dashed"
        case .title: "macwindow"
        case .domain: "globe"
        case .page: "doc.richtext"
        }
    }

    /// Rule conditions that describe this group (optionally narrowed by the current search).
    func ruleConditions(search: String) -> [RuleCondition] {
        let s = search.trimmingCharacters(in: .whitespaces)
        switch level {
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
        }
    }

    static func build(_ segments: [AttributedSegment]) -> [ActivityNode] {
        var apps: [String: ActivityNode] = [:]
        var titles: [String: ActivityNode] = [:]
        var domains: [String: ActivityNode] = [:]
        var pages: [String: ActivityNode] = [:]

        func add(_ node: inout ActivityNode, _ s: AttributedSegment) {
            node.duration += s.segment.duration
            node.keys.append(s.id)
            node.projectIds.insert(s.projectId)
        }

        for s in segments {
            let seg = s.segment
            let appId = "a\u{1F}\(seg.app)"
            if apps[appId] == nil { apps[appId] = ActivityNode(id: appId, level: .app, title: seg.app, app: seg.app) }
            add(&apps[appId]!, s)
            if seg.isWeb, let domain = seg.domain {
                let dId = "\(appId)\u{1F}d\u{1F}\(domain)"
                if domains[dId] == nil { domains[dId] = ActivityNode(id: dId, level: .domain, title: domain, app: seg.app, domain: domain) }
                add(&domains[dId]!, s)
                let pTitle = seg.displayTitle.isEmpty ? (seg.url ?? "") : seg.displayTitle
                let pId = "\(dId)\u{1F}\(pTitle)"
                if pages[pId] == nil { pages[pId] = ActivityNode(id: pId, level: .page, title: pTitle, app: seg.app, domain: domain) }
                add(&pages[pId]!, s)
            } else {
                let tTitle = seg.title.isEmpty ? "(ohne Titel)" : seg.title
                let tId = "\(appId)\u{1F}t\u{1F}\(tTitle)"
                if titles[tId] == nil { titles[tId] = ActivityNode(id: tId, level: .title, title: tTitle, app: seg.app) }
                add(&titles[tId]!, s)
            }
        }

        func parentId(_ id: String, dropping n: Int) -> String {
            id.components(separatedBy: "\u{1F}").dropLast(n).joined(separator: "\u{1F}")
        }
        let byDuration: (ActivityNode, ActivityNode) -> Bool = { $0.duration > $1.duration }
        var domainNodes = domains
        for id in domainNodes.keys {
            domainNodes[id]!.children = pages.values.filter { parentId($0.id, dropping: 1) == id }.sorted(by: byDuration)
        }
        var result: [ActivityNode] = []
        for (id, var a) in apps {
            let kids = titles.values.filter { parentId($0.id, dropping: 2) == id }
                + domainNodes.values.filter { parentId($0.id, dropping: 2) == id }
            a.children = kids.isEmpty ? nil : kids.sorted(by: byDuration)
            result.append(a)
        }
        return result.sorted(by: byDuration)
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

    private var filtered: [AttributedSegment] {
        let s = search.trimmingCharacters(in: .whitespaces)
        return report.segments.filter { a in
            if !showNoise && a.source == .ignoredNoise { return false }
            if onlyUnassigned && a.projectId != nil { return false }
            guard !s.isEmpty else { return true }
            let seg = a.segment
            return [seg.app, seg.title, seg.domain ?? "", seg.url ?? "", seg.pageTitle ?? ""].contains { $0.localizedCaseInsensitiveContains(s) }
        }
    }

    var body: some View {
        let segments = filtered
        let nodes = ActivityNode.build(segments)
        let index = Self.index(nodes)
        VStack(spacing: 0) {
            HStack {
                TextField("Filtern, z. B. „Acme“", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
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
                    Menu("Zuweisen und Regel erstellen") {
                        assignMenu(keys: keys, ruleConditions: selected.map { $0.ruleConditions(search: search) })
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
            ProjectBadges(ids: node.projectIds)
            Text(Fmt.duration(node.duration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .help(node.title)
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
