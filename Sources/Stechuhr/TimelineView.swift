import SwiftUI
import AppKit
import StechuhrCore

/// Day timeline: one foreground lane ("Ich") plus parallel background lanes
/// (manual background tasks and one lane per Claude Code session).
struct DayTimeline: View {
    @EnvironmentObject var model: AppModel
    let report: DayReport
    var onEditTask: (BackgroundEntry) -> Void

    @State private var zoom: CGFloat = 1
    @State private var hover: String?
    @State private var anchorKey: String?

    static let laneHeight: CGFloat = 26
    static let laneGap: CGFloat = 6
    static let labelWidth: CGFloat = 150
    static let axisHeight: CGFloat = 18

    var body: some View {
        let layout = TimelineLayout(report: report, now: Date(), isToday: model.isToday)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Self.laneGap) {
                    Color.clear.frame(height: Self.axisHeight - Self.laneGap)
                    ForEach(layout.lanes) { lane in
                        HStack(spacing: 4) {
                            Image(systemName: lane.icon).foregroundStyle(.secondary).frame(width: 14)
                            Text(lane.title).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.caption)
                        .frame(width: Self.labelWidth - 8, height: Self.laneHeight, alignment: .leading)
                        .help(lane.help)
                    }
                }
                .padding(.leading, 8)

                GeometryReader { geo in
                    ScrollView(.horizontal) {
                        canvas(layout: layout, width: max(geo.size.width, geo.size.width * zoom))
                    }
                }
                .frame(height: layout.height)
            }
            HStack {
                Text(hover ?? "Klick wählt aus · ⌘-Klick ergänzt · ⇧-Klick wählt einen Bereich")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...8).frame(width: 120)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }
    }

    private func canvas(layout: TimelineLayout, width: CGFloat) -> some View {
        let items = layout.items(width: width)
        return Canvas { ctx, size in
            // Hour grid
            for (x, label) in layout.hourMarks(width: width) {
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: Self.axisHeight - 4)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                ctx.draw(Text(label).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x + 2, y: 2), anchor: .topLeading)
            }
            for item in items {
                switch item.kind {
                case .sessionOpen:
                    let r = item.rect.insetBy(dx: 0, dy: item.rect.height / 2 - 1)
                    ctx.fill(Path(r), with: .color(.secondary.opacity(0.35)))
                default:
                    let path = Path(roundedRect: item.rect, cornerRadius: 3)
                    ctx.fill(path, with: .color(color(for: item)))
                    if case .segment(let key) = item.kind, model.selection.contains(key) {
                        ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    }
                    if item.rect.width > 60, let label = item.label {
                        ctx.draw(Text(label).font(.caption2).foregroundColor(.white),
                                 in: item.rect.insetBy(dx: 4, dy: 5))
                    }
                }
            }
            if let x = layout.nowX(width: width) {
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: Self.axisHeight - 4)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.red.opacity(0.7)), lineWidth: 1)
            }
        }
        .frame(width: width, height: layout.height)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in tap(at: value.location, items: items) })
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = items.last { $0.rect.insetBy(dx: -1, dy: 0).contains(p) && $0.kind != .sessionOpen }?.tooltip
            case .ended: hover = nil
            }
        }
    }

    private func color(for item: TimelineItem) -> Color {
        if item.ignored { return .secondary.opacity(0.25) }
        if model.colorByProject || item.kind != .segment(item.key) {
            if let p = model.project(item.projectId) { return Color(hex: p.colorHex) }
            return .gray.opacity(0.55)
        }
        return Color.forName(item.app)
    }

    private func tap(at p: CGPoint, items: [TimelineItem]) {
        guard let hit = items.last(where: { $0.rect.insetBy(dx: -1, dy: 0).contains(p) && $0.kind != .sessionOpen }) else {
            if !NSEvent.modifierFlags.contains(.command) { model.selection = [] }
            return
        }
        switch hit.kind {
        case .segment(let key):
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift), let anchor = anchorKey, let a = report.segments.first(where: { $0.id == anchor }) {
                let lo = min(a.segment.span.start, hit.start), hi = max(a.segment.span.end, hit.end)
                let range = report.segments.filter { $0.segment.span.start >= lo && $0.segment.span.end <= hi }.map(\.id)
                model.selection.formUnion(range)
            } else if flags.contains(.command) {
                if model.selection.contains(key) { model.selection.remove(key) } else { model.selection.insert(key) }
                anchorKey = key
            } else {
                model.selection = [key]
                anchorKey = key
            }
        case .manual(let id):
            if let task = report.manualTasks.first(where: { $0.id == id }) { onEditTask(task) }
        default:
            break
        }
    }
}

