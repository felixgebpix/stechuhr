import SwiftUI
import AppKit
import StechuhrCore

@main
struct StechuhrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Menu bar app: the window opens only from the menu bar icon, not at launch.
        Window("Stechuhr", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultLaunchBehavior(.suppressed)
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon – Stechuhr lives in the menu bar (also when started via swift run).
        NSApp.setActivationPolicy(.accessory)
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

/// Menu bar icon; shows how many Claude Code sessions are working right now.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let working = model.workingClaudeSessions.count
        HStack(spacing: 2) {
            Image(nsImage: MenuBarIcon.image)
            if working > 0 { Text("\(working)") }
        }
        .help("Stechuhr")
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

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        let running = model.workingClaudeSessions
        if let today = model.todayReport {
            Text("Heute: \(Fmt.duration(today.stats.reduce(0) { $0 + $1.foreground })) Vordergrund · \(Fmt.duration(today.billableWallClock)) abrechenbar")
        }
        Divider()
        if let r = model.runningEntry {
            Text("Jetzt: \(model.project(r.projectId)?.name ?? "–") seit \(Fmt.time(r.span.start))")
            Button("Stopp") { model.stopWorking() }
        }
        Menu("Ich arbeite jetzt an …") {
            ForEach(model.activeProjects) { p in
                Button(p.name) { model.startWorking(on: p.id) }
            }
        }
        .disabled(model.activeProjects.isEmpty)
        Divider()
        if running.isEmpty {
            Text("Keine Claude-Code-Session arbeitet gerade")
        } else {
            Text("Claude Code arbeitet (\(running.count)):")
            ForEach(running, id: \.sessionId) { c in
                Text("\((c.cwd as NSString).lastPathComponent) – \(model.project(c.projectId)?.name ?? "nicht zugeordnet") – seit \(Fmt.time(c.span.start))")
            }
        }
        if !model.suggestions.isEmpty {
            Divider()
            Button("\(model.suggestions.count) Regel-Vorschläge ansehen …") { open(.rules) }
        }
        Divider()
        Button("Heute öffnen") {
            model.setDay(Date())
            open(.day)
        }
        .keyboardShortcut("o")
        Button("Auswertung …") { open(.range) }
        Button("Projekte …") { open(.projects) }
        Button("Einstellungen …") { open(.settings) }
            .keyboardShortcut(",")
        Divider()
        Button("Stechuhr beenden") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func open(_ page: Page) {
        model.page = page
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
