import Foundation

/// Result from running a subprocess.
struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var output: String { stdout + stderr }
    var succeeded: Bool { exitCode == 0 }
}

/// Errors that VPNRuntime can surface.
enum VPNError: LocalizedError {
    case runtimeNotFound
    case tapUnavailable(TAPStatus)
    case serviceNotRunning
    case notConfigured
    case commandFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            return "Bundled runtime files not found. The app may be incomplete."
        case .tapUnavailable(let status):
            return status.userMessage
        case .serviceNotRunning:
            return "VPN service is not running. Start the service first."
        case .notConfigured:
            return "VPN configuration is incomplete. Fill in server, username, and password."
        case .commandFailed(let msg):
            return msg
        case .timeout:
            return "Command timed out."
        }
    }
}

/// macOS TAP diagnosis used before SoftEther account creation.
struct TAPStatus {
    enum State {
        case ready
        case installedButNotLoaded
        case missing
    }

    let state: State
    let devicePath: String?
    let installedKextPaths: [String]
    let loadedKexts: [String]

    var isReady: Bool { state == .ready }

    var nicName: String {
        guard let devicePath else { return "tap0" }
        return URL(fileURLWithPath: devicePath).lastPathComponent
    }

    var shortDetail: String {
        switch state {
        case .ready:
            return nicName
        case .installedButNotLoaded:
            return "TAP installed but not loaded"
        case .missing:
            return "no tap0"
        }
    }

    var userMessage: String {
        switch state {
        case .ready:
            return "TAP device \(devicePath ?? "/dev/tap0") is ready."
        case .installedButNotLoaded:
            let paths = installedKextPaths.joined(separator: "\n")
            return """
            TAP device /dev/tap0 was not found, but a TAP kernel extension is installed and not loaded.

            Installed TAP kext:
            \(paths)

            Open System Settings > Privacy & Security and allow the blocked system software, then reboot. On Apple Silicon, kernel extensions may also require Reduced Security with user-approved kernel extension loading enabled.
            """
        case .missing:
            return """
            TAP device /dev/tap0 was not found.

            Install or enable a macOS TAP driver that creates /dev/tap0. Existing utun interfaces are not TAP devices and cannot be used by this SoftEther client mode.
            """
        }
    }
}

/// Encapsulates all direct invocations of bundled vpnclient and vpncmd.
final class VPNRuntime {

    /// Resolved path to the runtime directory (bin/ in dev, Resources/Runtime/ in app).
    private var runtimeDir: URL
    private var vpnclientPath: URL { runtimeDir.appendingPathComponent("vpnclient") }
    private var vpncmdPath: URL { runtimeDir.appendingPathComponent("vpncmd") }
    private let accountName: () -> String

    // MARK: - Init

    init(runtimeDir: URL, accountName: @escaping () -> String) {
        self.runtimeDir = runtimeDir
        self.accountName = accountName
    }

    /// Update runtime directory after launch-time discovery.
    func setRuntimeDir(_ url: URL) { runtimeDir = url }

