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
    case tapNotFound
    case serviceNotRunning
    case notConfigured
    case commandFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            return "Bundled runtime files not found. The app may be incomplete."
        case .tapNotFound:
            return "TAP device /dev/tap0 not found.\nPlease install a tun/tap driver for macOS."
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
        var statInfo = stat()
        return stat("/dev/tap0", &statInfo) == 0 && (statInfo.st_mode & S_IFCHR) != 0
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
        if !checkTAP() {
            throw VPNError.tapNotFound
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
            "/NICNAME:tap0",
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
