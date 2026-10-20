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
            // Firefox-based browsers have no AppleScript, but expose the page URL via accessibility.
            if Self.firefox.contains(bundle), let url = firefoxURL(pid: app.processIdentifier) {
                obs.url = url
                obs.pageTitle = BrowserTitle.parse(obs.title).page
            }
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
    static let firefox: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "net.waterfox.waterfox",
        "app.zen-browser.zen", "io.gitlab.librewolf-community", "one.ablaze.floorp",
    ]

    /// Cached address bar of the current Firefox-family window (searching the tree every 2 s would be too expensive).
    private var urlField: (window: AXUIElement, field: AXUIElement)?
    private var wroteDiagnostics = false
    /// Failed lookups per browser process; drives the escalation below.
    private var misses: [pid_t: Int] = [:]

    /// URL of the focused tab in a Firefox-based browser, via accessibility:
    /// 1. AXURL of the web area, 2. value of the address bar. If neither works, a one-time diagnostic dump is written.
    func firefoxURL(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { return nil }
        let window = windowRef as! AXUIElement

        // Firefox builds its accessibility tree only when an assistive app asks for it.
        // AXManualAccessibility is the lightweight switch; AXEnhancedUserInterface (what VoiceOver uses) only if needed.
        let miss = misses[pid, default: 0]
        if miss == 0 {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        } else if miss == 3 {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }

        if let cached = urlField, CFEqual(cached.window, window), let url = Self.addressBarURL(cached.field) {
            return url
        }
        urlField = nil

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var dump: [String] = []
        while !queue.isEmpty && visited < 1500 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = Self.string(el, kAXRoleAttribute)
            if !wroteDiagnostics && dump.count < 600 {
                dump.append(String(repeating: "  ", count: depth) + Self.describe(el, role: role))
            }
            if role == "AXWebArea" {
                var url: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &url) == .success {
                    if let u = url as? URL { misses[pid] = 0; return u.absoluteString }
                    if let s = url as? String, !s.isEmpty { misses[pid] = 0; return s }
                }
                continue  // never descend into page content
            }
            if role == "AXTextField" || role == "AXComboBox", Self.looksLikeAddressBar(el), let url = Self.addressBarURL(el) {
                urlField = (window, el)
                misses[pid] = 0
                return url
            }
            var children: CFTypeRef?
            if depth < 14, AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.map { ($0, depth + 1) })
            }
        }
        misses[pid] = miss + 1
        // Diagnose only after both switches had a few seconds to take effect.
        if !wroteDiagnostics && miss >= 6 {
            wroteDiagnostics = true
            let text = "Stechuhr – Diagnose Firefox-Browser, \(Date())\nKeine URL gefunden (\(visited) Elemente durchsucht).\n\n" + dump.joined(separator: "\n")
            let url = StechuhrPaths.supportDir.appendingPathComponent("firefox-diagnose.txt")
            FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        }
        return nil
    }

    static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func looksLikeAddressBar(_ el: AXUIElement) -> Bool {
        let id = (string(el, "AXIdentifier") ?? "").lowercased()
        if id.contains("urlbar") || id.contains("address") { return true }
        let desc = [string(el, kAXDescriptionAttribute), string(el, kAXTitleAttribute), string(el, kAXPlaceholderValueAttribute)]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        return ["adresse", "address", "suchbegriff", "search or enter", "url"].contains { desc.contains($0) }
    }

    /// The address bar shows "example.com/path" or a full URL; search terms are ignored.
    static func addressBarURL(_ el: AXUIElement) -> String? {
        guard let raw = string(el, kAXValueAttribute)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              !raw.contains(" ") else { return nil }
        if raw.contains("://") || raw.hasPrefix("about:") { return raw }
        guard raw.contains("."), let host = raw.split(separator: "/").first, host.contains(".") else { return nil }
        return "https://" + raw
    }

    /// One line of the diagnostic dump: role, subrole, identifier, description and shortened title/value.
    static func describe(_ el: AXUIElement, role: String?) -> String {
        func short(_ s: String?) -> String { s.map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 } ?? "" }
        var parts = [role ?? "?"]
        if let sub = string(el, kAXSubroleAttribute) { parts.append("sub=\(sub)") }
        if let id = string(el, "AXIdentifier"), !id.isEmpty { parts.append("id=\(id)") }
        if let d = string(el, kAXDescriptionAttribute), !d.isEmpty { parts.append("desc=\(short(d))") }
        if let t = string(el, kAXTitleAttribute), !t.isEmpty { parts.append("title=\(short(t))") }
        if let v = string(el, kAXValueAttribute), !v.isEmpty { parts.append("value=\(short(v))") }
        var names: CFArray?
        if role == "AXWebArea", AXUIElementCopyAttributeNames(el, &names) == .success, let n = names as? [String] {
            parts.append("attrs=\(n.joined(separator: ","))")
        }
        return parts.joined(separator: " | ")
    }

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
