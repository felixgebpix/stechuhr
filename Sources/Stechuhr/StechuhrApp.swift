import SwiftUI
import AppKit
import StechuhrCore

@main
struct StechuhrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Stechuhr", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: "clock.badge.checkmark")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare executable (swift run); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared?.flushRecorder() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum Page: Hashable {
    case day, projects, rules, folders, settings
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                Label("Tag", systemImage: "calendar.day.timeline.left").tag(Page.day)
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

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        let running = model.isToday ? (model.report?.claudeSpans.filter(\.isOpen) ?? []) : []
        if running.isEmpty {
            Text("Keine Claude-Code-Session arbeitet gerade")
        } else {
            Text("\(running.count) Claude-Code-Session(s) arbeiten:")
            ForEach(running, id: \.sessionId) { c in
                Text("  \((c.cwd as NSString).lastPathComponent) – \(model.project(c.projectId)?.name ?? "nicht zugeordnet") – seit \(Fmt.time(c.span.start))")
            }
        }
        Divider()
        if let r = model.report, model.isToday {
            Text("Heute: Vordergrund \(Fmt.duration(r.stats.reduce(0) { $0 + $1.foreground })) · abrechenbar \(Fmt.duration(r.billableWallClock))")
        }
        Button("Stechuhr öffnen") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Beenden") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
