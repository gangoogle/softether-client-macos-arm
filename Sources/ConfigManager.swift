import Foundation
import Security

/// Manages VPN configuration persistence via UserDefaults and Keychain.
final class ConfigManager {

    // MARK: - Keys
    private enum Key: String {
        case host          = "VPN_HOST"
        case port          = "VPN_PORT"
        case username      = "VPN_USER"
        case hub           = "VPN_HUB"
        case accountName   = "VPN_ACCOUNT_NAME"
        case didImportEnv  = "VPN_DID_IMPORT_ENV"
        case launchAtLogin = "VPN_LAUNCH_AT_LOGIN"
    }

    private static let keychainService = "com.softether.vpnclient.gui"
    private static let keychainAccount = "vpn_password"

    let defaults = UserDefaults.standard

    // MARK: - Stored values

    var host: String {
        get { defaults.string(forKey: Key.host.rawValue) ?? "vpn.example.com" }
        set { defaults.set(newValue, forKey: Key.host.rawValue) }
    }

    var port: String {
        get { defaults.string(forKey: Key.port.rawValue) ?? "443" }
        set { defaults.set(newValue, forKey: Key.port.rawValue) }
    }

    var username: String {
        get { defaults.string(forKey: Key.username.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.username.rawValue) }
    }

    var hub: String {
        get { defaults.string(forKey: Key.hub.rawValue) ?? "DEFAULT" }
        set { defaults.set(newValue, forKey: Key.hub.rawValue) }
    }

    var accountName: String {
        get { defaults.string(forKey: Key.accountName.rawValue) ?? "vpn_conn" }
        set { defaults.set(newValue, forKey: Key.accountName.rawValue) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin.rawValue) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin.rawValue) }
    }

    // MARK: - Keychain password

    var password: String? {
        get {
            let query: [String: Any] = [
                kSecClass       as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
                kSecAttrAccount as String: Self.keychainAccount,
                kSecReturnData  as String: true,
                kSecMatchLimit  as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess,
                  let data = item as? Data,
                  let pass = String(data: data, encoding: .utf8) else {
                return nil
            }
            return pass
        }
        set {
            // Delete any existing item first
            let deleteQuery: [String: Any] = [
                kSecClass       as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
                kSecAttrAccount as String: Self.keychainAccount,
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            guard let newValue = newValue, !newValue.isEmpty else { return }

            let addQuery: [String: Any] = [
                kSecClass       as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
                kSecAttrAccount as String: Self.keychainAccount,
                kSecValueData   as String: newValue.data(using: .utf8)!,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    // MARK: - Config readiness

    var isConfigured: Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        return !h.isEmpty
            && h != "vpn.example.com"
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && password != nil
            && !(password?.isEmpty ?? true)
    }

    func serverAddress() -> String {
        let h = host.trimmingCharacters(in: .whitespaces)
        let p = port.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return "-" }
        return p.isEmpty ? h : "\(h):\(p)"
    }

    // MARK: - Import from .env

    /// Attempt to import configuration from a `.env` file beside the app binary.
    func importEnvIfNeeded() -> Bool {
        guard !defaults.bool(forKey: Key.didImportEnv.rawValue) else { return false }

        let envPath: String
        if let resourceURL = Bundle.main.resourceURL {
            // In a bundled app, .env might be beside the .app
            let appBundle = resourceURL.deletingLastPathComponent().deletingLastPathComponent()
            envPath = appBundle.appendingPathComponent(".env").path
        } else {
            // Development fallback
            envPath = FileManager.default.currentDirectoryPath + "/.env"
        }

        guard FileManager.default.fileExists(atPath: envPath),
              let content = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            return false
        }

        var imported = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"),
                  let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            guard !value.isEmpty else { continue }

            switch key {
            case "VPN_HOST":          host = value; imported = true
            case "VPN_PORT":          port = value; imported = true
            case "VPN_USER":          username = value; imported = true
            case "VPN_PASS":          password = value; imported = true
            case "VPN_HUB":           hub = value; imported = true
            case "VPN_ACCOUNT_NAME":  accountName = value; imported = true
            default: break
            }
        }

        defaults.set(true, forKey: Key.didImportEnv.rawValue)
        return imported
    }
}
