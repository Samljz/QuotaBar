import Foundation

/// Thin async HTTP helper shared by all providers.
struct HTTPClient: Sendable {
    var session: URLSession

    init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Perform a request and return (data, statusCode). Throws `HTTPError` for non-2xx.
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            // Truncate the body so we never log a whole HTML page into the menu.
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw HTTPError(status: status, body: preview)
        }
        // A 200 that is not JSON almost always means a login page or a proxy
        // interstitial rather than the API we asked for. Surface it explicitly
        // so this does not decode into a confusing schema error later.
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/html") {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw HTTPError(status: status, body: "返回了网页而非接口数据（可能需要重新登录）: \(preview)")
        }
        return (data, status)
    }

    /// Convenience GET with bearer-style auth header.
    func get(
        _ url: URL,
        headers: [String: String] = [:],
        authorization: String? = nil
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }
}

/// Decode JSON into `T`, or throw an error that quotes a snippet of the body so
/// a schema mismatch is diagnosable instead of a bare DecodingError.
///
/// Dates default to ISO-8601 strings, which is what the dashboard APIs use.
/// Providers whose fields are epoch numbers decode those as `Double` and are
/// unaffected by the strategy.
func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode(type, from: data)
    } catch {
        let excerpt = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        throw HTTPError(status: 200, body: "响应格式与预期不符: \(excerpt)")
    }
}

struct HTTPError: Error, CustomStringConvertible {
    let status: Int
    let body: String

    var description: String {
        let reason: String
        switch status {
        case 401, 403: reason = "认证失败"
        case 404: reason = "接口不存在"
        case 429: reason = "请求过于频繁"
        case 501: reason = "接口待接入"
        case 500..<600: reason = "服务端错误"
        default: reason = "请求失败"
        }
        // Surface a body excerpt so failures are diagnosable rather than
        // collapsing to a bare status code.
        let excerpt = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(300)
        if excerpt.isEmpty {
            return "\(reason) (\(status))"
        }
        return "\(reason) (\(status)): \(excerpt)"
    }
}
