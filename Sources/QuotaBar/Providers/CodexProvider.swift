import Foundation

/// OpenAI Codex / ChatGPT-plan quota.
///
/// ChatGPT-plan rate limits come from the same private backend endpoint Codex
/// CLI itself uses (verified in openai/codex `rate_limit_resets.rs`):
///   GET https://chatgpt.com/backend-api/wham/usage
///   Authorization: Bearer <ChatGPT OAuth access token>
///   ChatGPT-Account-Id: <account id>
///
/// The token is read from `~/.codex/auth.json`, which Codex keeps up to date,
/// so this provider is configured by default whenever Codex is installed.
///
/// Note this is distinct from platform.openai.com API-key billing, which is a
/// separate USD-spend surface and is not what ChatGPT-plan quota reports.
struct CodexProvider: QuotaProvider {
    let id = "codex"
    let name = "Codex"
    let billing = BillingModel.subscription
    private let config: ConfigStore
    private let client = HTTPClient()

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    init(config: ConfigStore) {
        self.config = config
    }

    var requiredCredentials: [CredentialField] {
        [
            CredentialField(
                key: "apiKey",
                label: "OAuth Token (可留空，自动读取 ~/.codex/auth.json)",
                isSecret: true
            ),
            CredentialField(key: "accountId", label: "Account ID (可留空)", isSecret: false),
        ]
    }

    /// Configured token present, or `~/.codex/auth.json` readable.
    var isConfigured: Bool {
        Self.readAuthFile() != nil || config.secret(provider: id, key: "apiKey") != nil
    }

    func fetch() async throws -> QuotaSnapshot {
        // A value typed in Settings wins. Leaving it blank falls through to
        // ~/.codex/auth.json, which is the ChatGPT OAuth token `/wham/usage`
        // accepts — an API key (sk-…) is rejected by that endpoint.
        let auth: (token: String, accountID: String?)
        if let token = config.secret(provider: id, key: "apiKey") {
            auth = (token, config.value(provider: id, key: "accountId"))
        } else if let file = Self.readAuthFile() {
            auth = (file.token, file.accountID)
        } else {
            throw HTTPError(status: 401, body: "未找到 Codex 登录态（请先用 ChatGPT 账号登录 Codex CLI）")
        }

        var headers = [
            "User-Agent": "codex-cli",
        ]
        if let accountID = auth.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let data: Data
        do {
            (data, _) = try await client.get(
                Self.usageURL,
                headers: headers,
                authorization: "Bearer \(auth.token)"
            )
        } catch let error as HTTPError {
            // The endpoint rejects non-OAuth credentials with a distinctive
            // message. Annotate with the token's shape so the user can tell a
            // ChatGPT login from an API key without anyone printing the secret.
            throw HTTPError(status: error.status, body: "\(error.body) [token 形态: \(Self.shape(of: auth.token))]")
        }

        let payload = try decodeJSON(WhamUsage.self, from: data)
        return payload.snapshot(providerID: id, name: name, billing: billing)
    }

    /// Describe a credential's format without revealing any of it.
    static func shape(of token: String) -> String {
        let kind: String
        if token.hasPrefix("sk-") {
            kind = "API key (sk-…)"
        } else if token.split(separator: ".").count == 3 {
            kind = "JWT"
        } else {
            kind = "opaque"
        }
        return "\(kind), \(token.count) chars"
    }

    // MARK: - Local auth discovery

    private struct AuthFile {
        let token: String
        let accountID: String?
    }

    /// Read `~/.codex/auth.json`. Schema from openai/codex `login/src/auth/storage.rs`:
    /// `tokens.access_token`, `tokens.account_id`, `tokens.id_token`.
    private static func readAuthFile() -> AuthFile? {
        let path = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String
        else { return nil }

        var accountID = tokens["account_id"] as? String
        // Fall back to the id_token's chatgpt_account_id claim.
        if accountID == nil, let idToken = tokens["id_token"] as? String {
            accountID = jwtClaim(idToken, "chatgpt_account_id") as? String
        }
        return AuthFile(token: accessToken, accountID: accountID)
    }

    private static func jwtClaim(_ jwt: String, _ claim: String) -> Any? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any]
        else { return nil }
        return claims[claim]
    }
}

// MARK: - Response decoding

