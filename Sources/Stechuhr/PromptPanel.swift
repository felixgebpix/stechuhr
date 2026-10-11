import SwiftUI
import AppKit
import StechuhrCore

/// Small floating panel under the menu bar: "Woran arbeitest du gerade?".
/// Does not activate Stechuhr or steal focus from the app you are working in.
@MainActor
final class PromptPanel {
    static let shared = PromptPanel()

    private var panel: NSPanel?
    private var timeout: Timer?

    final class Panel: NSPanel {
        // Needed for the note field; still does not activate the app.
        override var canBecomeKey: Bool { true }
    }

    func show(model: AppModel) {
        hide()
        let view = PromptView().environmentObject(model)
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)

        let p = Panel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = hosting

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - hosting.fittingSize.width - 12, y: f.maxY - hosting.fittingSize.height - 8))
        }
        p.orderFrontRegardless()
        panel = p

        // Unanswered questions disappear after 2 minutes and count as "Später".
        timeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak model] _ in
            Task { @MainActor in model?.answerLater() }
        }
    }

    func hide() {
        timeout?.invalidate()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct PromptView: View {
    @EnvironmentObject var model: AppModel
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(nsImage: MenuBarIcon.image).renderingMode(.template)
                Text(heading).font(.headline)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            let candidates = (model.prompt?.candidates ?? []).compactMap { model.project($0) }
            VStack(spacing: 4) {
                ForEach(candidates) { p in
                    projectButton(p)
                }
                let others = model.activeProjects.filter { p in !candidates.contains { $0.id == p.id } }
                if !others.isEmpty {
                    Menu(candidates.isEmpty ? "Projekt wählen …" : "Anderes Projekt …") {
                        ForEach(others) { p in Button(p.name) { model.answer(project: p.id, note: note) } }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
            }

            if case .away = model.prompt {
                TextField("Notiz, z. B. Besprechung", text: $note).textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(isAway ? "Pause / Privat" : "Privat / Pause") { model.answerPrivate() }
                Spacer()
                Button("Später") { model.answerLater() }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    private func projectButton(_ p: Project) -> some View {
        Button { model.answer(project: p.id, note: note) } label: {
            HStack {
                Circle().fill(Color(hex: p.colorHex)).frame(width: 10, height: 10)
                Text(p.name)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(Color(hex: p.colorHex).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var isAway: Bool {
        if case .away = model.prompt { return true }
        return false
    }

    private var heading: String { isAway ? "Willkommen zurück" : "Woran arbeitest du gerade?" }

    private var detail: String {
        switch model.prompt {
        case .unclear(let since, _):
            return "Seit \(Fmt.time(since)) erkennt Stechuhr kein eindeutiges Projekt. Deine Antwort gilt ab dann und läuft weiter, bis du sichtbar an etwas anderem arbeitest."
        case .away(let span, _):
            return "Du warst \(Fmt.time(span.start))–\(Fmt.time(span.end)) weg (\(Fmt.duration(span.duration))). Für welches Projekt war das, z. B. eine Besprechung oder ein Telefonat?"
        case nil:
            return ""
        }
    }
}
