import Foundation

/// A day as Markdown for analysis with an AI ("Was habe ich heute gemacht?").
/// URLs are shortened to scheme, host and path – query strings often contain tokens or personal data.
public enum AIExport {
    public static func markdown(_ r: DayReport, projectName: (Int64?) -> String) -> String {
        var out: [String] = []
        let dayTitle = r.day.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "de_AT")))
        out.append("# Stechuhr – Tagesprotokoll \(dayTitle)")
        out.append("")
        out.append("""
        > Vorschlag für die KI: „Fasse zusammen, woran ich an diesem Tag gearbeitet habe – gruppiert nach Projekt und Thema, \
        mit geschätzter Zeit. Nenne, was nach Recherche, Kommunikation, Umsetzung oder Ablenkung aussieht, und welche \
        Zeit noch keinem Projekt zugeordnet ist.“
        """)
        out.append("")
        out.append("Alle Zeiten in Ortszeit. Dauer = Zeit im Vordergrund. Private Browserfenster sind nicht enthalten.")
        out.append("")

        // Overview
        out.append("## Übersicht pro Projekt")
        out.append("")
        out.append("| Projekt | Vordergrund | davon bestätigt | Claude Code (Hintergrund) | Hintergrund manuell | Abrechenbar | Arbeitsblöcke |")
        out.append("|---|---|---|---|---|---|---|")
        for s in r.stats where s.trackSum >= 30 {
            out.append("| \(cell(projectName(s.projectId))) | \(dur(s.foreground)) | \(dur(s.confirmed)) | \(dur(s.claude)) | \(dur(s.manualBackground)) | \(dur(s.billable)) | \(s.blockCount) |")
        }
        out.append("")
        out.append("Gesamt: \(dur(r.stats.reduce(0) { $0 + $1.foreground })) Vordergrund, \(dur(r.billableWallClock)) abrechenbar (Wanduhr).")
        out.append("")

        // Entries and background
        if !r.entries.isEmpty || !r.manualTasks.isEmpty {
            out.append("## Zeiteinträge und Hintergrundaufgaben")
            out.append("")
            let items = r.entries.map { ($0.span, $0.projectId, "Zeiteintrag", $0.title) }
                + r.manualTasks.map { ($0.span, $0.projectId, "Hintergrund", $0.note) }
            for (span, pid, kind, text) in items.sorted(by: { $0.0.start < $1.0.start }) {
                out.append("- \(time(span.start))–\(time(span.end)) (\(dur(span.duration))) · \(projectName(pid)) · \(kind)\(text.isEmpty ? "" : " · \(text)")")
            }
            out.append("")
        }

        // Claude Code
        if !r.claudeSpans.isEmpty {
            out.append("## Claude Code (arbeitet im Hintergrund)")
            out.append("")
            let bySession = Dictionary(grouping: r.claudeSpans, by: \.sessionId)
            for run in r.runs where bySession[run.sessionId] != nil {
                let spans = bySession[run.sessionId]!
                let total = Spans.total(spans.map(\.span))
                let times = spans.map { "\(time($0.span.start))–\(time($0.span.end))" }.joined(separator: ", ")
                out.append("- \(projectName(spans.first?.projectId)) · `\(home(run.cwd))`\(run.title.map { " · „\($0)“" } ?? "") · \(dur(total)) · \(times)")
            }
            out.append("")
        }

        let counted = r.segments.filter(\.counts)

        // Browser: tabs with URL by domain; title-only browser windows (e.g. Firefox family) by website from the title.
        let isBrowserWindow: (AttributedSegment) -> Bool = { $0.segment.isWeb || BrowserTitle.isBrowser($0.segment.app) }
        let browser = counted.filter(isBrowserWindow)
        if !browser.isEmpty {
            out.append("## Browser (nach Website und Seite)")
            out.append("")
            out.append("Website aus der URL, sonst aus dem Fenstertitel geschätzt. Profil = Browserprofil (z. B. Arbeit/Privat).")
            out.append("")
            func key(_ s: AttributedSegment) -> (site: String, page: String, profile: String?) {
                let parsed = BrowserTitle.parse(s.segment.title, app: s.segment.app)
                if s.segment.isWeb {
                    return (s.segment.domain ?? "?", s.segment.displayTitle, parsed.profile)
                }
                return (parsed.site ?? "(Website unbekannt)", parsed.page.isEmpty ? "(leerer Tab)" : parsed.page, parsed.profile)
            }
            let bySite = Dictionary(grouping: browser) { key($0).site }
            for (site, segs) in bySite.sorted(by: { total($0.value) > total($1.value) }) {
                let profiles = Set(segs.compactMap { key($0).profile }).sorted()
                out.append("### \(site) – \(dur(total(segs)))\(profiles.isEmpty ? "" : " · Profil: \(profiles.joined(separator: ", "))")")
                let pages = Dictionary(grouping: segs) { key($0).page }
                for (title, ps) in pages.sorted(by: { total($0.value) > total($1.value) }) where total(ps) >= 5 {
                    let first = ps.map(\.segment.span.start).min()!, last = ps.map(\.segment.span.end).max()!
                    let url = ps.compactMap(\.segment.url).first.map(shortURL) ?? ""
                    out.append("- \(title) · \(dur(total(ps))) · \(time(first))–\(time(last))\(url.isEmpty ? "" : " · <\(url)>") · \(projectsLabel(ps, projectName))")
                }
                out.append("")
            }
        }

        // Other apps
        let apps = counted.filter { !isBrowserWindow($0) }
        if !apps.isEmpty {
            out.append("## Apps (nach Fenster bzw. Dokument)")
            out.append("")
            for (app, segs) in Dictionary(grouping: apps, by: \.segment.app).sorted(by: { total($0.value) > total($1.value) }) {
                out.append("### \(app) – \(dur(total(segs)))")
                let windows = Dictionary(grouping: segs) { s in s.segment.path.map(home) ?? (s.segment.title.isEmpty ? "(ohne Titel)" : s.segment.title) }
                for (title, ws) in windows.sorted(by: { total($0.value) > total($1.value) }) where total(ws) >= 10 {
                    out.append("- \(title) · \(dur(total(ws))) · \(projectsLabel(ws, projectName))")
                }
                out.append("")
            }
        }

        // Timeline
        out.append("## Chronologischer Verlauf")
        out.append("")
        out.append("Aufeinanderfolgende Schnipsel im selben Fenster sind zusammengefasst; Wechsel unter 10 Sekunden sind weggelassen.")
        out.append("")
        for run in mergedRuns(counted) where run.duration >= 10 {
            let s = run.first.segment
            let what = s.isWeb ? "\(s.app) · \(s.domain ?? "") · \(s.displayTitle)" : "\(s.app)\(s.path.map { " · \(home($0))" } ?? (s.title.isEmpty ? "" : " · \(s.title)"))"
            out.append("- \(time(run.start))–\(time(run.end)) (\(dur(run.duration))) \(what) → \(projectName(run.first.projectId))")
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    struct Run {
        var first: AttributedSegment
        var start: Date
        var end: Date
        var duration: TimeInterval
    }

    /// Consecutive snippets in the same window (gap ≤ 60 s) become one line.
    static func mergedRuns(_ segs: [AttributedSegment]) -> [Run] {
        var out: [Run] = []
        for s in segs.sorted(by: { $0.segment.span.start < $1.segment.span.start }) {
            if var last = out.last, sameWindow(last.first.segment, s.segment), s.segment.span.start.timeIntervalSince(last.end) <= 60 {
                last.end = max(last.end, s.segment.span.end)
                last.duration += s.segment.duration
                out[out.count - 1] = last
            } else {
                out.append(Run(first: s, start: s.segment.span.start, end: s.segment.span.end, duration: s.segment.duration))
            }
        }
        return out
    }

    static func sameWindow(_ a: Segment, _ b: Segment) -> Bool {
        a.app == b.app && a.displayTitle == b.displayTitle && a.domain == b.domain && a.path == b.path
    }

    static func total(_ segs: [AttributedSegment]) -> TimeInterval { segs.reduce(0) { $0 + $1.segment.duration } }

    static func projectsLabel(_ segs: [AttributedSegment], _ name: (Int64?) -> String) -> String {
        let ids = Set(segs.map(\.projectId))
        return ids.count == 1 ? name(ids.first!) : ids.map(name).sorted().joined(separator: " / ")
    }

    /// Scheme, host and path only.
    public static func shortURL(_ url: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        return c.string ?? url
    }

    static func home(_ path: String) -> String {
        let h = NSHomeDirectory()
        return path.hasPrefix(h) ? "~" + path.dropFirst(h.count) : path
    }

    static func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "/") }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func dur(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        return m < 60 ? "\(m) min" : String(format: "%d:%02d h", m / 60, m % 60)
    }
}
