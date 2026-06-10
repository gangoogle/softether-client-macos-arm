import AppKit

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Manages the custom NSPanel that appears below the menu bar status item.
final class PanelController: NSObject {

    private(set) var panel: NSPanel!
    var isVisible: Bool { panel.isVisible }

    private let contentViewController: PanelContentViewController

    init(contentViewController: PanelContentViewController) {
        self.contentViewController = contentViewController
        super.init()
        buildPanel()
        observeAppEvents()
    }

    // MARK: - Panel setup

    private func buildPanel() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 610),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.title = "SoftEther VPN"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = false
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // Minimum size
        panel.contentMinSize = NSSize(width: 340, height: 400)

        // Set content
        panel.contentViewController = contentViewController
    }

    // MARK: - Show / Hide

    func show(relativeTo statusItem: NSStatusItem) {
        positionPanel(relativeTo: statusItem)

        // Text editing commands such as Cmd+V need the LSUIElement app to be
        // active and the panel to be key, otherwise AppKit's responder chain is
        // incomplete for NSTextField's field editor.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        if let first = contentViewController.initialFirstResponder {
            panel.initialFirstResponder = first
            panel.makeFirstResponder(first)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle(relativeTo statusItem: NSStatusItem) {
        if panel.isVisible {
            hide()
        } else {
            show(relativeTo: statusItem)
        }
    }

    private func positionPanel(relativeTo statusItem: NSStatusItem) {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonFrame = button.frame
        let screenRect = buttonWindow.convertToScreen(buttonFrame)

        var panelFrame = panel.frame
        let panelWidth = panelFrame.width

        // Center panel under the status item horizontally
        let originX = screenRect.midX - panelWidth / 2

        // Clamp to screen edges
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let clampedX = max(visibleFrame.minX + 10,
                               min(originX, visibleFrame.maxX - panelWidth - 10))
            let topY = screenRect.minY - panelFrame.height - 4

            panelFrame.origin = NSPoint(x: clampedX, y: max(topY, visibleFrame.minY + 10))
        } else {
            panelFrame.origin = NSPoint(x: originX,
                                        y: screenRect.minY - panelFrame.height - 4)
        }

        panel.setFrame(panelFrame, display: false)
    }

    // MARK: - App resign active → hide

    private func observeAppEvents() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func appDidResignActive() {
        // Only auto-hide when the user clicks outside the app.
        // The status-item toggle already handles the case where
        // the user clicks the status item while the panel is open.
        if panel.isVisible {
            hide()
        }
    }
}
