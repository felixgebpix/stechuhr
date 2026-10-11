import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// One recorded foreground period in one window / browser tab.
public struct RecordedEvent: Hashable, Sendable {
    public var id: Int64
    public var span: TimeSpan
    public var app: String
    public var bundleId: String
    public var title: String
    public var url: String?
    public var pageTitle: String?
    public var path: String?

    public init(id: Int64 = 0, span: TimeSpan, app: String, bundleId: String = "", title: String,
                url: String? = nil, pageTitle: String? = nil, path: String? = nil) {
        self.id = id
        self.span = span
        self.app = app
        self.bundleId = bundleId
        self.title = title
        self.url = url
        self.pageTitle = pageTitle
        self.path = path
    }
}

/// What is in front right now.
struct Observation: Equatable {
    var app: String
    var bundleId: String
    var title: String
    var url: String?
    var pageTitle: String?
    var path: String?
}

public enum Permissions {
    /// Window titles need the Accessibility permission.
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Records the frontmost app, its focused window title and (for browsers) the active tab.
/// Runs on its own queue with its own database connection.
public final class ActivityRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "stechuhr.recorder", qos: .utility)
    private let db: Database
    private var timer: DispatchSourceTimer?
    private var current: (id: Int64, obs: Observation, start: Date, lastSeen: Date)?
    private var paused = false
    private var scripts: [String: NSAppleScript] = [:]

    public var interval: TimeInterval = 2
    /// No keyboard/mouse input for this long → away.
    public var idleThreshold: TimeInterval = 180

    public init(databaseURL: URL = StechuhrPaths.database) throws {
        db = try Database(url: databaseURL)
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.setPaused(true) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.setPaused(false) }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.setPaused(true)
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.setPaused(false)
        }
    }

    /// Closes the open event, e.g. on quit.
    public func flush() {
        queue.sync { close(at: Date()) }
    }

    private func setPaused(_ p: Bool) {
        queue.async {
            self.paused = p
            if p { self.close(at: Date()) }
        }
    }

    private func tick() {
        let now = Date()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if paused || idle >= idleThreshold {
            // Away: the period ended with the last input.
            close(at: paused ? now : now.addingTimeInterval(-idle))
            return
        }
        guard let obs = observe() else { close(at: now); return }

        if var cur = current, cur.obs == obs, now.timeIntervalSince(cur.lastSeen) < interval * 3 + 5 {
            cur.lastSeen = now
            current = cur
            try? db.extendRecorded(id: cur.id, to: now)
            return
        }
        close(at: current.map { now.timeIntervalSince($0.lastSeen) < interval * 3 + 5 ? now : $0.lastSeen } ?? now)
        let event = RecordedEvent(span: TimeSpan(now, now), app: obs.app, bundleId: obs.bundleId, title: obs.title,
                                  url: obs.url, pageTitle: obs.pageTitle, path: obs.path)
        if let id = try? db.insertRecorded(event) {
            current = (id, obs, now, now)
        }
    }

    private func close(at t: Date) {
        guard let cur = current else { return }
        try? db.extendRecorded(id: cur.id, to: max(cur.start, min(t, Date())))
        current = nil
    }

    private func observe() -> Observation? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unbekannt"
        let bundle = app.bundleIdentifier ?? ""
        let window = Self.focusedWindow(pid: app.processIdentifier)
        var obs = Observation(app: name, bundleId: bundle, title: window.title ?? "", path: window.path)
        switch browserTab(bundle: bundle) {
        case .tab(let url, let title):
            obs.url = url
            obs.pageTitle = title
        case .privateWindow:
            obs.title = "Privates Fenster"
        case .none:
            break
        }
        return obs
    }

    /// Title and – for document-based apps – the file path of the focused window.
    static func focusedWindow(pid: pid_t) -> (title: String?, path: String?) {
        guard AXIsProcessTrusted() else { return (nil, nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return (nil, nil) }
        let element = window as! AXUIElement
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        var document: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXDocumentAttribute as CFString, &document)
        var path: String?
        if let doc = document as? String, let url = URL(string: doc), url.isFileURL {
            path = url.path
        }
        return (title as? String, path)
    }

    // MARK: - Browsers

    static let chromium: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.google.Chrome.beta": "Google Chrome Beta",
        "company.thebrowser.Browser": "Arc", "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge", "com.vivaldi.Vivaldi": "Vivaldi",
        "org.chromium.Chromium": "Chromium", "com.operasoftware.Opera": "Opera",
        "company.thebrowser.dia": "Dia",
    ]
    static let safari: [String: String] = [
        "com.apple.Safari": "Safari", "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
    ]

    public static func isScriptableBrowser(_ bundleId: String) -> Bool {
        chromium[bundleId] != nil || safari[bundleId] != nil
    }

    /// Asks the browser for its active tab. Private/incognito windows are recorded without URL.
    enum BrowserTab { case tab(String, String), privateWindow, none }

    private func browserTab(bundle: String) -> BrowserTab {
        let source: String
        if let name = Self.chromium[bundle] {
            source = """
            with timeout of 2 seconds
              tell application "\(name)"
                if (count of windows) = 0 then return ""
                set w to front window
                try
                  if mode of w is "incognito" then return "\u{1F}privat"
                end try
                return (URL of active tab of w) & "\u{1F}" & (title of active tab of w)
              end tell
            end timeout
            """
        } else if let name = Self.safari[bundle] {
            source = """
            with timeout of 2 seconds
              tell application "\(name)"
                if (count of documents) = 0 then return ""
                return (URL of front document) & "\u{1F}" & (name of front document)
              end tell
            end timeout
            """
        } else {
            return .none
        }
        let script = scripts[bundle] ?? NSAppleScript(source: source)
        scripts[bundle] = script
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error).stringValue, !result.isEmpty else { return .none }
        let parts = result.components(separatedBy: "\u{1F}")
        guard parts.count >= 2 else { return .none }
        if parts[0].isEmpty && parts[1] == "privat" { return .privateWindow }
        return .tab(parts[0], parts[1...].joined(separator: " "))
    }
}
