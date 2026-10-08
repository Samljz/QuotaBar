import Foundation

/// GLM Coding Plan (Z.ai / ZHIPU bigmodel).
///
/// The official `glm-plan-usage` plugin takes the host from `ANTHROPIC_BASE_URL`
/// and requests `GET https://<host>/api/monitor/usage/quota/limit`. The quota
/// payload lives under `data` when the response is enveloped. Time-window query
/// parameters belong to the model-usage endpoints, not this one.
struct GLMProvider: QuotaProvider {
    let id = "glm"
    let name = "GLM Coding"
    let menuTitle = "GLM"
    let billing = BillingModel.subscription
    private let config: ConfigStore
    private let client = HTTPClient()

    init(config: ConfigStore) {
        self.config = config
    }

    var requiredCredentials: [CredentialField] {
        [
            CredentialField(
                key: "apiKey",
                label: "Token（可留空，读取本机 GLM 账号）",
                isSecret: true,
                placeholder: "自动读取 ~/.claude/settings.json"
            ),
            CredentialField(
                key: "baseUrl", label: "Base URL", isSecret: false,
                placeholder: "https://api.z.ai/api/anthropic"
            ),
        ]
    }

    var isConfigured: Bool {
        secret != nil
    }

    /// Keychain override, then the GLM Coding account Claude Code already saved.
    private var secret: String? {
        if let saved = config.secret(provider: id, key: "apiKey") { return saved }
        if let local = LocalAccount.value(
            in: ".claude/settings.json",
            keys: ["env", "ANTHROPIC_AUTH_TOKEN"]
        ) { return local }
        let env = ProcessInfo.processInfo.environment
        return env["ANTHROPIC_AUTH_TOKEN"] ?? env["ANTHROPIC_API_KEY"]
    }

    private var baseUrl: URL? {
        let configured = config.value(provider: id, key: "baseUrl")
        let raw = (configured?.isEmpty == false ? configured : nil)
            ?? LocalAccount.value(in: ".claude/settings.json", keys: ["env", "ANTHROPIC_BASE_URL"])
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"]
            ?? "https://api.z.ai/api/anthropic"
        return Self.normalizeBase(raw)
    }

    func fetch() async throws -> QuotaSnapshot {
        guard let secret else {
            throw HTTPError(status: 401, body: "missing token")
        }
        guard let base = baseUrl, let url = Self.quotaLimitURL(baseURL: base) else {
            throw HTTPError(status: 400, body: "bad url")
        }

        let (data, _) = try await client.get(url, authorization: secret)
        return try Self.snapshot(parsing: data, providerID: id, name: name, billing: billing)
    }

    /// `https://api.z.ai/api/anthropic` -> `https://api.z.ai/api/monitor/usage/quota/limit`.
    static func quotaLimitURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty
        else { return nil }
        components.user = nil
        components.password = nil
        components.path = "/api/monitor/usage/quota/limit"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func normalizeBase(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }

    static func snapshot(
        parsing data: Data,
        providerID: String,
        name: String,
        billing: BillingModel
    ) throws -> QuotaSnapshot {
        let payload = try quotaResponse(from: data)
        guard !(payload.limits ?? []).isEmpty else {
            let excerpt = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw HTTPError(status: 200, body: "响应中没有额度数据: \(excerpt)")
        }
        return payload.snapshot(providerID: providerID, name: name, billing: billing)
    }

    /// Accept both `{ "data": { "limits": [...] } }` and a bare `{ "limits": [...] }`.
    private static func quotaResponse(from data: Data) throws -> QuotaLimitResponse {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(QuotaLimitEnvelope.self, from: data) {
            let resolved = envelope.resolved
            if !(resolved.limits ?? []).isEmpty {
                return resolved
            }
        }
        return try decodeJSON(QuotaLimitResponse.self, from: data)
    }
}

// MARK: - Response decoding

