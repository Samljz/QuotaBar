import Foundation

/// Providers that can expose their raw response body for schema debugging.
protocol RawDebuggable {
    func rawResponse() async throws -> Data
}

/// `QuotaBar --dump-raw`: print each provider's raw JSON response body.
///
/// Response bodies are usage/quota figures, not credentials — this exists so a
/// schema mismatch can be diagnosed without hand-rolling a request.
enum RawDump {
    static func printAll(providers: [any QuotaProvider]) async {
        print("======== RAW RESPONSES ========")
        for provider in providers {
            print("--- \(provider.name) ---")
            guard let debuggable = provider as? RawDebuggable else {
                print("(不支持 raw 输出)")
                continue
            }
            do {
                let data = try await debuggable.rawResponse()
                if let pretty = prettyJSON(data) {
                    print(pretty)
                } else {
                    print(String(data: data.prefix(2000), encoding: .utf8) ?? "<binary>")
                }
            } catch {
                let message = (error as? HTTPError)?.description ?? error.localizedDescription
                print("ERROR \(message)")
            }
            print("")
        }
    }

    private static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
