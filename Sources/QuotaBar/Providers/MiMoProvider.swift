import Foundation

/// Xiaomi MiMo balance and Token Plan quota.
///
/// The `sk-` inference key authenticates `/v1/models` and chat completions, but
/// the gateway does not expose a balance. Quota comes from the console JSON
/// API, using a Xiaomi session cookie. When that cookie is missing or rejected,
/// the provider rebuilds it from the Chrome login already on this Mac.
///
///   GET https://platform.xiaomimimo.com/api/v1/tokenPlan/usage
///   GET https://platform.xiaomimimo.com/api/v1/tokenPlan/detail
///   GET https://platform.xiaomimimo.com/api/v1/balance
///
/// Auth is the logged-in session cookie (`api-platform_serviceToken`, `userId`),
/// pasted from browser DevTools. Unofficial and may break without notice.
struct MiMoProvider: QuotaProvider {
    let id = "mimo"
    let name = "Xiaomi MiMo"
    let menuTitle = "MiMo"
    // MiMo is a topped-up account billed per call, not a Token Plan window.
    let billing = BillingModel.prepaid
    private let config: ConfigStore
    private let client = HTTPClient()

    private static let host = "platform.xiaomimimo.com"

    init(config: ConfigStore) {
        self.config = config
    }

    var requiredCredentials: [CredentialField] {
        [
            CredentialField(
                key: "cookie",
                label: "会话 Cookie（可留空，读取 Chrome 里的小米官网登录）",
                isSecret: true,
                placeholder: "自动读取 platform.xiaomimimo.com"
            ),
        ]
    }

    var isConfigured: Bool {
        config.secret(provider: id, key: "cookie") != nil
            || config.secret(provider: id, key: "apiKey") != nil
            || MiMoBrowserSession.hasChromeLogin
    }

    func fetch() async throws -> QuotaSnapshot {
        if let cookie = config.secret(provider: id, key: "cookie") {
            do {
                return try await snapshot(cookie: cookie)
            } catch {
                if let fresh = await MiMoBrowserSession.cookieHeader() {
                    try? config.setSecret(fresh, provider: id, key: "cookie")
                    return try await snapshot(cookie: fresh)
                }
                throw error
            }
        }
        guard let fresh = await MiMoBrowserSession.cookieHeader() else {
            throw HTTPError(status: 401, body: "缺少会话 Cookie，且本机没有可用的小米登录")
        }
        try? config.setSecret(fresh, provider: id, key: "cookie")
        return try await snapshot(cookie: fresh)
    }

    private func snapshot(cookie: String) async throws -> QuotaSnapshot {
        // Plan endpoints are optional. A failure there must not drop a balance
        // that already came back, and one failure must not cancel the others.
        async let usage = fetchResult("tokenPlan/usage", cookie: cookie)
        async let detail = fetchResult("tokenPlan/detail", cookie: cookie)
        async let balance = fetchResult("balance", cookie: cookie)
        let usageResult = await usage
        let detailResult = await detail
        let balanceResult = await balance

        let balanceData = try? balanceResult.get()
        let usageData = try? usageResult.get()
        let detailData = try? detailResult.get()
        let meters = try Self.meters(usage: usageData, balance: balanceData)
        if meters.isEmpty, case .failure(let error) = balanceResult {
            throw error
        }
        if meters.isEmpty, case .failure(let error) = usageResult {
            throw error
        }

        let plan = detailData.flatMap { Self.planName(from: $0) } ?? "按量计费"
        return QuotaSnapshot(
            providerID: id,
            displayName: name,
            planName: plan,
            billing: .prepaid,
            meters: meters,
            updatedAt: Date()
        )
    }

    private func fetchResult(_ path: String, cookie: String) async -> Result<Data, Error> {
        do {
            return .success(try await request(path, cookie: cookie))
        } catch {
            return .failure(error)
        }
    }

    // MARK: HTTP

    private func request(_ path: String, cookie: String) async throws -> Data {
        guard let url = URL(string: "https://\(Self.host)/api/v1/\(path)") else {
            throw HTTPError(status: 400, body: "bad url")
        }
        let (data, _) = try await client.get(url, headers: [
            "Cookie": cookie,
            "Origin": "https://\(Self.host)",
            "Referer": "https://\(Self.host)/#/console/balance",
            // The console rejects non-browser clients.
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36",
            "x-timeZone": "Asia/Shanghai",
        ])
        return data
    }

    // MARK: Parsing

    /// Envelope is `{ "code": 0, "data": { ... } }`. A non-zero code or a 3xx
    /// from the server means the session cookie has expired.
    private static func unwrap(_ data: Data) throws -> Any? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else { return object }
        if let code = dict["code"] as? Int, code != 0 {
            let message = dict["message"] as? String ?? dict["msg"] as? String ?? "code \(code)"
            throw HTTPError(status: 401, body: "会话失效：\(message)")
        }
        return dict["data"]
    }

    private static func planName(from data: Data) -> String? {
        guard let root = try? unwrap(data) as? [String: Any] else { return nil }
        let name = root["planName"] as? String
        if let expired = root["expired"] as? Bool, expired {
            return (name ?? "Token Plan") + " (已过期)"
        }
        return name
    }

    private static func meters(usage: Data?, balance: Data?) throws -> [Meter] {
        var meters: [Meter] = []

        // MiMo is a topped-up account, so the balance is the headline number.
        // A non-zero envelope code means the session is dead; surface that
        // instead of rendering an empty row.
        if let balance, let root = try unwrap(balance) as? [String: Any] {
            let amount = double(root["balance"])
            let currency = root["currency"] as? String ?? "CNY"
            if amount != nil {
                meters.append(Meter(
                    id: "balance",
                    label: "充值余额",
                    kind: .balance,
                    total: amount,
                    unit: currency
                ))
                let cash = double(root["cashBalance"])
                let gift = double(root["giftBalance"])
                if cash != nil || gift != nil {
                    meters.append(Meter(
                        id: "balance-breakdown",
                        label: "充值 \(Self.fmt(cash)) / 赠送 \(Self.fmt(gift))",
                        kind: .counter,
                        unit: currency
                    ))
                }
            }
        }

        // Monthly quota windows, if the account also has a plan attached.
        // `{ monthUsage: { items: [{ name, used, limit }] } }`
        if let usage, let root = try? unwrap(usage) as? [String: Any] {
            let monthUsage = root["monthUsage"] as? [String: Any] ?? root
            if let items = monthUsage["items"] as? [[String: Any]] {
                for (index, item) in items.enumerated() {
                    guard let name = item["name"] as? String else { continue }
                    let used = double(item["used"])
                    let limit = double(item["limit"])
                    guard limit != nil else { continue }
                    meters.append(Meter(
                        id: "window-\(name)-\(index)",
                        label: label(forWindow: name),
                        kind: .quota,
                        fraction: (used != nil && (limit ?? 0) > 0) ? used! / limit! : nil,
                        used: used,
                        total: limit,
                        unit: "Credits",
                        resetsAt: nil
                    ))
                }
            }
        }

        return meters
    }

    private static func fmt(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value)
    }

    private static func label(forWindow name: String) -> String {
        switch name {
        case "month_total_token": return "本月 Token 总量"
        case "month_total_request": return "本月请求数"
        default: return name.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as String: return Double(value)
        default: return nil
        }
    }
}
