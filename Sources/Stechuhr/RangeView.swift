import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StechuhrCore

/// Week / month / custom range: sums per project and CSV export for billing.
struct RangeView: View {
    @EnvironmentObject var model: AppModel

    enum Period: String, CaseIterable, Identifiable {
        case thisWeek = "Diese Woche", lastWeek = "Letzte Woche", thisMonth = "Dieser Monat", lastMonth = "Letzter Monat", custom = "Zeitraum"
        var id: String { rawValue }
    }

    @State private var period: Period = .thisWeek
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
    @State private var customTo = Date()
    @State private var days: [DayReport] = []
    @State private var loading = false

    var body: some View {
        let stats = RangeReport.aggregate(days)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if period == .custom {
                    DatePicker("", selection: $customFrom, displayedComponents: .date).labelsHidden()
                    Text("bis")
                    DatePicker("", selection: $customTo, displayedComponents: .date).labelsHidden()
                }
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Menu {
                    Button("Projekte pro Tag …") { export(CSVExport.projectDays(days, name: name), suffix: "Projekte") }
                    Button("Zeiteinträge und Hintergrundaufgaben …") { export(CSVExport.entries(days, name: name), suffix: "Zeiteinträge") }
                } label: {
                    Label("CSV exportieren", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .disabled(days.isEmpty)
            }
            .padding(10)
            Text(rangeLabel).font(.headline).padding(.horizontal, 10)

            Table(stats) {
                TableColumn("Projekt") { s in
                    HStack(spacing: 6) {
                        Circle().fill(model.project(s.projectId).map { Color(hex: $0.colorHex) } ?? .gray).frame(width: 9, height: 9)
                        Text(name(s.projectId)).foregroundStyle(s.projectId == nil ? .secondary : .primary)
                    }
                }
                .width(min: 140, ideal: 180)
                TableColumn("Ich (Vordergrund)") { s in dur(s.foreground) }
                TableColumn("davon bestätigt") { s in dur(s.confirmed) }
                TableColumn("Hintergrund manuell") { s in dur(s.manualBackground) }
                TableColumn("Claude Code") { s in dur(s.claude) }
                TableColumn("Überlappung") { s in dur(s.overlap) }
                TableColumn("Abrechenbar") { s in dur(s.billable).fontWeight(.semibold) }
                TableColumn("Blöcke") { s in Text(s.blockCount == 0 ? "–" : "\(s.blockCount)").monospacedDigit() }
                    .width(50)
            }
            Divider()
            HStack(spacing: 28) {
                total("Abrechenbar", stats.reduce(0) { $0 + $1.billable })
                total("Vordergrund", stats.reduce(0) { $0 + $1.foreground })
                total("davon bestätigt", stats.reduce(0) { $0 + $1.confirmed })
                total("Nicht zugeordnet", stats.first { $0.projectId == nil }?.foreground ?? 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tage mit Aktivität").font(.caption).foregroundStyle(.secondary)
                    Text("\(days.filter { $0.wallClock > 60 }.count)").font(.title3).monospacedDigit()
                }
            }
            .padding(10)
        }
        .navigationTitle("Auswertung")
        .task(id: "\(period.rawValue)-\(customFrom.timeIntervalSince1970)-\(customTo.timeIntervalSince1970)") { await load() }
    }

    private var range: (Date, Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch period {
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: today)!.start
            return (start, today)
        case .lastWeek:
            let start = cal.date(byAdding: .weekOfYear, value: -1, to: cal.dateInterval(of: .weekOfYear, for: today)!.start)!
            return (start, cal.date(byAdding: .day, value: 6, to: start)!)
        case .thisMonth:
            return (cal.dateInterval(of: .month, for: today)!.start, today)
        case .lastMonth:
            let start = cal.date(byAdding: .month, value: -1, to: cal.dateInterval(of: .month, for: today)!.start)!
            return (start, cal.date(byAdding: .day, value: -1, to: cal.dateInterval(of: .month, for: today)!.start)!)
        case .custom:
            return (cal.startOfDay(for: min(customFrom, customTo)), cal.startOfDay(for: max(customFrom, customTo)))
        }
    }

    private var rangeLabel: String {
        let (a, b) = range
        return "\(a.formatted(date: .abbreviated, time: .omitted)) – \(b.formatted(date: .abbreviated, time: .omitted))"
    }

    private func load() async {
        loading = true
        let (a, b) = range
        days = await model.reports(from: a, to: b)
        loading = false
    }

    private func name(_ id: Int64?) -> String {
        id == nil ? "nicht zugeordnet" : (model.project(id)?.name ?? "–")
    }

    private func dur(_ t: TimeInterval) -> Text {
        t < 30 ? Text("–").foregroundColor(.secondary) : Text(Fmt.duration(t)).monospacedDigit()
    }

    private func total(_ label: String, _ t: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.duration(t)).font(.title3).monospacedDigit()
        }
    }

    private func export(_ csv: String, suffix: String) {
        let (a, b) = range
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Stechuhr \(suffix) \(f.string(from: a)) bis \(f.string(from: b)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // BOM so that Excel opens umlauts correctly.
        try? (Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8)).write(to: url)
    }
}
