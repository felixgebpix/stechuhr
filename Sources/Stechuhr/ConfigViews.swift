import SwiftUI
import AppKit
import StechuhrCore

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""
    @State private var confirmDelete: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Neues Projekt", text: $newName).textFieldStyle(.roundedBorder).frame(width: 240)
                    .onSubmit(add)
                Button("Anlegen", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(10)
            Table(model.projects) {
                TableColumn("Farbe") { p in
                    ColorPicker("", selection: Binding(get: { Color(hex: p.colorHex) },
                                                       set: { var q = p; q.colorHex = $0.hexString; model.save(q) }),
                                supportsOpacity: false).labelsHidden()
                }
                .width(44)
                TableColumn("Name") { p in
                    TextField("", text: Binding(get: { p.name }, set: { var q = p; q.name = $0; model.save(q) }))
                }
                TableColumn("Stichwörter") { p in
                    KeywordsField(project: p)
                }
                .width(min: 160, ideal: 240)
                TableColumn("Hintergrund abrechenbar") { p in
                    Toggle("", isOn: Binding(get: { p.backgroundBillable }, set: { var q = p; q.backgroundBillable = $0; model.save(q) }))
                        .labelsHidden()
                        .help("Manuell markierte Hintergrundzeit fließt in die abrechenbare Summe ein")
                }
                TableColumn("Claude Code abrechenbar") { p in
                    Toggle("", isOn: Binding(get: { p.claudeBillable }, set: { var q = p; q.claudeBillable = $0; model.save(q) }))
                        .labelsHidden()
                        .help("Claude-Code-Hintergrundzeit fließt in die abrechenbare Summe ein")
                }
                TableColumn("Archiviert") { p in
                    Toggle("", isOn: Binding(get: { p.archived }, set: { var q = p; q.archived = $0; model.save(q) })).labelsHidden()
                }
                .width(70)
                TableColumn("") { p in
                    Button(role: .destructive) { confirmDelete = p } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                .width(30)
            }
        }
        .navigationTitle("Projekte")
        .alert("Projekt löschen?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
               presenting: confirmDelete) { p in
            Button("Löschen", role: .destructive) { model.deleteProject(p.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { p in
            Text("„\(p.name)“ samt Regeln, Ordner-Zuordnungen, Hintergrundaufgaben und manuellen Zuweisungen wird gelöscht. Tipp: Archivieren behält die Daten.")
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.newProject(named: name)
        newName = ""
    }
}

/// Comma-separated keywords; saved on Enter or when the field loses focus.
struct KeywordsField: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("z. B. Kürzel, Kunde, Repo"))
            .focused($focused)
            .onAppear { text = project.keywords.joined(separator: ", ") }
            .onSubmit(save)
            .onChange(of: focused) { _, f in if !f { save() } }
            .help("Der Projektname zählt automatisch. Weitere Wörter mit Komma trennen. Sie werden als ganze Wörter in Fenstertiteln, URLs und Claude-Code-Ordnern gesucht.")
    }

    private func save() {
        let words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard words != project.keywords else { return }
        var p = project
        p.keywords = words
        model.save(p)
    }
}

struct RulesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Regeln ordnen Aktivitäten automatisch zu. Manuelle Zuweisungen haben Vorrang. Bei mehreren passenden Regeln gewinnt die mit der kleineren Priorität.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    editing = Rule(projectId: model.activeProjects.first?.id ?? 0, conditions: [RuleCondition(.app, .equals, "")])
                } label: { Label("Regel", systemImage: "plus") }
                .disabled(model.activeProjects.isEmpty)
            }
            .padding(10)
            if !model.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Vorschläge aus deinen Zuweisungen", systemImage: "lightbulb").font(.headline)
                    ForEach(model.suggestions) { s in
                        HStack {
                            Circle().fill(model.project(s.projectId).map { Color(hex: $0.colorHex) } ?? .gray).frame(width: 9, height: 9)
                            Text(model.project(s.projectId)?.name ?? "–").fontWeight(.medium)
                            Text("wenn " + s.conditions.map(\.summary).joined(separator: " und ")).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(s.count)× von Hand, \(Fmt.duration(s.duration)) an \(s.days) Tag(en)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Übernehmen") { model.accept(s) }
                            Button("Ablehnen") { model.dismiss(s) }
                        }
                    }
                }
                .padding(10)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            Table(model.rules) {
                TableColumn("Projekt") { r in Text(model.project(r.projectId)?.name ?? "–") }
                    .width(min: 120, ideal: 160)
                TableColumn("Bedingungen") { r in Text(r.conditions.map(\.summary).joined(separator: " und ")) }
                TableColumn("Priorität") { r in Text("\(r.priority)").monospacedDigit() }
                    .width(60)
                TableColumn("") { r in
                    HStack {
                        Button { editing = r } label: { Image(systemName: "pencil") }
                        Button(role: .destructive) { model.deleteRule(r.id) } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                }
                .width(60)
            }
        }
        .navigationTitle("Regeln")
        .sheet(item: $editing) { rule in RuleEditor(rule: rule) }
    }
}

