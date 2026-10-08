import Foundation

/// Values already stored by the official local clients, such as Claude Code's
/// provider files. QuotaBar reads them when the Keychain has no override, the
/// same way Codex reads `~/.codex/auth.json`.
enum LocalAccount {
    static func value(in relativePath: String, keys: [String]) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        var current: Any = object
        for key in keys {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        guard let text = current as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
