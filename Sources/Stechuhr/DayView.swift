import SwiftUI
import StechuhrCore

struct DayView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var editingTask: BackgroundEntry?
    @State private var newProjectRequest: NewProjectRequest?
    @State private var editingEntry: TimeEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.accessibilityGranted {
                HStack {
                    Banner(text: "Stechuhr erfasst gerade nur App-Namen, keine Fenstertitel. Steht Stechuhr unter Bedienungshilfen schon auf „an“, gehört der Eintrag zu einer älteren Version: mit „–“ entfernen und Stechuhr neu hinzufügen (z. B. aus dem Finder hineinziehen).",
                           systemImage: "lock.shield")
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    Button("Einstellungen öffnen") { Permissions.openAccessibilitySettings() }.padding(.trailing, 8)
                }
                .background(Color.orange.opacity(0.15))
            }
            if !model.suggestions.isEmpty {
                HStack {
                    Banner(text: "Stechuhr hat \(model.suggestions.count) Regel-Vorschlag/-Vorschläge aus deinen Zuweisungen gelernt.",
                           systemImage: "lightbulb")
                    Button("Ansehen") { model.page = .rules }.padding(.trailing, 8)
                }
                .background(Color.orange.opacity(0.15))
            }
            if let err = model.hookServerError {
                Banner(text: err, systemImage: "bolt.horizontal.circle")
            }
            if let report = model.report {
                DayTimeline(report: report, onEditTask: { editingTask = $0 }, onEditEntry: { editingEntry = $0 },
                            onSuggestion: { s in
                                editingEntry = TimeEntry(projectId: s.projectId ?? model.activeProjects.first?.id ?? 0,
                                                         span: s.span, title: s.title)
                            })
                    .padding(.vertical, 8)
                Divider()
                selectionBar(report)
                Picker("", selection: $tab) {
                    Text("Aktivitäten").tag(0)
                    Text("Auswertung").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .padding(8)
                if tab == 0 {
                    ActivityListView(report: report) { keys, rules in
                        newProjectRequest = NewProjectRequest(keys: keys, rules: rules)
                    }
                } else {
                    DayStatsView(report: report)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $editingTask) { task in
            BackgroundEntrySheet(task: task)
        }
        .sheet(item: $newProjectRequest) { req in
            NewProjectSheet(request: req)
        }
        .sheet(item: $editingEntry) { entry in
            TimeEntrySheet(entry: entry)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.setDay(model.day.addingTimeInterval(-86400)) } label: { Image(systemName: "chevron.left") }
            DatePicker("", selection: Binding(get: { model.day }, set: { model.setDay($0) }), displayedComponents: .date)
                .labelsHidden().frame(width: 120)
            Button { model.setDay(model.day.addingTimeInterval(86400)) } label: { Image(systemName: "chevron.right") }
                .disabled(model.isToday)
            Button("Heute") { model.setDay(Date()) }.disabled(model.isToday)
            Text(model.day.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.headline).padding(.leading, 8)
            Spacer()
            if let n = model.report?.suggestions.filter({ $0.projectId != nil }).count, n > 0 {
                Button {
                    model.acceptAllBlocks()
                } label: {
                    Label("\(n) Vorschläge übernehmen", systemImage: "checkmark.seal")
                }
                .help("Alle gestrichelten Blöcke mit erkanntem Projekt als Zeiteinträge bestätigen")
            }
            Menu {
                Button("In Zwischenablage kopieren") { model.copyAIExport(for: model.day) }
                Button("Als Datei sichern …") { model.saveAIExport(for: model.day) }
            } label: {
                Label("Für KI exportieren", systemImage: "sparkles.rectangle.stack")
            }
            .fixedSize()
            .help("Den ganzen Tag als Text (Markdown) für ChatGPT, Claude & Co.: Projekte, Browser nach Domain und Seite, Apps, Claude-Code-Sessions und chronologischer Verlauf. URLs ohne Query-Parameter.")
            Toggle("Nach Projekt einfärben", isOn: $model.colorByProject).toggleStyle(.switch).controlSize(.small)
            Button {
                let start = model.isToday ? Date().addingTimeInterval(-3600) : model.day.addingTimeInterval(10 * 3600)
                editingTask = BackgroundEntry(projectId: model.activeProjects.first?.id ?? 0,
                                             span: TimeSpan(start, start.addingTimeInterval(3600)))
            } label: {
                Label("Hintergrundaufgabe", systemImage: "plus")
            }
            .disabled(model.activeProjects.isEmpty)
            .help(model.activeProjects.isEmpty ? "Lege zuerst ein Projekt an." : "Zeitraum markieren, in dem etwas für ein Projekt im Hintergrund lief")
            Button { model.recompute() } label: { Image(systemName: "arrow.clockwise") }
                .help("Neu laden")
        }
        .padding(10)
    }

    @ViewBuilder
    private func selectionBar(_ report: DayReport) -> some View {
        let selected = report.segments.filter { model.selection.contains($0.id) }
        if !selected.isEmpty {
            HStack {
                Text("\(selected.count) Schnipsel ausgewählt · \(Fmt.duration(selected.reduce(0) { $0 + $1.segment.duration }))")
                Spacer()
                Menu("Zuweisen an") {
                    ForEach(model.activeProjects) { p in
                        Button(p.name) { model.assign(model.selection, to: p.id) }
                    }
                    Divider()
                    Button("Neues Projekt …") { newProjectRequest = NewProjectRequest(keys: model.selection, rules: nil) }
                    Button("Kein Projekt") { model.assign(model.selection, to: Attribution.noProject) }
                    Button("Manuelle Zuordnung entfernen") { model.assign(model.selection, to: nil) }
                }
                .fixedSize()
                Button("Als Zeiteintrag …") { editingEntry = model.entryFromSelection() }
                Button("Auswahl aufheben") { model.selection = [] }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
        }
    }
}

struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .padding(8)
        .background(Color.orange.opacity(0.15))
    }
}

struct NewProjectRequest: Identifiable {
    let id = UUID()
    var keys: Set<String>
    var rules: [[RuleCondition]]?
}

struct NewProjectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let request: NewProjectRequest
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neues Projekt").font(.headline)
            TextField("Name", text: $name).frame(width: 280)
            if let rules = request.rules, !rules.isEmpty {
                Text("Es werden zusätzlich \(rules.count) Regel(n) angelegt.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Anlegen und zuweisen") {
                    let id = model.newProject(named: name.trimmingCharacters(in: .whitespaces))
                    model.assign(request.keys, to: id)
                    request.rules?.forEach { model.addRule($0, projectId: id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

struct TimeEntrySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var entry: TimeEntry

    init(entry: TimeEntry) { _entry = State(initialValue: entry) }

    var body: some View {
        Form {
            Text(entry.id == 0 ? "Zeiteintrag anlegen" : "Zeiteintrag bearbeiten").font(.headline)
            Picker("Projekt", selection: $entry.projectId) {
                ForEach(model.activeProjects) { p in Text(p.name).tag(p.id) }
            }
            DatePicker("Von", selection: $entry.span.start)
            DatePicker("Bis", selection: Binding(get: { entry.span.end }, set: { entry.span.end = max($0, entry.span.start) }))
            TextField("Titel", text: $entry.title, prompt: Text("optional"))
            Text("Dauer: \(Fmt.duration(entry.span.duration)). Kurze Wechsel zu Werkzeugen zählen mit. Schnipsel, die eindeutig zu einem anderen Projekt gehören, werden herausgerechnet.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if entry.id != 0 {
                    Button("Löschen", role: .destructive) {
                        model.deleteTimeEntry(entry.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(entry.id == 0 ? "Übernehmen" : "Speichern") {
                    model.save(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry.projectId == 0 || entry.span.duration <= 0)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct BackgroundEntrySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var task: BackgroundEntry

    init(task: BackgroundEntry) {
        _task = State(initialValue: task)
    }

    var body: some View {
        Form {
            Text(task.id == 0 ? "Hintergrundaufgabe markieren" : "Hintergrundaufgabe bearbeiten").font(.headline)
            Picker("Projekt", selection: $task.projectId) {
                ForEach(model.activeProjects) { p in Text(p.name).tag(p.id) }
            }
            DatePicker("Von", selection: $task.span.start)
            DatePicker("Bis", selection: Binding(get: { task.span.end }, set: { task.span.end = max($0, task.span.start) }))
            TextField("Notiz", text: $task.note, prompt: Text("z. B. Export läuft, Rendering …"))
            Text("Dauer: \(Fmt.duration(task.span.duration))").foregroundStyle(.secondary)
            HStack {
                if task.id != 0 {
                    Button("Löschen", role: .destructive) {
                        model.deleteBackgroundTask(task.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    model.save(task)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.projectId == 0 || task.span.duration <= 0)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Per project: foreground (me), background (manual + Claude Code), overlap, billable, fragmentation.
struct DayStatsView: View {
    @EnvironmentObject var model: AppModel
    let report: DayReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(report.stats) {
                TableColumn("Projekt") { s in
                    HStack(spacing: 6) {
                        Circle().fill(model.project(s.projectId).map { Color(hex: $0.colorHex) } ?? .gray).frame(width: 9, height: 9)
                        Text(model.project(s.projectId)?.name ?? "nicht zugeordnet")
                            .foregroundStyle(s.projectId == nil ? .secondary : .primary)
                    }
                }
                .width(min: 140, ideal: 180)
                TableColumn("Ich (Vordergrund)") { s in dur(s.foreground) }
                TableColumn("davon bestätigt") { s in
                    dur(s.confirmed).help("Durch Zeiteinträge bestätigter Teil der Vordergrundzeit")
                }
                TableColumn("Hintergrund manuell") { s in dur(s.manualBackground) }
                TableColumn("Claude Code") { s in
                    HStack(spacing: 4) {
                        dur(s.claude)
                        if s.claudeParallel > 30 {
                            Text("(+\(Fmt.duration(s.claudeParallel)) parallel)").font(.caption).foregroundStyle(.secondary)
                                .help("Mehrere Sessions liefen gleichzeitig. Gezählt wird die Wanduhrzeit.")
                        }
                    }
                }
                TableColumn("Überlappung") { s in
                    dur(s.overlap).help("Hintergrundzeit, während der du selbst am selben Projekt gearbeitet hast")
                }
                TableColumn("Abrechenbar") { s in
                    dur(s.billable).fontWeight(.semibold)
                        .help(billableHelp(s))
                }
                TableColumn("Blöcke") { s in
                    Text(s.blockCount == 0 ? "–" : "\(s.blockCount)").monospacedDigit()
                }
                .width(50)
                TableColumn("Längster Block") { s in dur(s.longestBlock) }
            }
            Divider()
            totals.padding(10)
        }
    }

    private func dur(_ t: TimeInterval) -> Text {
        t < 30 ? Text("–").foregroundColor(.secondary) : Text(Fmt.duration(t)).monospacedDigit()
    }

    private func billableHelp(_ s: ProjectDayStats) -> String {
        guard let p = model.project(s.projectId) else { return "Nicht zugeordnete Zeit ist nicht abrechenbar." }
        var parts = ["Vordergrund"]
        if p.backgroundBillable { parts.append("manueller Hintergrund") }
        if p.claudeBillable { parts.append("Claude Code") }
        return "Abrechenbar: " + parts.joined(separator: " + ") + ". Überlappung wird nur einmal gezählt."
    }

    private var totals: some View {
        let fg = report.stats.reduce(0) { $0 + $1.foreground }
        let bg = report.stats.reduce(0) { $0 + $1.background }
        let interactive = report.stats.reduce(0) { $0 + $1.claudeInteractive }
        return Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
            GridRow {
                total("Vordergrund gesamt", fg)
                total("Hintergrund gesamt", bg)
                total("Summe aller Spuren", report.trackSum)
                total("Wanduhrzeit", report.wallClock)
            }
            GridRow {
                total("Davon doppelt gezählt", report.doubleCounted, highlight: report.doubleCounted > 60)
                total("Abrechenbar (Summe)", report.billableSum)
                total("Abrechenbar (Wanduhr)", report.billableWallClock)
                total("Rauschen ignoriert", report.noiseIgnored)
            }
            if interactive > 30 {
                GridRow {
                    Text("\(Fmt.duration(interactive)) Claude-Code-Zeit lief, während du selbst im Terminal dieser Session warst. Diese Zeit zählt als Vordergrund, nicht als Hintergrund.")
                        .font(.caption).foregroundStyle(.secondary).gridCellColumns(4)
                }
            }
        }
    }

    private func total(_ label: String, _ t: TimeInterval, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.duration(t)).font(.title3).monospacedDigit().foregroundStyle(highlight ? .orange : .primary)
        }
    }
}
