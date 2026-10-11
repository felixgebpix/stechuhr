import Foundation

/// Sums of several days (week, month) per project.
public enum RangeReport {
    public static func aggregate(_ days: [DayReport]) -> [ProjectDayStats] {
        var byProject: [Int64?: ProjectDayStats] = [:]
        for d in days {
            for s in d.stats {
                var a = byProject[s.projectId] ?? ProjectDayStats(projectId: s.projectId)
                a.foreground += s.foreground
                a.confirmed += s.confirmed
                a.manualBackground += s.manualBackground
                a.claude += s.claude
                a.background += s.background
                a.overlap += s.overlap
                a.claudeParallel += s.claudeParallel
                a.claudeInteractive += s.claudeInteractive
                a.billable += s.billable
                a.blockCount += s.blockCount
                a.longestBlock = max(a.longestBlock, s.longestBlock)
                byProject[s.projectId] = a
            }
        }
        return byProject.values.sorted { a, b in
            if (a.projectId == nil) != (b.projectId == nil) { return b.projectId == nil }
            return a.billable != b.billable ? a.billable > b.billable : a.trackSum > b.trackSum
        }
    }
}

/// CSV for Excel/Numbers in German locale: semicolon separator, decimal comma, hours as decimal numbers.
public enum CSVExport {
    public static func hours(_ t: TimeInterval) -> String {
        String(format: "%.2f", t / 3600).replacingOccurrences(of: ".", with: ",")
    }

    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ fields: [String]) -> String { fields.map(field).joined(separator: ";") }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// One row per day and project.
    public static func projectDays(_ days: [DayReport], name: (Int64?) -> String) -> String {
        var rows = [line(["Datum", "Projekt", "Vordergrund (h)", "davon bestätigt (h)", "Hintergrund manuell (h)",
                          "Claude Code (h)", "Überlappung (h)", "Abrechenbar (h)", "Arbeitsblöcke", "Längster Block (h)"])]
        for d in days {
            for s in d.stats where s.trackSum >= 30 {
                rows.append(line([date(d.day.start), name(s.projectId), hours(s.foreground), hours(s.confirmed),
                                  hours(s.manualBackground), hours(s.claude), hours(s.overlap), hours(s.billable),
                                  String(s.blockCount), hours(s.longestBlock)]))
            }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// Confirmed time entries and manual background tasks, one row each.
    public static func entries(_ days: [DayReport], name: (Int64?) -> String) -> String {
        var rows = [line(["Datum", "Von", "Bis", "Dauer (h)", "Projekt", "Art", "Titel / Notiz"])]
        for d in days {
            let items = d.entries.map { ($0.span, $0.projectId, "Zeiteintrag", $0.title) }
                + d.manualTasks.map { ($0.span, $0.projectId, "Hintergrund", $0.note) }
            for (span, pid, kind, text) in items.sorted(by: { $0.0.start < $1.0.start }) {
                rows.append(line([date(span.start), time(span.start), time(span.end), hours(span.duration), name(pid), kind, text]))
            }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