struct TimelineLane: Identifiable {
    var id: String
    var title: String
    var icon: String
    var help: String
}

enum TimelineItemKind: Hashable {
    case segment(String), manual(Int64), claude, sessionOpen
}

struct TimelineItem {
    var kind: TimelineItemKind
    var rect: CGRect
    var start: Date
    var end: Date
    var projectId: Int64?
    var app: String = ""
    var label: String?
    var tooltip: String
    var ignored = false

    var key: String {
        if case .segment(let k) = kind { return k }
        return ""
    }
}

struct TimelineLayout {
    let report: DayReport
    let range: TimeSpan
    let lanes: [TimelineLane]
    private let manualLane: [Int64: Int]
    private let sessionLane: [String: Int]
    private let now: Date
    private let isToday: Bool

    init(report: DayReport, now: Date, isToday: Bool) {
        self.report = report
        self.now = now
        self.isToday = isToday
        let cal = Calendar.current
        var starts = report.segments.map(\.segment.span.start) + report.manualTasks.map(\.span.start) + report.claudeSpans.map(\.span.start)
        var ends = report.segments.map(\.segment.span.end) + report.manualTasks.map(\.span.end) + report.claudeSpans.map(\.span.end)
        if isToday { starts.append(now); ends.append(now) }
        let dayStart = report.day.start
        var lo = starts.min() ?? dayStart.addingTimeInterval(8 * 3600)
        var hi = ends.max() ?? dayStart.addingTimeInterval(18 * 3600)
        lo = cal.dateInterval(of: .hour, for: lo)?.start ?? lo
        hi = cal.dateInterval(of: .hour, for: hi.addingTimeInterval(-1))?.end ?? hi
        if hi.timeIntervalSince(lo) < 4 * 3600 { hi = min(report.day.end, lo.addingTimeInterval(4 * 3600)) }
        range = TimeSpan(max(lo, report.day.start), min(hi, report.day.end))

        var lanes = [TimelineLane(id: "fg", title: "Ich (Vordergrund)", icon: "person.fill", help: "Aktive Fenster aus der Vordergrund-Erfassung")]
        // Pack manual background tasks into as few lanes as possible.
        var laneEnds: [Date] = []
        var manualLane: [Int64: Int] = [:]
        for t in report.manualTasks.sorted(by: { $0.span.start < $1.span.start }) {
            if let i = laneEnds.firstIndex(where: { $0 <= t.span.start }) {
                manualLane[t.id] = i
                laneEnds[i] = t.span.end
            } else {
                manualLane[t.id] = laneEnds.count
                laneEnds.append(t.span.end)
            }
        }
        for i in laneEnds.indices {
            lanes.append(TimelineLane(id: "manual\(i)", title: "Hintergrund", icon: "square.stack.3d.down.right", help: "Manuell markierte Hintergrundaufgaben"))
        }
        var sessionLane: [String: Int] = [:]
        for run in report.runs where !run.work.isEmpty {
            sessionLane[run.sessionId] = lanes.count
            lanes.append(TimelineLane(id: "cc-\(run.sessionId)", title: "Claude · \(run.title ?? run.folderName)",
                                      icon: "sparkles", help: "\(run.cwd)\nSession \(run.sessionId)"))
        }
        self.manualLane = manualLane.mapValues { $0 + 1 }
        self.sessionLane = sessionLane
        self.lanes = lanes
    }

