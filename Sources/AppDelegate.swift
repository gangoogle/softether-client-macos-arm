import AppKit
import UserNotifications

private enum RuntimePreparationError: LocalizedError {
    case applicationSupportUnavailable
    case templateNotFound

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Cannot locate Application Support. The app cannot prepare a writable SoftEther runtime."
        case .templateNotFound:
            return "Cannot locate runtime template files. Expected vpnclient, vpncmd, and hamcore.se2 in the app bundle or repo bin/ directory."
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Core components
    private var config: ConfigManager!
    private var runtime: VPNRuntime!
    private var statusBar: StatusBarController!
    private var panelController: PanelController!
    private var panelContent: PanelContentViewController!

    private var runtimeDir: URL?
    private var statusTimer: Timer?

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        // --- Prepare writable runtime directory ---
        do {
            runtimeDir = try prepareRuntimeDir()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showStartupError(msg)
            NSApp.terminate(nil)
            return
        }
        guard let rDir = runtimeDir else {
            showStartupError("Cannot prepare runtime files (vpnclient, vpncmd).")
            NSApp.terminate(nil)
            return
        }

        // --- Init UI first (so appendLog works) ---
        panelContent = PanelContentViewController()
        panelContent.delegate = self

        panelController = PanelController(contentViewController: panelContent)

        statusBar = StatusBarController()
        statusBar.delegate = self

        // --- Init config & runtime ---
        config = ConfigManager()
        runtime = VPNRuntime(runtimeDir: rDir) { [weak self] in
            self?.config.accountName ?? "vpn_conn"
        }

        // Validate bundled runtime
        guard runtime.validateRuntime() else {
            showStartupError("Bundled runtime incomplete.\nExpected vpnclient, vpncmd, hamcore.se2 in:\n\(rDir.path)")
            NSApp.terminate(nil)
            return
        }

        // --- Import .env on first launch ---
        if config.importEnvIfNeeded() {
            appendLog("Imported configuration from .env")
        }

        // Load saved config into the form
        refreshConfigForm()
        appendLog("SoftEther VPN Client ready.")

        // --- Start periodic status polling ---
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        refreshStatus()

        // --- Auto-open panel so user sees the UI immediately ---
        let sb = statusBar!
        let pc = panelController!
        DispatchQueue.main.async {
            pc.show(relativeTo: sb.statusItem)
        }

        // --- Request notification permission ---
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // --- Check TAP on launch ---
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if !self.runtime.checkTAP() {
                self.appendLog("⚠ /dev/tap0 not found. Install a tun/tap driver.")
                self.statusBar.state = .error
                self.panelContent.setServiceRunning(false)
                self.panelContent.setVPNConnected(false, detail: "(no tap0)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
    }

    // MARK: - Menu commands

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "SoftEther VPN")
        appMenu.addItem(
            withTitle: "Quit SoftEther VPN",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Runtime discovery

    private func prepareRuntimeDir() throws -> URL {
        let templateDir = try findRuntimeTemplateDir()
        let targetDir = try applicationSupportRuntimeDir()
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let files = try FileManager.default.contentsOfDirectory(
            at: templateDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        for source in files where shouldCopyRuntimeFile(source) {
            let destination = targetDir.appendingPathComponent(source.lastPathComponent)
            try copyRuntimeFileIfNeeded(from: source, to: destination)
        }

        try makeExecutable(targetDir.appendingPathComponent("vpnclient"))
        try makeExecutable(targetDir.appendingPathComponent("vpncmd"))

        return targetDir
    }

    private func applicationSupportRuntimeDir() throws -> URL {
        guard let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RuntimePreparationError.applicationSupportUnavailable
        }
        return supportDir
            .appendingPathComponent("SoftEtherVPN", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    private func findRuntimeTemplateDir() throws -> URL {
        // 1. Bundled app: Contents/Resources/Runtime
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("Runtime")
            if isRuntimeTemplateUsable(bundled) {
                return bundled
            }
        }

        // 2. Development: repo/bin relative to the current working directory
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("bin")
        if isRuntimeTemplateUsable(cwd) {
            return cwd
        }

        // 3. Development: climb upward from the SwiftPM build executable
        if let exec = Bundle.main.executableURL {
            var cursor = exec.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = cursor.appendingPathComponent("bin")
                if isRuntimeTemplateUsable(candidate) {
                    return candidate
                }
                cursor.deleteLastPathComponent()
            }
        }

        throw RuntimePreparationError.templateNotFound
    }

    private func isRuntimeTemplateUsable(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: dir.appendingPathComponent("vpnclient").path)
            && fm.isExecutableFile(atPath: dir.appendingPathComponent("vpncmd").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("hamcore.se2").path)
    }

