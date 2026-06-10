import AppKit

private class EditingTextField: NSTextField, NSMenuItemValidation {
    func activeEditor() -> NSTextView? {
        window?.fieldEditor(false, for: self) as? NSTextView
    }

    @objc func pasteText(_ sender: Any?) {
        if let editor = activeEditor() {
            editor.paste(sender)
            return
        }

        if let value = NSPasteboard.general.string(forType: .string) {
            stringValue += value
        }
    }

    @objc func cutText(_ sender: Any?) {
        activeEditor()?.cut(sender)
    }

    @objc func copyText(_ sender: Any?) {
        activeEditor()?.copy(sender)
    }

    @objc func deleteText(_ sender: Any?) {
        activeEditor()?.delete(sender)
    }

    @objc func selectAllText(_ sender: Any?) {
        if let editor = activeEditor() {
            editor.selectAll(sender)
        } else {
            currentEditor()?.selectAll(sender)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(pasteText(_:)):
            return isEditable
        case #selector(cutText(_:)), #selector(deleteText(_:)):
            return isEditable && selectedRange.length > 0
        case #selector(copyText(_:)):
            return selectedRange.length > 0
        case #selector(selectAllText(_:)):
            return isSelectable && !stringValue.isEmpty
        default:
            return true
        }
    }

    private var selectedRange: NSRange {
        activeEditor()?.selectedRange() ?? NSRange(location: 0, length: 0)
    }
}

private final class EditingSecureTextField: NSSecureTextField, NSMenuItemValidation {
    private func activeEditor() -> NSTextView? {
        window?.fieldEditor(false, for: self) as? NSTextView
    }

    @objc func pasteText(_ sender: Any?) {
        if let editor = activeEditor() {
            editor.paste(sender)
            return
        }

        if let value = NSPasteboard.general.string(forType: .string) {
            stringValue += value
        }
    }

    @objc func cutText(_ sender: Any?) {
        activeEditor()?.cut(sender)
    }

    @objc func copyText(_ sender: Any?) {
        activeEditor()?.copy(sender)
    }

    @objc func deleteText(_ sender: Any?) {
        activeEditor()?.delete(sender)
    }

    @objc func selectAllText(_ sender: Any?) {
        if let editor = activeEditor() {
            editor.selectAll(sender)
        } else {
            currentEditor()?.selectAll(sender)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(pasteText(_:)):
            return isEditable
        case #selector(cutText(_:)), #selector(deleteText(_:)):
            return isEditable && selectedRange.length > 0
        case #selector(copyText(_:)):
            return selectedRange.length > 0
        case #selector(selectAllText(_:)):
            return isSelectable && !stringValue.isEmpty
        default:
            return true
        }
    }

    private var selectedRange: NSRange {
        activeEditor()?.selectedRange() ?? NSRange(location: 0, length: 0)
    }
}

// MARK: - Delegate

protocol PanelContentDelegate: AnyObject {
    func panelDidRequestStartService()
    func panelDidRequestStopService()
    func panelDidRequestConnect()
    func panelDidRequestDisconnect()
    func panelDidRequestSave(host: String, port: String, username: String,
                             hub: String, account: String, password: String)
    func panelDidRequestClearLogs()
    func panelDidRequestOpenLogs()
    func panelDidRequestRevealRuntime()
    func panelDidRequestImportEnv()
}

// MARK: - View Controller

final class PanelContentViewController: NSViewController {

    weak var delegate: PanelContentDelegate?

    /// Current log content as a plain string.
    var logContent: String { logTextView.string }

    /// First text field that should receive initial focus.
    var initialFirstResponder: NSView? { hostField }

    // MARK: - Status labels
    private let serviceStatusField = NSTextField(labelWithString: "● Unknown")
    private let vpnStatusField      = NSTextField(labelWithString: "● Unknown")

    // MARK: - Config fields
    private let hostField      = EditingTextField()
    private let portField      = EditingTextField()
    private let usernameField  = EditingTextField()
    private let hubField       = EditingTextField()
    private let accountField   = EditingTextField()
    private let passwordField  = EditingSecureTextField()

    // MARK: - Action buttons
    private let startBtn   = NSButton(title: "Start Service", target: nil, action: nil)
    private let stopBtn    = NSButton(title: "Stop Service",  target: nil, action: nil)
    private let connectBtn = NSButton(title: "Connect",       target: nil, action: nil)
    private let disconnectBtn = NSButton(title: "Disconnect", target: nil, action: nil)
    private let saveBtn    = NSButton(title: "Save Config",   target: nil, action: nil)

    // MARK: - Log
    private let logTextView = NSTextView()
    private let logScrollView = NSScrollView()

    // MARK: - Constraints to update dynamically
    private var logHeightConstraint: NSLayoutConstraint!

    // MARK: - Lifecycle

