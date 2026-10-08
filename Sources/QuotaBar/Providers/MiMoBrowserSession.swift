import CommonCrypto
import Foundation
import SQLite3

/// Rebuilds a Xiaomi MiMo console session from the Chrome login already on this Mac.
///
/// The pay-as-you-go API key can call models, but balance lives on
/// `platform.xiaomimimo.com` and only accepts the console session cookie.
/// Chrome's `passToken` is exchanged through Xiaomi's service login, and the
/// resulting `api-platform_serviceToken` is what the quota requests send.
enum MiMoBrowserSession {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static var hasChromeLogin: Bool {
        cookieDatabases().contains(where: databaseHasPassToken)
    }

    /// Cookie header for `platform.xiaomimimo.com`, or nil when Chrome has no Xiaomi login.
    static func cookieHeader() async -> String? {
        let cookies = chromeCookies()
        if let header = consoleHeader(from: cookies) { return header }
        let account = cookies.filter {
            $0.host.contains("account.xiaomi.com") && ["passToken", "userId", "deviceId", "cUserId"].contains($0.name)
        }
        guard account.contains(where: { $0.name == "passToken" }) else { return nil }
        guard let loginURL = await loginURL() else { return nil }
        return await exchange(accountCookies: account, loginURL: loginURL)
    }

    /// The console session Chrome already stored, so the passToken is left unused.
    private static func consoleHeader(from cookies: [StoredCookie]) -> String? {
        var values: [String: String] = [:]
        for cookie in cookies where cookie.host.contains("xiaomimimo.com") {
            values[cookie.name] = cookie.value
        }
        guard let token = values["api-platform_serviceToken"], let userID = values["userId"] else { return nil }
        var parts = [
            "api-platform_serviceToken=\(token)",
            "userId=\(userID)",
        ]
        if let slh = values["api-platform_slh"] { parts.append("api-platform_slh=\(slh)") }
        if let ph = values["api-platform_ph"] { parts.append("api-platform_ph=\(ph)") }
        return parts.joined(separator: "; ")
    }

    // MARK: Chrome cookies

    private struct StoredCookie {
        let host: String
        let name: String
        let value: String
    }

    private static func cookieDatabases() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome")
        guard let profiles = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return profiles.compactMap { profile in
            let cookies = profile.appendingPathComponent("Cookies")
            return FileManager.default.fileExists(atPath: cookies.path) ? cookies : nil
        }
    }

    private static func databaseHasPassToken(_ database: URL) -> Bool {
        guard let opened = openCopy(of: database) else { return false }
        defer {
            sqlite3_close(opened.db)
            try? FileManager.default.removeItem(at: opened.copy)
        }
        let db = opened.db
        let sql = "SELECT 1 FROM cookies WHERE name = 'passToken' AND host_key LIKE '%xiaomi.com' LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func chromeCookies() -> [StoredCookie] {
        guard let key = chromeEncryptionKey() else { return [] }
        var found: [StoredCookie] = []
        for database in cookieDatabases() {
            guard let opened = openCopy(of: database) else { continue }
            let db = opened.db
            defer {
                sqlite3_close(db)
                try? FileManager.default.removeItem(at: opened.copy)
            }
            let sql = """
            SELECT host_key, name, encrypted_value FROM cookies
            WHERE host_key LIKE '%xiaomi%' OR host_key LIKE '%mimo%';
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let hostC = sqlite3_column_text(statement, 0),
                      let nameC = sqlite3_column_text(statement, 1),
                      let blob = sqlite3_column_blob(statement, 2)
                else { continue }
                let count = Int(sqlite3_column_bytes(statement, 2))
                let data = Data(bytes: blob, count: count)
                guard let value = decrypt(data, key: key) else { continue }
                found.append(StoredCookie(
                    host: String(cString: hostC),
                    name: String(cString: nameC),
                    value: value
                ))
            }
        }
        return found
    }

    /// Chrome locks its cookie database and keeps recent rows in the WAL.
    /// Copy the database and its sidecars so the session cookie is visible.
    private static func openCopy(of database: URL) -> (db: OpaquePointer, copy: URL)? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-chrome-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let copy = folder.appendingPathComponent("Cookies")
        guard (try? FileManager.default.copyItem(at: database, to: copy)) != nil else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var db: OpaquePointer?
        let status = sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let db else {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return (db, folder)
    }

    private nonisolated(unsafe) static var cachedChromeKey: [UInt8]?

    /// Chrome's own keychain item only trusts Google and Apple tools. Asking for
    /// it directly makes macOS show the login-password dialog on every read, and
    /// "Always Allow" does not stick. `security` is an Apple tool, so it can
    /// read the item without a dialog.
    private static func chromeEncryptionKey() -> [UInt8]? {
        if let cachedChromeKey { return cachedChromeKey }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Chrome Safe Storage",
            "-a", "Chrome",
            "-w",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let password = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty
        else { return nil }
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withCString { passwordPointer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordPointer,
                strlen(passwordPointer),
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &derived,
                derived.count
            )
        }
        guard status == kCCSuccess else { return nil }
        cachedChromeKey = derived
        return derived
    }

    /// Chrome 130+ stores `v10` + AES-128-CBC, then a 32-byte prefix before the value.
    private static func decrypt(_ data: Data, key: [UInt8]) -> String? {
        guard data.count > 3, data.starts(with: Data("v10".utf8)) else { return nil }
        let ciphertext = [UInt8](data.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            kCCKeySizeAES128,
            iv,
            ciphertext,
            ciphertext.count,
            &output,
            output.count,
            &moved
        )
        guard status == kCCSuccess, moved > 32 else { return nil }
        return String(bytes: output[32..<moved], encoding: .utf8)
    }

    // MARK: Xiaomi service login

    private static func loginURL() async -> URL? {
        guard let endpoint = URL(string: "https://platform.xiaomimimo.com/api/v1/balance") else { return nil }
        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["loginUrl"] as? String,
              var components = URLComponents(string: raw)
        else { return nil }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "_json" }) {
            items.append(URLQueryItem(name: "_json", value: "true"))
        }
        components.queryItems = items
        return components.url
    }

    private static func exchange(accountCookies: [StoredCookie], loginURL: URL) async -> String? {
        let storage = HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = storage
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        for cookie in accountCookies {
            let domain = cookie.host.hasPrefix(".") ? String(cookie.host.dropFirst()) : cookie.host
            guard let http = HTTPCookie(properties: [
                .name: cookie.name,
                .value: cookie.value,
                .domain: domain,
                .path: "/",
                .secure: "TRUE",
            ]) else { continue }
            storage.setCookie(http)
        }

        var login = URLRequest(url: loginURL)
        login.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (body, _) = try? await session.data(for: login),
              let location = locationURL(in: body)
        else { return nil }

        var follow = URLRequest(url: location)
        follow.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        _ = try? await session.data(for: follow)

        var values: [String: String] = [:]
        for cookie in storage.cookies ?? [] where cookie.domain.contains("xiaomimimo.com") {
            values[cookie.name] = cookie.value
        }
        guard let token = values["api-platform_serviceToken"], let userID = values["userId"] else { return nil }
        var parts = [
            "api-platform_serviceToken=\(token)",
            "userId=\(userID)",
        ]
        if let slh = values["api-platform_slh"] { parts.append("api-platform_slh=\(slh)") }
        if let ph = values["api-platform_ph"] { parts.append("api-platform_ph=\(ph)") }
        return parts.joined(separator: "; ")
    }

    private static func locationURL(in data: Data) -> URL? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "&&&START&&&"
        if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let location = object["location"] as? String
        else { return nil }
        return URL(string: location)
    }
}
