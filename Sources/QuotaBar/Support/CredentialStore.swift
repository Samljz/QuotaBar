import Foundation

/// Where per-provider configuration (base URLs, API keys) is kept.
///
/// Secrets are written to the macOS Keychain; non-secret fields go to a JSON
/// file under Application Support. Providers read through this store rather
/// than from `ProcessInfo.environment`, so each plan can have its own token
/// even when only one of them is exported in the shell.
struct ConfigStore {
    /// Non-secret per-provider settings, keyed by provider id then field key.
    private struct FileConfig: Codable {
        var providers: [String: [String: String]]
        var refreshInterval: TimeInterval?

        init(providers: [String: [String: String]] = [:], refreshInterval: TimeInterval? = nil) {
            self.providers = providers
            self.refreshInterval = refreshInterval
        }
    }

    /// Field keys that must never be written to `config.json`.
    static func isSecretField(_ key: String) -> Bool {
        key == "apiKey" || key == "cookie"
    }

    let fileURL: URL
    private let keychain: Keychain

    init(fileURL: URL? = nil, keychainService: String = "com.lijunze.quotabar") {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("QuotaBar", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("config.json")
        }
        self.keychain = Keychain(service: keychainService)
    }

    // MARK: Non-secret fields

    func value(provider: String, key: String) -> String? {
        if Self.isSecretField(key) { return secret(provider: provider, key: key) }
        let stored = fileValues()[provider]?[key]
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    /// Persist a non-secret field. An empty string deletes it.
    /// Secret keys are ignored here so a cookie cannot land in the JSON file.
    func setValue(_ value: String, provider: String, key: String) {
        if Self.isSecretField(key) { return }
        var config = load()
        var entry = config.providers[provider] ?? [:]
        if value.isEmpty {
            entry.removeValue(forKey: key)
        } else {
            entry[key] = value
        }
        if entry.isEmpty {
            config.providers.removeValue(forKey: provider)
        } else {
            config.providers[provider] = entry
        }
        save(config)
    }

    // MARK: Refresh interval

    var refreshInterval: TimeInterval? {
        load().refreshInterval
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        var config = load()
        config.refreshInterval = interval
        save(config)
    }

    // MARK: Secrets

    /// Read a secret. Falls back to a value previously leaked into the JSON
    /// file (and moves it into the Keychain), then to well-known environment
    /// variables so a first run works when the shell already has the token.
    func secret(provider: String, key: String) -> String? {
        let account = "\(provider).\(key)"
        if let cached = Self.cachedSecret(account) { return cached }
        if let stored = keychain.get(account: account) {
            Self.rememberSecret(stored, account: account)
            return stored
        }
        if let leaked = fileValues()[provider]?[key], !leaked.isEmpty {
            if (try? keychain.set(leaked, account: account)) != nil {
                removePlaintext(provider: provider, key: key)
            }
            Self.rememberSecret(leaked, account: account)
            return leaked
        }
        return Self.envFallback(provider: provider, key: key)
    }

    func setSecret(_ value: String, provider: String, key: String) throws {
        let account = "\(provider).\(key)"
        try keychain.set(value, account: account)
        removePlaintext(provider: provider, key: key)
        Self.rememberSecret(value, account: account)
    }

    /// Drop a saved secret so providers can fall back to auto-discovery.
    func removeSecret(provider: String, key: String) throws {
        let account = "\(provider).\(key)"
        try keychain.delete(account: account)
        removePlaintext(provider: provider, key: key)
        Self.forgetSecret(account)
    }

    /// One successful keychain read per launch. Refresh keeps using this copy,
    /// so a later quota poll does not ask for the login password again.
    private static let secretLock = NSLock()
    private nonisolated(unsafe) static var secretCache: [String: String] = [:]

    private static func cachedSecret(_ account: String) -> String? {
        secretLock.lock()
        defer { secretLock.unlock() }
        return secretCache[account]
    }

    private static func rememberSecret(_ value: String, account: String) {
        secretLock.lock()
        secretCache[account] = value
        secretLock.unlock()
    }

    private static func forgetSecret(_ account: String) {
        secretLock.lock()
        secretCache.removeValue(forKey: account)
        secretLock.unlock()
    }

    /// Environment variables consulted when no Keychain entry exists yet.
    ///
    /// Only vars that genuinely belong to the provider are consulted. A token
    /// from one service is never sent to another — that both breaks auth and
    /// leaks the credential across vendors.
    private static func envFallback(provider: String, key: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        switch (provider, key) {
        case ("glm", "apiKey"):
            // GLM is consumed through an Anthropic-compatible endpoint, so the
            // same token the CLI uses is the natural default.
            return env["ANTHROPIC_AUTH_TOKEN"] ?? env["ANTHROPIC_API_KEY"]
        case ("deepseek", "apiKey"):
            return env["DEEPSEEK_API_KEY"]
        case ("cursor", "apiKey"):
            return env["CURSOR_API_KEY"]
        // codex and mimo have no env fallback on purpose: Codex needs the
        // ChatGPT OAuth token from ~/.codex/auth.json (an API key is rejected),
        // and MiMo quota needs a web session cookie. Guessing here would send
        // the wrong credential to the wrong vendor.
        default:
            return nil
        }
    }

    // MARK: File plumbing

    private func fileValues() -> [String: [String: String]] {
        load().providers
    }

    private func removePlaintext(provider: String, key: String) {
        var config = load()
        guard config.providers[provider]?[key] != nil else { return }
        config.providers[provider]?.removeValue(forKey: key)
        if config.providers[provider]?.isEmpty == true {
            config.providers.removeValue(forKey: provider)
        }
        save(config)
    }

    private func load() -> FileConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(FileConfig.self, from: data)
        else { return FileConfig() }
        return config
    }

    private func save(_ config: FileConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "钥匙串写入失败（\(status)）"
    }
}

/// Minimal Keychain wrapper for generic passwords.
///
/// Items are created with the keychain's default access. Because the app is
/// signed with the stable "QuotaBar Local" certificate, that default trusts
/// the certificate and the bundle id, not the binary hash. A custom access
/// list pins the current hash, and macOS then asks for the login password
/// again after every rebuild.
struct Keychain: Sendable {
    let service: String

    func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            allowEveryApplication(account: account)
            return
        }
        if update != errSecItemNotFound {
            throw KeychainError(status: update)
        }
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added != errSecSuccess {
            throw KeychainError(status: added)
        }
        allowEveryApplication(account: account)
    }

    /// The default ACL trusts only this exact binary. macOS then asks for the
    /// login password after every rebuild, and "Always Allow" is tied to that
    /// same hash. Clearing the application list keeps the item available to
    /// this Mac without another prompt.
    private func allowEveryApplication(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let item
        else { return }
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item as! SecKeychainItem, &access) == errSecSuccess,
              let access
        else { return }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess else { return }
        for case let acl as SecACL in (list as? [SecACL] ?? []) {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard authorizations.contains("ACLAuthorizationDecrypt") else { continue }
            _ = SecACLSetContents(
                acl,
                nil,
                "QuotaBar" as CFString,
                SecKeychainPromptSelector(rawValue: 0)
            )
        }
        _ = SecKeychainItemSetAccess(item as! SecKeychainItem, access)
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError(status: status)
        }
    }
}