    override func viewDidAppear() {
        super.viewDidAppear()
        // Delay focus: the panel is floating and the app may not be active yet.
        // The user clicking the panel will auto-activate the app (macOS default),
        // at which point Cmd+V and other shortcuts work naturally.
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.hostField)
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 610))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = root

        buildUI(in: root)
    }

    // MARK: - Build UI

    private func buildUI(in root: NSView) {
        // Main vertical stack — .width alignment makes children fill horizontally
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        // ---- Status section ----
        let statusHeader = sectionLabel("Status")
        stack.addArrangedSubview(statusHeader)

        serviceStatusField.font = .systemFont(ofSize: 12)
        serviceStatusField.textColor = .secondaryLabelColor
        stack.addArrangedSubview(serviceStatusField)

        vpnStatusField.font = .systemFont(ofSize: 12)
        vpnStatusField.textColor = .secondaryLabelColor
        stack.addArrangedSubview(vpnStatusField)

        stack.setCustomSpacing(10, after: vpnStatusField)
        stack.addArrangedSubview(thinSeparator())
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // ---- Actions section ----
        let actionsHeader = sectionLabel("Actions")
        stack.addArrangedSubview(actionsHeader)

        let row1 = NSStackView(views: [startBtn, stopBtn])
        row1.orientation = .horizontal
        row1.distribution = .fillEqually
        row1.spacing = 8
        row1.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row1)

        let row2 = NSStackView(views: [connectBtn, disconnectBtn])
        row2.orientation = .horizontal
        row2.distribution = .fillEqually
        row2.spacing = 8
        row2.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row2)

        for row in [row1, row2] {
            row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }

        styleActionButton(startBtn, style: .primary)
        styleActionButton(stopBtn, style: .secondary)
        styleActionButton(connectBtn, style: .primary)
        styleActionButton(disconnectBtn, style: .secondary)

        startBtn.target = self
        startBtn.action = #selector(startTapped)
        stopBtn.target = self
        stopBtn.action = #selector(stopTapped)
        connectBtn.target = self
        connectBtn.action = #selector(connectTapped)
        disconnectBtn.target = self
        disconnectBtn.action = #selector(disconnectTapped)

        stack.setCustomSpacing(10, after: row2)
        stack.addArrangedSubview(thinSeparator())
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // ---- Configuration section ----
        let configHeader = sectionLabel("Configuration")
        stack.addArrangedSubview(configHeader)

        // Build form rows
        for (label, field, _) in formFields() {
            let row = formRow(label: label, field: field)
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(6, after: row)
        }

        // Save + Import row
        let buttonRow = NSStackView(views: [saveBtn, NSView()])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.heightAnchor.constraint(equalToConstant: 26).isActive = true
        stack.addArrangedSubview(buttonRow)

        styleActionButton(saveBtn, style: .primary)
        saveBtn.target = self
        saveBtn.action = #selector(saveTapped)

        let importBtn = NSButton(title: "Import .env", target: self,
                                 action: #selector(importEnvTapped))
        importBtn.bezelStyle = .roundRect
        importBtn.controlSize = .small
        stack.addArrangedSubview(importBtn)

        stack.setCustomSpacing(10, after: importBtn)
        stack.addArrangedSubview(thinSeparator())
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // ---- Quit button ----
        let quitRow = NSStackView()
        quitRow.orientation = .horizontal
        quitRow.distribution = .equalSpacing
        quitRow.translatesAutoresizingMaskIntoConstraints = false
        quitRow.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let quitBtn = NSButton(title: "Quit", target: nil, action: nil)
        quitBtn.bezelStyle = .roundRect
        quitBtn.controlSize = .small
        quitBtn.font = .systemFont(ofSize: 11)
        quitBtn.target = self
        quitBtn.action = #selector(quitTapped)

        quitRow.addArrangedSubview(NSView()) // spacer
        quitRow.addArrangedSubview(quitBtn)
        stack.addArrangedSubview(quitRow)

        // ---- Log section ----
        let logHeaderRow = NSStackView()
        logHeaderRow.orientation = .horizontal
        logHeaderRow.distribution = .equalSpacing
        logHeaderRow.addArrangedSubview(sectionLabel("Log"))
        let utilRow = NSStackView()
        utilRow.orientation = .horizontal
        utilRow.spacing = 8
        for (title, sel) in [("Clear", #selector(clearLogsTapped)),
                             ("Open Logs", #selector(openLogsTapped)),
                             ("Reveal Runtime", #selector(revealRuntimeTapped))] {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .roundRect
            b.controlSize = .small
            b.font = .systemFont(ofSize: 10)
            utilRow.addArrangedSubview(b)
        }
        logHeaderRow.addArrangedSubview(utilRow)
        stack.addArrangedSubview(logHeaderRow)

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.backgroundColor = .textBackgroundColor
        logTextView.textContainerInset = NSSize(width: 4, height: 4)
        logTextView.drawsBackground = true

        logScrollView.documentView = logTextView
        logScrollView.hasVerticalScroller = true
        logScrollView.autohidesScrollers = true
        logScrollView.borderType = .bezelBorder
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(logScrollView)

        logHeightConstraint = logScrollView.heightAnchor.constraint(equalToConstant: 140)
        logHeightConstraint.isActive = true
    }

    // MARK: - UI helpers

    private func sectionLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .boldSystemFont(ofSize: 13)
        f.textColor = .labelColor
        return f
    }

    private func thinSeparator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func formFields() -> [(String, NSControl, String)] {
        let fields: [NSTextField] = [hostField, portField, usernameField, hubField, accountField, passwordField]
        let placeholders = ["vpn.example.com", "443", "username", "DEFAULT", "vpn_conn", "password"]

        for (f, ph) in zip(fields, placeholders) {
            f.placeholderString = ph
            f.font = .systemFont(ofSize: 12)
            f.controlSize = .small
            f.isEditable = true
            f.isSelectable = true
            f.isBordered = true
            f.isBezeled = true
            f.focusRingType = .default
            f.menu = textEditingMenu(for: f)
        }

        return [
            ("Server:",   hostField,      "vpn.example.com"),
            ("Port:",     portField,      "443"),
            ("Username:", usernameField,  "username"),
            ("Hub:",      hubField,       "DEFAULT"),
            ("Account:",  accountField,   "vpn_conn"),
            ("Password:", passwordField,  "password"),
        ]
    }

    private func formRow(label: String, field: NSControl) -> NSStackView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 11)
        lbl.textColor = .secondaryLabelColor
        lbl.alignment = .right

        let row = NSStackView(views: [lbl, field])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func textEditingMenu(for field: NSTextField) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Cut", action: #selector(EditingTextField.cutText(_:)), target: field))
        menu.addItem(menuItem("Copy", action: #selector(EditingTextField.copyText(_:)), target: field))
        menu.addItem(menuItem("Paste", action: #selector(EditingTextField.pasteText(_:)), target: field))
        menu.addItem(menuItem("Delete", action: #selector(EditingTextField.deleteText(_:)), target: field))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("Select All", action: #selector(EditingTextField.selectAllText(_:)), target: field))
        return menu
    }

    private func menuItem(_ title: String, action: Selector, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }

    private enum ActionStyle { case primary, secondary }

    private func styleActionButton(_ btn: NSButton, style: ActionStyle) {
        btn.bezelStyle = .roundRect
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        if style == .primary {
            btn.keyEquivalent = ""
            if #available(macOS 12.0, *) {
                btn.bezelColor = .controlAccentColor
            }
        }
    }

    // MARK: - Public UI update methods

    func setServiceRunning(_ running: Bool) {
        serviceStatusField.stringValue = running
            ? "●  Service: Running"
            : "○  Service: Stopped"
        serviceStatusField.textColor = running
            ? NSColor.systemGreen
            : NSColor.secondaryLabelColor
    }

    func setVPNConnected(_ connected: Bool, detail: String = "") {
        vpnStatusField.stringValue = connected
            ? "●  VPN: Connected  \(detail)"
            : "○  VPN: Disconnected"
        vpnStatusField.textColor = connected
            ? NSColor.systemGreen
            : NSColor.secondaryLabelColor
    }

    func setConfig(host: String, port: String, username: String,
                   hub: String, account: String, password: String) {
        hostField.stringValue     = host
        portField.stringValue     = port
        usernameField.stringValue = username
        hubField.stringValue      = hub
        accountField.stringValue  = account
        passwordField.stringValue = password
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let current = self.logTextView.string
            self.logTextView.string = current + line
            // Keep only last 500 lines
            let lines = self.logTextView.string.split(separator: "\n",
                                                       omittingEmptySubsequences: false)
            if lines.count > 500 {
                self.logTextView.string = lines.suffix(500).joined(separator: "\n")
            }
            self.logTextView.scrollToEndOfDocument(nil)
        }
    }

    func clearLogs() {
        logTextView.string = ""
    }

    // MARK: - Button actions

    @objc private func startTapped()      { delegate?.panelDidRequestStartService() }
    @objc private func stopTapped()       { delegate?.panelDidRequestStopService() }
    @objc private func connectTapped()    { delegate?.panelDidRequestConnect() }
    @objc private func disconnectTapped() { delegate?.panelDidRequestDisconnect() }

    @objc private func saveTapped() {
        delegate?.panelDidRequestSave(
            host: hostField.stringValue,
            port: portField.stringValue,
            username: usernameField.stringValue,
            hub: hubField.stringValue,
            account: accountField.stringValue,
            password: passwordField.stringValue
        )
    }

    @objc private func importEnvTapped()   { delegate?.panelDidRequestImportEnv() }
    @objc private func clearLogsTapped()   { delegate?.panelDidRequestClearLogs() }
    @objc private func openLogsTapped()    { delegate?.panelDidRequestOpenLogs() }
    @objc private func revealRuntimeTapped() { delegate?.panelDidRequestRevealRuntime() }
    @objc private func quitTapped()        { NSApp.terminate(nil) }
}