/// Response of `/api/monitor/usage/quota/limit`, either bare or under `data`.
private struct QuotaLimitEnvelope: Decodable {
    let data: QuotaLimitResponse?
    let limits: [QuotaLimitResponse.Limit]?
    let planName: String?
    let level: String?

    var resolved: QuotaLimitResponse {
        if let data, !(data.limits ?? []).isEmpty { return data }
        if limits != nil {
            return QuotaLimitResponse(
                limits: limits,
                planName: planName ?? data?.planName,
                level: level ?? data?.level
            )
        }
        return data ?? QuotaLimitResponse(limits: nil, planName: planName, level: level)
    }
}

/// Response of `/api/monitor/usage/quota/limit`.
private struct QuotaLimitResponse: Decodable {
    struct Limit: Decodable {
        let type: String
        let percentage: Double?
        let currentValue: Double?
        let usage: Double?
        /// Window unit from the monitor API. 3 = hours, 5 = months, 6 = weeks.
        let unit: Int?
        /// Window length in `unit`s. (unit 3, number 5) is the 5-hour window.
        let number: Int?
        /// Unix timestamp in milliseconds.
        let nextResetTime: Double?
    }

    let limits: [Limit]?
    let planName: String?
    /// Account tier, e.g. "pro". Present when `planName` is absent.
    let level: String?

    init(limits: [Limit]?, planName: String?, level: String? = nil) {
        self.limits = limits
        self.planName = planName
        self.level = level
    }

    func snapshot(providerID: String, name: String, billing: BillingModel) -> QuotaSnapshot {
        var meters: [Meter] = []
        for (index, limit) in (limits ?? []).enumerated() {
            let fraction = limit.percentage.map { $0 / 100 }
            let resetsAt = Self.resetDate(limit.nextResetTime)
            switch limit.type {
            case "TOKENS_LIMIT", "CREDIT_LIMIT":
                meters.append(Meter(
                    id: Self.tokenMeterID(unit: limit.unit, index: index),
                    label: Self.tokenLabel(unit: limit.unit, number: limit.number),
                    fraction: fraction,
                    used: limit.currentValue,
                    total: limit.usage,
                    unit: "tokens",
                    resetsAt: resetsAt
                ))
            case "TIME_LIMIT":
                meters.append(Meter(
                    id: "mcp",
                    label: "MCP 用量 (每月)",
                    fraction: fraction,
                    used: limit.currentValue,
                    total: limit.usage,
                    unit: "min",
                    resetsAt: resetsAt
                ))
            default:
                meters.append(Meter(
                    id: "\(limit.type.lowercased())-\(index)",
                    label: limit.type,
                    fraction: fraction,
                    used: limit.currentValue,
                    total: limit.usage,
                    unit: "",
                    resetsAt: resetsAt
                ))
            }
        }
        return QuotaSnapshot(
            providerID: providerID,
            displayName: name,
            planName: resolvedPlanName,
            billing: billing,
            meters: meters,
            updatedAt: Date()
        )
    }

    private var resolvedPlanName: String? {
        if let planName, !planName.isEmpty { return planName }
        guard let level, !level.isEmpty else { return nil }
        if level.lowercased() == "pro" { return "GLM Coding Pro" }
        let titled = level.prefix(1).uppercased() + level.dropFirst()
        return "GLM Coding \(titled)"
    }

    /// (unit 3, number 5) is the 5-hour window; (unit 6, number 1) is weekly.
    /// A TOKENS_LIMIT with no unit is the legacy 5-hour window.
    private static func tokenLabel(unit: Int?, number: Int?) -> String {
        switch (unit, number) {
        case (3, _): return "Token 用量 (5 小时)"
        case (6, _): return "Token 用量 (每周)"
        case (nil, _): return "Token 用量 (5 小时)"
        default: return "Token 用量"
        }
    }

    private static func tokenMeterID(unit: Int?, index: Int) -> String {
        switch unit {
        case 3, nil: return "tokens-5h"
        case 6: return "tokens-week"
        default: return "tokens-\(index)"
        }
    }

    private static func resetDate(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}
