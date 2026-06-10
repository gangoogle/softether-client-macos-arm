import AppKit

// MARK: - Status bar state

enum StatusBarState {
    case disconnected
    case connecting
    case connected
    case error
}

// MARK: - Delegate

protocol StatusBarDelegate: AnyObject {
    func statusBarDidToggle()
}

// MARK: - Controller

final class StatusBarController {

    let statusItem: NSStatusItem
    weak var delegate: StatusBarDelegate?

    var state: StatusBarState = .disconnected {
        didSet { updateIcon() }
    }

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.title = ""
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.isHidden = false
        }

        updateIcon()
    }

    // MARK: - Icon drawing

    private func updateIcon() {
        statusItem.button?.image = icon(for: state)
    }

    /// Returns a template image for the menu bar.
    /// Uses SF Symbols (reliable, always visible) with a bitmap fallback.
    private func icon(for state: StatusBarState) -> NSImage {
        let symbolName: String
        switch state {
        case .disconnected: symbolName = "lock.shield"
        case .connecting:   symbolName = "arrow.triangle.2.circlepath"
        case .connected:    symbolName = "lock.shield.fill"
        case .error:        symbolName = "exclamationmark.shield.fill"
        }

        if let raw = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            // Configure for menu bar size (~16 pt within the 22 pt squareLength area).
            let cfg = NSImage.SymbolConfiguration(pointSize: NSStatusBar.system.thickness - 6,
                                                   weight: .regular)
            if let sized = raw.withSymbolConfiguration(cfg) {
                sized.isTemplate = true
                return sized
            }
            raw.isTemplate = true
            return raw
        }

        // Fallback: simple coloured circle (should never be reached on macOS 11+)
        return fallbackIcon(for: state)
    }

    private func fallbackIcon(for state: StatusBarState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(
            size: size,
            flipped: false
        ) { _ in
            let color: NSColor = {
                switch state {
                case .disconnected: return NSColor.systemGray
                case .connecting:   return NSColor.systemOrange
                case .connected:    return NSColor.systemGreen
                case .error:        return NSColor.systemRed
                }
            }()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: - Action

    @objc private func toggle() {
        delegate?.statusBarDidToggle()
    }
}