/// Response of `/wham/usage`. Field names verified against openai/codex's
/// `rate_limit_status_payload.rs` and `RateLimitStatusWithResetCredits`.
private struct WhamUsage: Decodable {
    struct Window: Decodable {
        /// Percent **used**, 0...100.
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        let resetAfterSeconds: Double?
        /// Unix epoch **seconds**.
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    struct RateLimit: Decodable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct AdditionalRateLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        /// Decimal string.
        let balance: String?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }
    }

    struct Limit: Decodable {
        let source: String?
        let limit: String?
        let used: String?
        let remaining: String?
        let usedPercent: Double?
        let remainingPercent: Double?
        let resetAfterSeconds: Double?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case source, limit, used, remaining
            case usedPercent = "used_percent"
            case remainingPercent = "remaining_percent"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    struct SpendControl: Decodable {
        let reached: Bool?
        let individualLimit: Limit?

        enum CodingKeys: String, CodingKey {
            case reached
            case individualLimit = "individual_limit"
        }
    }

    struct ResetCredits: Decodable {
        let availableCount: Int?

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
        }
    }

    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?
    let credits: Credits?
    let spendControl: SpendControl?
    let rateLimitResetCredits: ResetCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case spendControl = "spend_control"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }

    func snapshot(providerID: String, name: String, billing: BillingModel) -> QuotaSnapshot {
        var meters: [Meter] = []

        // The two active windows are not fixed 5h/weekly slots — the backend
        // returns whichever windows are currently relevant. Classify by length.
        if let limit = rateLimit {
            if let window = limit.primaryWindow {
                meters.append(meter(id: "primary", window: window))
            }
            if let window = limit.secondaryWindow {
                meters.append(meter(id: "secondary", window: window))
            }
        }

        for (index, item) in (additionalRateLimits ?? []).enumerated() {
            guard let limit = item.rateLimit, let window = limit.primaryWindow else { continue }
            let label = item.limitName ?? item.meteredFeature ?? "额外额度"
            var meter = meter(id: "extra-\(index)", window: window)
            meter.label = label
            meters.append(meter)
        }

        if let credits = credits, credits.hasCredits == true {
            if credits.unlimited == true {
                meters.append(Meter(
                    id: "credits",
                    label: "Credits (无限)",
                    kind: .counter
                ))
            } else {
                meters.append(Meter(
                    id: "credits",
                    label: "Credits 余额",
                    kind: .balance,
                    total: Double(credits.balance ?? ""),
                    unit: "credits"
                ))
            }
        }

        if let spend = spendControl?.individualLimit, spend.used != nil {
            meters.append(Meter(
                id: "spend-limit",
                label: "花费上限",
                fraction: (spend.usedPercent ?? 0) / 100,
                used: Double(spend.used ?? ""),
                total: Double(spend.limit ?? ""),
                unit: "USD",
                resetsAt: spend.resetAt.map { Date(timeIntervalSince1970: $0) }
            ))
        }

        if let resetCredits = rateLimitResetCredits?.availableCount, resetCredits > 0 {
            meters.append(Meter(
                id: "reset-credits",
                label: "可用重置次数",
                kind: .counter,
                total: Double(resetCredits),
                unit: "次"
            ))
        }

        return QuotaSnapshot(
            providerID: providerID,
            displayName: name,
            planName: planType.map(Self.planLabel),
            billing: billing,
            meters: meters,
            updatedAt: Date()
        )
    }

    /// `used_percent` is percent used; window length decides the label.
    private func meter(id: String, window: Window) -> Meter {
        Meter(
            id: id,
            label: Self.windowLabel(seconds: window.limitWindowSeconds),
            fraction: (window.usedPercent ?? 0) / 100,
            used: nil,
            total: nil,
            unit: "%",
            resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func windowLabel(seconds: Double?) -> String {
        guard let seconds else { return "额度窗口" }
        // codex-rs labels ~18000s "5-hour" and ~604800s "weekly".
        if seconds <= 6 * 3600 { return "5 小时窗口" }
        return "每周窗口"
    }

    private static func planLabel(_ plan: String) -> String {
        switch plan {
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "prolite": return "ChatGPT Pro Lite"
        case "promax": return "ChatGPT Pro Max"
        case "team": return "ChatGPT Team"
        case "business": return "ChatGPT Business"
        case "enterprise": return "ChatGPT Enterprise"
        case "free": return "Free"
        case "go": return "ChatGPT Go"
        default: return plan
        }
    }
}
