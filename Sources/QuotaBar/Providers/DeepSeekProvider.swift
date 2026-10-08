import Foundation

/// DeepSeek platform balance.
///
/// DeepSeek is prepaid rather than windowed, so this reports money remaining
/// rather than a percentage of a plan. Official docs: "Get User Balance".
///   GET https://api.deepseek.com/user/balance
///   Authorization: Bearer <api key>
struct DeepSeekProvider: QuotaProvider {
    let id = "deepseek"
    let name = "DeepSeek"
    let billing = BillingModel.prepaid
    private let config: ConfigStore
    private let client = HTTPClient()

    init(config: ConfigStore) {
        self.config = config
    }

    var requiredCredentials: [CredentialField] {
        [
            CredentialField(
                key: "apiKey",
                label: "API Key（可留空，读取本机 DeepSeek 账号）",
                isSecret: true,
                placeholder: "自动读取 ~/.claude/providers/deepseek.json"
            ),
        ]
    }

    var isConfigured: Bool { secret != nil }

    /// Keychain override, then the DeepSeek account Claude Code already saved.
    /// The balance endpoint accepts this key and no browser session.
    private var secret: String? {
        if let saved = config.secret(provider: id, key: "apiKey") { return saved }
        return LocalAccount.value(
            in: ".claude/providers/deepseek.json",
            keys: ["env", "ANTHROPIC_AUTH_TOKEN"]
        )
    }

    func fetch() async throws -> QuotaSnapshot {
        guard let secret else {
            throw HTTPError(status: 401, body: "missing api key")
        }
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        let (data, _) = try await client.get(url, authorization: "Bearer \(secret)")
        let payload = try JSONDecoder().decode(BalanceResponse.self, from: data)
        return payload.snapshot(providerID: id, name: name)
    }
}

/// Response of `/user/balance`. Field names follow the official docs
/// (`is_available`, `balance_infos`), which differ from an older draft
/// (`is_balance_sufficient`, `balanceInfos`) — both are accepted.
private struct BalanceResponse: Decodable {
    struct BalanceInfo: Decodable {
        let currency: String?
        let totalBalance: String?
        let grantedBalance: String?
        let toppedUpBalance: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currency = try container.decodeIfPresent(String.self, forKey: .currency)
            // Accept both snake_case (current docs) and legacy spellings.
            totalBalance = try container.decodeIfPresent(String.self, forKey: .totalBalance)
            grantedBalance = try container.decodeIfPresent(String.self, forKey: .grantedBalance)
            toppedUpBalance = try container.decodeIfPresent(String.self, forKey: .toppedUpBalance)
        }
    }

    let isAvailable: Bool?
    let balanceInfos: [BalanceInfo]?

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case isBalanceSufficient = "is_balance_sufficient"
        case balanceInfos = "balance_infos"
        case balanceInfosLegacy = "balanceInfos"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable)
            ?? container.decodeIfPresent(Bool.self, forKey: .isBalanceSufficient)
        balanceInfos = try container.decodeIfPresent([BalanceInfo].self, forKey: .balanceInfos)
            ?? container.decodeIfPresent([BalanceInfo].self, forKey: .balanceInfosLegacy)
    }

    func snapshot(providerID: String, name: String) -> QuotaSnapshot {
        var meters: [Meter] = []
        for (index, info) in (balanceInfos ?? []).enumerated() {
            let currency = info.currency ?? "CNY"
            let balance = Double(info.totalBalance ?? "")
                ?? (Double(info.grantedBalance ?? "") ?? 0) + (Double(info.toppedUpBalance ?? "") ?? 0)
            let granted = Double(info.grantedBalance ?? "") ?? 0
            let toppedUp = Double(info.toppedUpBalance ?? "") ?? 0
            meters.append(Meter(
                id: "balance-\(currency.lowercased())-\(index)",
                label: "余额 (\(currency))",
                // Prepaid money remaining, not a fraction of a plan.
                kind: .balance,
                total: balance,
                unit: currency
            ))
            if granted > 0 || toppedUp > 0 {
                meters.append(Meter(
                    id: "breakdown-\(currency.lowercased())-\(index)",
                    label: "赠送 \(Self.fmt(granted)) / 充值 \(Self.fmt(toppedUp))",
                    kind: .counter,
                    unit: currency
                ))
            }
        }
        if meters.isEmpty {
            meters.append(Meter(
                id: "balance",
                label: "余额",
                kind: .balance,
                unit: ""
            ))
        }
        return QuotaSnapshot(
            providerID: providerID,
            displayName: name,
            planName: isAvailable == false ? "余额不足" : "按量计费",
            billing: .prepaid,
            meters: meters,
            updatedAt: Date()
        )
    }

    private static func fmt(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}
