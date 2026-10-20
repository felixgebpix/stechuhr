import Foundation

/// Reads page, website and browser profile from a browser window title, for browsers that give no URL.
/// e.g. "Ein Video - Videoportal — Arbeit" → page "Ein Video - Videoportal", site "Videoportal", profile "Arbeit".
public enum BrowserTitle {
    public static let browserApps: Set<String> = [
        "Waterfox", "Firefox", "Firefox Developer Edition", "Firefox Nightly", "Zen", "LibreWolf", "Floorp",
        "Safari", "Google Chrome", "Chromium", "Arc", "Brave Browser", "Microsoft Edge", "Vivaldi", "Opera", "Orion", "Dia",
    ]

    public static func isBrowser(_ app: String) -> Bool { browserApps.contains(app) }

    public struct Parsed: Equatable {
        public var page: String
        public var site: String?
        public var profile: String?
    }

    public static func parse(_ title: String, app: String? = nil) -> Parsed {
        var page = title
        var profile: String?
        // Firefox-family: "Page — Profile" or "Profile — Waterfox" (empty tab).
        let parts = title.components(separatedBy: " — ")
        if parts.count >= 2 {
            let last = parts.last!.trimmingCharacters(in: .whitespaces)
            if let app, last == app {
                profile = parts.count >= 2 ? parts[parts.count - 2] : nil
                page = parts.count >= 3 ? parts.dropLast(2).joined(separator: " — ") : ""
            } else {
                profile = last
                page = parts.dropLast().joined(separator: " — ")
            }
        }
        return Parsed(page: page, site: site(of: page), profile: profile)
    }

    static func site(of page: String) -> String? {
        let p = page.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)  // "(13) Feed"
        // A host name anywhere wins: "… - news.example.org", "www.example.at".
        for token in p.components(separatedBy: CharacterSet(charactersIn: " |·•–-")) {
            let t = token.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil { return t.lowercased() }
        }
        // "Name • Section" (site first), otherwise "Page - Site" / "Page | Site" (site last).
        if p.contains(" • ") { return p.components(separatedBy: " • ").first.map(trim) }
        for sep in [" | ", " - ", " – ", " · "] where p.contains(sep) {
            let last = trim(p.components(separatedBy: sep).last!)
            return last.count <= 40 ? last : nil
        }
        return nil
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
}