struct RuleEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var rule: Rule

    init(rule: Rule) { _rule = State(initialValue: rule) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rule.id == 0 ? "Neue Regel" : "Regel bearbeiten").font(.headline)
            Picker("Projekt", selection: $rule.projectId) {
                ForEach(model.activeProjects) { p in Text(p.name).tag(p.id) }
            }
            Text("Alle Bedingungen müssen zutreffen:").font(.caption).foregroundStyle(.secondary)
            ForEach(rule.conditions.indices, id: \.self) { i in
                HStack {
                    Picker("", selection: $rule.conditions[i].field) {
                        ForEach(RuleField.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 90)
                    Picker("", selection: $rule.conditions[i].match) {
                        ForEach(RuleMatch.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 90)
                    TextField("Wert", text: $rule.conditions[i].value)
                    Button { rule.conditions.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(rule.conditions.count == 1)
                }
            }
            Button { rule.conditions.append(RuleCondition(.title, .contains, "")) } label: { Label("Bedingung", systemImage: "plus") }
                .buttonStyle(.borderless)
            Stepper("Priorität: \(rule.priority)", value: $rule.priority, in: 0...1000, step: 10)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { model.save(rule); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.projectId == 0 || rule.conditions.contains { $0.value.isEmpty })
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Claude Code working folders → projects, plus the list of unknown folders.
struct ClaudeFoldersView: View {
    @EnvironmentObject var model: AppModel
    @State private var usage: [Database.FolderUsage] = []

    var body: some View {
        let resolved = usage.map { ($0, model.resolve(folder: $0.cwd)) }
        let unmapped = resolved.filter { $0.1.projectId == nil }.map(\.0)
        let byKeyword = resolved.compactMap { u, r -> (Database.FolderUsage, Int64, String)? in
            if case .keyword(let id, let term) = r { return (u, id, term) }
            return nil
        }
        Form {
            Section("Erfassung") {
                LabeledContent("Empfang") {
                    Label(model.hookServerRunning ? "läuft auf 127.0.0.1:\(String(StechuhrPaths.hookPort))" : "nicht aktiv",
                          systemImage: model.hookServerRunning ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.hookServerRunning ? .green : .red)
                }
                LabeledContent("Hook-Helfer") {
                    Text(model.hookHelperInstalled ? StechuhrPaths.hookBinary.path : "nicht installiert")
                        .textSelection(.enabled).font(.caption.monospaced())
                }
                LabeledContent("Letztes Ereignis") {
                    Text(model.lastHookEvent.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "noch keines")
                }
            }
            Section {
                if unmapped.isEmpty {
                    Text("Alle Ordner der letzten 60 Tage sind zugeordnet.").foregroundStyle(.secondary)
                }
                ForEach(unmapped, id: \.cwd) { f in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(f.cwd).font(.body.monospaced()).lineLimit(1).truncationMode(.head)
                            Text("\(f.sessions) Session(s) · zuletzt \(f.lastSeen.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Zuweisen") {
                            ForEach(model.activeProjects) { p in
                                Button(p.name) { model.map(folder: f.cwd, to: p.id) }
                            }
                            if f.cwd.split(separator: "/").count > 2 {
                                Divider()
                                let parent = (f.cwd as NSString).deletingLastPathComponent
                                Menu("Übergeordneten Ordner \(parent)") {
                                    ForEach(model.activeProjects) { p in
                                        Button(p.name) { model.map(folder: parent, to: p.id) }
                                    }
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text("Nicht zugeordnet")
            } footer: {
                Text("Ordner, deren Pfad den Namen oder ein Stichwort genau eines Projekts enthält, werden automatisch zugeordnet. Passen mehrere Projekte, landet der Ordner hier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !byKeyword.isEmpty {
                Section("Automatisch erkannt (per Stichwort)") {
                    ForEach(byKeyword, id: \.0.cwd) { f, pid, term in
                        HStack {
                            Text(f.cwd).font(.body.monospaced()).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("→ \(model.project(pid)?.name ?? "–") (Stichwort „\(term)“)").foregroundStyle(.secondary)
                            Button("Fest zuordnen") { model.map(folder: f.cwd, to: pid) }
                        }
                    }
                }
            }
            Section {
                ForEach(model.folders) { m in
                    HStack {
                        Text(m.path).font(.body.monospaced()).lineLimit(1).truncationMode(.head)
                        Text("inkl. Unterordner").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: Binding(get: { m.projectId }, set: { model.map(folder: m.path, to: $0) })) {
                            ForEach(model.projects) { p in Text(p.name).tag(p.id) }
                        }
                        .labelsHidden().frame(width: 180)
                        Button(role: .destructive) { model.deleteFolderMapping(m.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Ordner hinzufügen …") {
                    ForEach(model.activeProjects) { p in
                        Button(p.name) { pickFolder(for: p.id) }
                    }
                }
                .fixedSize()
                .disabled(model.activeProjects.isEmpty)
            } header: {
                Text("Ordner → Projekt")
            } footer: {
                Text("Der längste passende Pfad gewinnt. So kannst du z. B. ~/repos einem Projekt zuweisen und ~/repos/kunde-x einem anderen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Claude-Code-Ordner")
        .onAppear { usage = model.recentClaudeFolders() }
        .onChange(of: model.lastHookEvent) { _, _ in usage = model.recentClaudeFolders() }
    }

    private func pickFolder(for projectId: Int64) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Zuweisen"
        if panel.runModal() == .OK {
            for url in panel.urls { model.map(folder: url.path, to: projectId) }
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var s = AppSettings()
    @State private var terminals = ""

    var body: some View {
        Form {
            Section("Fragmentiertes Arbeiten") {
                Stepper("Rauschen: Wechsel unter \(Int(s.noiseThreshold)) s ignorieren", value: $s.noiseThreshold, in: 0...60, step: 1)
                Text("Kürzere Wechsel werden dem umgebenden Projekt zugerechnet, wenn davor und danach dasselbe Projekt lief, sonst ignoriert. Alles darüber behält seine eigene Zuordnung.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Arbeitsblock: Pausen bis \(Int(s.blockGap / 60)) min zählen zum selben Block", value: $s.blockGap, in: 0...1800, step: 60)
            }
            Section("Claude Code") {
                Stepper("Laufende Session ohne Lebenszeichen nach \(Int(s.claudeStaleAfter / 60)) min beenden",
                        value: $s.claudeStaleAfter, in: 600...6 * 3600, step: 600)
                VStack(alignment: .leading) {
                    Text("Terminal-Apps (eine pro Zeile)")
                    TextEditor(text: $terminals).font(.body.monospaced()).frame(height: 90)
                    Text("Ist eine dieser Apps im Vordergrund und zeigt sie die Session (der Ordnername steht im Fenstertitel, oder es ist nur eine Session offen), zählt die Zeit als Vordergrund und nicht zusätzlich als Hintergrund.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Vordergrund-Erfassung") {
                Stepper("Abwesend nach \(Int(s.idleThreshold / 60)) min ohne Maus/Tastatur", value: $s.idleThreshold, in: 60...1800, step: 60)
                LabeledContent("Fenstertitel") {
                    if Permissions.accessibilityGranted {
                        Label("erlaubt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Bedienungshilfen-Berechtigung öffnen") { Permissions.openAccessibilitySettings() }
                    }
                }
                Text("Stechuhr zeichnet die aktive App, den Fenstertitel und in Safari, Chrome, Arc, Brave, Edge, Vivaldi und Opera den aktiven Tab selbst auf. Beim ersten Mal fragt macOS pro Browser einmal nach. Private Fenster werden ohne Titel und URL erfasst. Bei Firefox gibt es nur den Fenstertitel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Speichern") {
                    s.terminalApps = terminals.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    model.save(s)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Einstellungen")
        .onAppear {
            s = model.settings
            terminals = s.terminalApps.joined(separator: "\n")
        }
    }
}
