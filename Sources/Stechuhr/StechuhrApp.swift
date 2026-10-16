import SwiftUI
import AppKit
import StechuhrCore

@main
struct StechuhrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Menu bar icon and main window are managed with AppKit (StatusItemController, MainWindow):
        // SwiftUI's MenuBarExtra cannot open on hover.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon – Stechuhr lives in the menu bar (also when started via swift run).
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let model = AppModel()
            statusItem = StatusItemController(model: model)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared?.flushRecorder() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum Page: Hashable {
    case day, range, projects, rules, folders, settings
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                Label("Tag", systemImage: "calendar.day.timeline.left").tag(Page.day)
                Label("Auswertung", systemImage: "chart.bar.doc.horizontal").tag(Page.range)
                Section("Einrichtung") {
                    Label("Projekte", systemImage: "folder").tag(Page.projects)
                    Label("Regeln", systemImage: "wand.and.stars").badge(model.suggestions.count).tag(Page.rules)
                    Label("Claude-Code-Ordner", systemImage: "sparkles").badge(unmappedCount).tag(Page.folders)
                    Label("Einstellungen", systemImage: "gearshape").tag(Page.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch model.page ?? .day {
            case .day: DayView()
            case .range: RangeView()
            case .projects: ProjectsView()
            case .rules: RulesView()
            case .folders: ClaudeFoldersView()
            case .settings: GeneralSettingsView()
            }
        }
    }

    private var unmappedCount: Int {
        // Folders that got their project from a keyword are not "unassigned".
        model.report?.unmappedFolders.count ?? 0
    }
}

enum MenuBarIcon {
    /// Template image (adapts to light/dark menu bar): clock with a time card underneath.
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let face = NSBezierPath(ovalIn: NSRect(x: 3, y: 5.2, width: 11.5, height: 11.5))
            face.lineWidth = 1.6
            face.stroke()
            let hands = NSBezierPath()
            hands.move(to: NSPoint(x: 8.75, y: 10.95))
            hands.line(to: NSPoint(x: 8.75, y: 14.4))
            hands.move(to: NSPoint(x: 8.75, y: 10.95))
            hands.line(to: NSPoint(x: 11.2, y: 9.5))
            hands.lineWidth = 1.5
            hands.lineCapStyle = .round
            hands.stroke()
            // time card
            NSBezierPath(roundedRect: NSRect(x: 5.25, y: 0.6, width: 7, height: 3.4), xRadius: 0.8, yRadius: 0.8).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

/// Opens with one click on the menu bar icon: projects right away, one click starts or switches the timer.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    /// Closes the popover.
    var dismiss: () -> Void = {}
    @State private var newName = ""
    @FocusState private var newFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            runningHeader
            Divider()
            if model.activeProjects.isEmpty {
                Text("Noch keine Projekte – unten eines anlegen.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.menuProjects) { p in projectRow(p) }
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                TextField("Neues Projekt – Enter startet den Timer", text: $newName)
                    .textFieldStyle(.plain)
                    .focused($newFocused)
                    .onSubmit(createAndStart)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            Divider()
            statusLines
            Divider()
            HStack {
                footerButton("Heute", "calendar") { model.setDay(Date()); open(.day) }
                footerButton("Auswertung", "chart.bar.doc.horizontal") { open(.range) }
                footerButton("Einstellungen", "gearshape") { open(.settings) }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("Stechuhr beenden")
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder
    private var runningHeader: some View {
        if let r = model.runningEntry, let p = model.project(r.projectId) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: p.colorHex)).frame(width: 10, height: 10)
                Text(p.name).font(.headline).lineLimit(1)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed(since: r.span.start)).font(.headline.monospacedDigit())
                }
                Button { model.stopWorking() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).foregroundStyle(.red).help("Timer stoppen")
            }
        } else {
            HStack {
                Image(nsImage: MenuBarIcon.image).renderingMode(.template)
                Text("Kein Timer läuft – Projekt anklicken").foregroundStyle(.secondary)
            }
        }
    }

    private func projectRow(_ p: Project) -> some View {
        let running = model.runningEntry?.projectId == p.id
        return Button {
            if running { model.stopWorking() } else { model.startWorking(on: p.id) }
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: p.colorHex)).frame(width: 10, height: 10)
                Text(p.name).lineLimit(1)
                Spacer()
                if let t = model.todayForeground[p.id], t >= 60 {
                    Text(Fmt.duration(t)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.caption).foregroundStyle(running ? .red : .secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(running ? Color(hex: p.colorHex).opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(running ? "Timer stoppen" : "Timer für \(p.name) starten")
    }

    @ViewBuilder
    private var statusLines: some View {
        let working = model.workingClaudeSessions
        VStack(alignment: .leading, spacing: 3) {
            if let today = model.todayReport {
                Text("Heute \(Fmt.duration(today.stats.reduce(0) { $0 + $1.foreground })) · abrechenbar \(Fmt.duration(today.billableWallClock))")
            }
            if !working.isEmpty {
                let names = Set(working.map { model.project($0.projectId)?.name ?? "nicht zugeordnet" }).sorted()
                Text("Claude Code arbeitet: \(working.count) Session(s) · \(names.joined(separator: ", "))").lineLimit(2)
            }
            if !model.suggestions.isEmpty {
                Button("\(model.suggestions.count) Regel-Vorschläge ansehen …") { open(.rules) }.buttonStyle(.link)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func footerButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.caption) }.buttonStyle(.borderless)
    }

    private func createAndStart() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let existing = model.activeProjects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        model.startWorking(on: existing?.id ?? model.newProject(named: name))
        newName = ""
        dismiss()
    }

    private func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private func open(_ page: Page) {
        model.page = page
        dismiss()
        MainWindow.shared.show(model: model)
    }
}