    var height: CGFloat {
        DayTimeline.axisHeight + CGFloat(lanes.count) * (DayTimeline.laneHeight + DayTimeline.laneGap)
    }

    private func x(_ d: Date, _ width: CGFloat) -> CGFloat {
        CGFloat(d.timeIntervalSince(range.start) / max(range.duration, 1)) * width
    }

    private func laneRect(_ lane: Int, _ a: Date, _ b: Date, _ width: CGFloat) -> CGRect {
        let y = DayTimeline.axisHeight + CGFloat(lane) * (DayTimeline.laneHeight + DayTimeline.laneGap)
        let x0 = x(a, width), x1 = x(b, width)
        return CGRect(x: x0, y: y, width: max(1.5, x1 - x0), height: DayTimeline.laneHeight)
    }

    func hourMarks(width: CGFloat) -> [(CGFloat, String)] {
        var out: [(CGFloat, String)] = []
        var t = range.start
        let step: TimeInterval = width / CGFloat(range.duration / 3600) < 40 ? 7200 : 3600
        while t <= range.end {
            out.append((x(t, width), t.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())))
            t = t.addingTimeInterval(step)
        }
        return out
    }

    func nowX(width: CGFloat) -> CGFloat? {
        guard isToday, now >= range.start, now <= range.end else { return nil }
        return x(now, width)
    }

    func items(width: CGFloat) -> [TimelineItem] {
        var out: [TimelineItem] = []
        for s in report.segments {
            let seg = s.segment
            let what = seg.isWeb ? "\(seg.app) · \(seg.domain ?? "") · \(seg.displayTitle)" : "\(seg.app) · \(seg.title)"
            let note = s.source == .ignoredNoise ? " (Rauschen, ignoriert)" : s.source == .absorbedNoise ? " (kurzer Wechsel, eingerechnet)" : ""
            out.append(TimelineItem(kind: .segment(seg.key), rect: laneRect(0, seg.span.start, seg.span.end, width),
                                    start: seg.span.start, end: seg.span.end, projectId: s.projectId, app: seg.app,
                                    label: seg.app,
                                    tooltip: "\(Fmt.time(seg.span.start))–\(Fmt.time(seg.span.end)) · \(Fmt.duration(seg.duration)) · \(what)\(note)",
                                    ignored: s.source == .ignoredNoise))
        }
        for t in report.manualTasks {
            let lane = manualLane[t.id] ?? 1
            out.append(TimelineItem(kind: .manual(t.id), rect: laneRect(lane, t.span.start, t.span.end, width),
                                    start: t.span.start, end: t.span.end, projectId: t.projectId,
                                    label: t.note.isEmpty ? "Hintergrund" : t.note,
                                    tooltip: "Hintergrund \(Fmt.time(t.span.start))–\(Fmt.time(t.span.end)) · \(Fmt.duration(t.span.duration))\(t.note.isEmpty ? "" : " · \(t.note)") – Klick zum Bearbeiten"))
        }
        for run in report.runs {
            guard let lane = sessionLane[run.sessionId] else { continue }
            out.append(TimelineItem(kind: .sessionOpen, rect: laneRect(lane, run.sessionSpan.start, run.sessionSpan.end, width),
                                    start: run.sessionSpan.start, end: run.sessionSpan.end, tooltip: ""))
        }
        for c in report.claudeSpans {
            guard let lane = sessionLane[c.sessionId] else { continue }
            out.append(TimelineItem(kind: .claude, rect: laneRect(lane, c.span.start, c.span.end, width),
                                    start: c.span.start, end: c.span.end, projectId: c.projectId,
                                    label: c.isOpen ? "arbeitet…" : nil,
                                    tooltip: "Claude Code arbeitet \(Fmt.time(c.span.start))–\(c.isOpen ? "jetzt" : Fmt.time(c.span.end)) · \(Fmt.duration(c.span.duration)) · \(c.cwd)\(c.projectId == nil ? " · Ordner nicht zugeordnet" : "")"))
        }
        return out
    }
}