    /// Validate that the runtime directory contains the expected files.
    func validateRuntime() -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: vpnclientPath.path)
            && fm.isExecutableFile(atPath: vpncmdPath.path)
            && fm.fileExists(atPath: runtimeDir.appendingPathComponent("hamcore.se2").path)
    }

    // MARK: - Environment

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let libPath = runtimeDir.path
        if let existing = env["DYLD_LIBRARY_PATH"], !existing.isEmpty {
            env["DYLD_LIBRARY_PATH"] = "\(libPath):\(existing)"
        } else {
            env["DYLD_LIBRARY_PATH"] = libPath
        }
        if let existing = env["LD_LIBRARY_PATH"], !existing.isEmpty {
            env["LD_LIBRARY_PATH"] = "\(libPath):\(existing)"
        } else {
            env["LD_LIBRARY_PATH"] = libPath
        }
        return env
    }

    // MARK: - Process runner

    @discardableResult
    private func run(executable: URL, arguments: [String],
                     stdin: String? = nil, timeout: TimeInterval = 30) -> ProcessResult {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.environment = environment()
        proc.currentDirectoryURL = runtimeDir

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        if let input = stdin {
            let inPipe = Pipe()
            proc.standardInput = inPipe
            inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
            inPipe.fileHandleForWriting.closeFile()
        }

        let deadline = Date().addingTimeInterval(timeout)
        do {
            try proc.run()
        } catch {
            return ProcessResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }

        // Wait with timeout
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if proc.isRunning { proc.interrupt() }
            return ProcessResult(stdout: "", stderr: "Command timed out after \(timeout)s", exitCode: -1)
        }

        let outStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(stdout: outStr, stderr: errStr, exitCode: proc.terminationStatus)
    }

    // MARK: - vpncmd helper

    @discardableResult
    func vpncmd(_ args: String..., stdin: String? = nil, timeout: TimeInterval = 20) -> ProcessResult {
        run(executable: vpncmdPath, arguments: ["localhost", "/CLIENT", "/CMD"] + args,
            stdin: stdin, timeout: timeout)
    }

    // MARK: - vpnclient helper

    @discardableResult
    func vpnclient(_ args: String..., timeout: TimeInterval = 15) -> ProcessResult {
        run(executable: vpnclientPath, arguments: args, timeout: timeout)
    }

    // MARK: - Service lifecycle

    func startService() -> ProcessResult {
        vpnclient("start")
    }

    func stopService() -> ProcessResult {
        vpnclient("stop")
    }

    /// Returns true if the vpnclient service is reachable via vpncmd.
    func isServiceRunning() -> Bool {
        let r = vpncmd("AccountList", timeout: 5)
        let lower = r.output.lowercased()
        return lower.contains("connected to vpn client \"localhost\"")
            && lower.contains("accountlist command")
    }

    // MARK: - TAP / NIC

    func checkTAP() -> Bool {
        tapStatus().isReady
    }

    func tapStatus() -> TAPStatus {
        if hasCharacterDevice("/dev/tap0") {
            return TAPStatus(state: .ready, devicePath: "/dev/tap0", installedKextPaths: installedTAPKextPaths(), loadedKexts: loadedTAPKexts())
        }

        let installed = installedTAPKextPaths()
        let loaded = loadedTAPKexts()
        if !loaded.isEmpty, hasAnyTapDevice() {
            return TAPStatus(state: .ready, devicePath: firstTapDevice(), installedKextPaths: installed, loadedKexts: loaded)
        }

        if !installed.isEmpty {
            return TAPStatus(state: .installedButNotLoaded, devicePath: nil, installedKextPaths: installed, loadedKexts: loaded)
        }

        return TAPStatus(state: .missing, devicePath: nil, installedKextPaths: [], loadedKexts: loaded)
    }

    private func hasCharacterDevice(_ path: String) -> Bool {
        var statInfo = stat()
        return stat(path, &statInfo) == 0 && (statInfo.st_mode & S_IFCHR) != 0
    }

    private func hasAnyTapDevice() -> Bool {
        firstTapDevice() != nil
    }

    private func firstTapDevice() -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else {
            return nil
        }

        return entries
            .filter { $0.range(of: #"^tap[0-9]+$"#, options: .regularExpression) != nil }
            .sorted()
            .map { "/dev/\($0)" }
            .first(where: hasCharacterDevice)
    }

    private func installedTAPKextPaths() -> [String] {
        [
            "/Library/Extensions/tunnelblick-tap.kext",
            "/Library/Extensions/tap.kext",
            "/Library/Extensions/tun.kext",
            "/Library/Extensions/tuntap.kext",
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func loadedTAPKexts() -> [String] {
        let result = run(executable: URL(fileURLWithPath: "/usr/sbin/kmutil"), arguments: ["showloaded"], timeout: 5)
        let output = result.output.isEmpty ? run(executable: URL(fileURLWithPath: "/usr/sbin/kextstat"), arguments: [], timeout: 5).output : result.output
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("tunnelblick.tap")
                    || lower.contains("net.sf.tuntaposx.tap")
                    || lower.contains("foo.tun")
                    || lower.contains(".tap")
            }
    }

    // MARK: - Connection

    func isConnected() -> Bool {
        let r = vpncmd("AccountStatusGet", accountName(), timeout: 8)
        let lower = r.output.lowercased()
        guard !lower.contains("error occurred"),
              !lower.contains("not connected"),
              lower.contains("the command completed successfully.") else {
            return false
        }
        return true
    }

    /// Full connect flow: start service → check TAP → delete old account → create → set password → connect.
    func connect(host: String, port: String, username: String,
                 password: String, hub: String) throws -> ProcessResult {
        // 1. Service must be running
        if !isServiceRunning() {
            throw VPNError.serviceNotRunning
        }

        // 2. TAP must be present
        let tap = tapStatus()
        if !tap.isReady {
            throw VPNError.tapUnavailable(tap)
        }

        let acct = accountName()
        let server = "\(host):\(port)"

        // 3. Delete old account (best-effort)
        vpncmd("AccountDelete", acct, timeout: 10)

        // 4. Create new account (needs "VPN\n" on stdin for management auth)
        let createResult = vpncmd(
            "AccountCreate", acct,
            "/SERVER:\(server)",
            "/HUB:\(hub)",
            "/USERNAME:\(username)",
            "/NICNAME:\(tap.nicName)",
            stdin: "VPN\n",
            timeout: 15
        )

        // 5. Set password
        let pwdResult = vpncmd(
            "AccountPasswordSet", acct,
            "/PASSWORD:\(password)",
            "/TYPE:standard",
            timeout: 10
        )

        // 6. Connect
        let connResult = vpncmd("AccountConnect", acct, timeout: 15)

        let combined = [createResult.output, pwdResult.output, connResult.output]
            .joined(separator: "\n")
        let success = connResult.output.lowercased().contains("completed successfully")

        if !success {
            throw VPNError.commandFailed(combined)
        }

        return ProcessResult(stdout: combined, stderr: "", exitCode: success ? 0 : 1)
    }

    func disconnect() -> ProcessResult {
        vpncmd("AccountDisconnect", accountName(), timeout: 10)
    }
}
