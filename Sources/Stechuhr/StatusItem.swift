import SwiftUI
import AppKit
import Combine
import StechuhrCore

/// Menu bar icon. Hovering opens the project panel (without taking focus), clicking toggles it.
@MainActor
final class StatusItemController: NSResponder, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var openedByHover = false
    private var hoverTimer: Timer?
    private var closeTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: MenuBarPanel(dismiss: { [weak self] in self?.close() }).environmentObject(model))
        // The popover follows the panel's size (e.g. more projects, running timer).
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = item.button {
            button.image = MenuBarIcon.image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.toolTip = "Stechuhr"
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: nil))
        }
        // Number of Claude Code sessions working right now next to the icon.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        let n = model.workingClaudeSessions.count
        item.button?.title = n > 0 ? " \(n)" : ""
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        closeTimer?.invalidate()
        guard !popover.isShown else { return }
        // Short delay so that merely passing over the menu bar does not open it.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.popover.isShown else { return }
                self.openedByHover = true
                self.show()
                self.watchMouseForClose()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
    }

    /// A hover-opened panel closes again when the mouse is neither over the icon nor the panel for a moment.
    private func watchMouseForClose() {
        closeTimer?.invalidate()
        var outsideSince: Date?
        closeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown, self.openedByHover else { timer.invalidate(); return }
                let mouse = NSEvent.mouseLocation
                let overPanel = self.popover.contentViewController?.view.window?.frame.insetBy(dx: -8, dy: -8).contains(mouse) ?? false
                let overIcon = self.item.button?.window?.frame.contains(mouse) ?? false
                if overPanel || overIcon {
                    outsideSince = nil
                } else if let since = outsideSince {
                    if Date().timeIntervalSince(since) > 0.6 { self.close() }
                } else {
                    outsideSince = Date()
                }
            }
        }
    }

    // MARK: Click

    @objc private func clicked() {
        hoverTimer?.invalidate()
        if popover.isShown && !openedByHover {
            close()
            return
        }
        // A click "pins" the panel: it no longer closes on mouse-out, and typing works.
        openedByHover = false
        closeTimer?.invalidate()
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { show() }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func show() {
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        closeTimer?.invalidate()
        popover.performClose(nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            openedByHover = false
            closeTimer?.invalidate()
        }
    }
}

/// The main window (day view, evaluation, settings), opened from the menu bar panel.
@MainActor
final class MainWindow {
    static let shared = MainWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: ContentView().environmentObject(model).frame(minWidth: 980, minHeight: 640))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Stechuhr"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 1200, height: 800))
            w.setFrameAutosaveName("StechuhrMain")
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