    private func shouldCopyRuntimeFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if ["vpnclient", "vpncmd", "hamcore.se2", "lang.config"].contains(name) {
            return true
        }
        if name.hasSuffix(".dylib") {
            return true
        }
        return name.hasPrefix("lib") && name.contains(".so")
    }

    private func copyRuntimeFileIfNeeded(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            let srcAttrs = try fm.attributesOfItem(atPath: source.path)
            let dstAttrs = try fm.attributesOfItem(atPath: destination.path)
            let srcSize = srcAttrs[.size] as? NSNumber
            let dstSize = dstAttrs[.size] as? NSNumber
            let srcDate = srcAttrs[.modificationDate] as? Date
            let dstDate = dstAttrs[.modificationDate] as? Date

            if srcSize == dstSize, let srcDate, let dstDate, srcDate <= dstDate {
                return
            }
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private func makeExecutable(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Status refresh

    @objc private func refreshStatus() {
        let running = runtime.isServiceRunning()
        panelContent.setServiceRunning(running)

        if running {
            let connected = runtime.isConnected()
            panelContent.setVPNConnected(connected)

            statusBar.state = connected ? .connected : .disconnected
        } else {
            panelContent.setVPNConnected(false)
            statusBar.state = .disconnected
        }
    }

    private func refreshConfigForm() {
        panelContent.setConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            hub: config.hub,
            account: config.accountName,
            password: config.password ?? ""
        )
    }

    // MARK: - Helpers

    private func appendLog(_ msg: String) {
        panelContent.appendLog(msg)
    }

    private func showStartupError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "VPN Client Startup Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Operations (background)

    private func performAsync(_ label: String, block: @escaping () throws -> Void) {
        statusBar.state = .connecting
        appendLog(label + "...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try block()
                DispatchQueue.main.async {
                    self.appendLog("✓ " + label + " done")
                    self.refreshStatus()
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async {
                    self.appendLog("✗ " + label + " failed: " + msg)
                    self.statusBar.state = .error
                    self.refreshStatus()
                    self.notify(title: label + " Failed", body: msg)
                }
            }
        }
    }
}

// MARK: - StatusBarDelegate

extension AppDelegate: StatusBarDelegate {
    func statusBarDidToggle() {
        panelController.toggle(relativeTo: statusBar.statusItem)
    }
}

// MARK: - PanelContentDelegate

extension AppDelegate: PanelContentDelegate {

    func panelDidRequestStartService() {
        performAsync("Starting service") {
            let r = self.runtime.startService()
            if !r.succeeded {
                throw VPNError.commandFailed(r.output)
            }
            Thread.sleep(forTimeInterval: 2)
            if !self.runtime.isServiceRunning() {
                throw VPNError.serviceNotRunning
            }
        }
    }

    func panelDidRequestStopService() {
        performAsync("Stopping service") {
            let r = self.runtime.stopService()
            if !r.succeeded {
                throw VPNError.commandFailed(r.output)
            }
        }
    }

    func panelDidRequestConnect() {
        guard config.isConfigured else {
            appendLog("✗ Configuration incomplete. Fill in server, username, and password.")
            statusBar.state = .error
            notify(title: "Cannot Connect", body: "Configuration is incomplete.")
            return
        }

        if !runtime.isServiceRunning() {
            performAsync("Starting service") {
                _ = self.runtime.startService()
                Thread.sleep(forTimeInterval: 2)
                if !self.runtime.isServiceRunning() {
                    throw VPNError.serviceNotRunning
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.doConnect()
            }
        } else {
            doConnect()
        }
    }

    private func doConnect() {
        performAsync("Connecting") {
            _ = try self.runtime.connect(
                host: self.config.host,
                port: self.config.port,
                username: self.config.username,
                password: self.config.password ?? "",
                hub: self.config.hub
            )
            Thread.sleep(forTimeInterval: 3)
            if self.runtime.isConnected() {
                DispatchQueue.main.async {
                    self.notify(title: "VPN Connected",
                                body: "Successfully connected to \(self.config.serverAddress())")
                }
            }
        }
    }

    func panelDidRequestDisconnect() {
        performAsync("Disconnecting") {
            let r = self.runtime.disconnect()
            if !r.succeeded {
                throw VPNError.commandFailed(r.output)
            }
            DispatchQueue.main.async {
                self.notify(title: "VPN Disconnected", body: "Disconnected from VPN server.")
            }
        }
    }

    func panelDidRequestSave(host: String, port: String, username: String,
                             hub: String, account: String, password: String) {
        config.host = host
        config.port = port
        config.username = username
        config.hub = hub
        config.accountName = account
        if !password.isEmpty {
            config.password = password
        }
        appendLog("Configuration saved.")
    }

    func panelDidRequestClearLogs() {
        panelContent.clearLogs()
    }

    func panelDidRequestOpenLogs() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("softether_vpn_log_\(Int(Date().timeIntervalSince1970)).txt")
        try? panelContent.logContent.write(to: tmp, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(tmp)
    }

    func panelDidRequestRevealRuntime() {
        if let dir = runtimeDir {
            NSWorkspace.shared.open(dir)
        }
    }

    func panelDidRequestImportEnv() {
        if config.importEnvIfNeeded() {
            refreshConfigForm()
            appendLog("Configuration imported from .env")
        } else {
            appendLog("No .env found or already imported.")
        }
    }
}
