import Foundation
import SQLite3

/// Cursor subscription usage.
///
/// Cursor has no official personal quota API. The web dashboard's own endpoint
/// is what menu bar apps use in practice:
///   GET https://cursor.com/api/usage-summary
///   Cookie: WorkosCursorSessionToken=<userID>%3A%3A<accessToken>
///
/// The access token can be read locally from Cursor's own state DB, so this
/// provider auto-discovers it and falls back to a pasted cookie.
struct CursorProvider: QuotaProvider, RawDebuggable {
    let id = "cursor"
    let name = "Cursor"
    let menuTitle = "Cursor"
    let billing = BillingModel.subscription
    private let config: ConfigStore
    private let client = HTTPClient()

    init(config: ConfigStore) {
        self.config = config
    }

    var requiredCredentials: [CredentialField] {
        [
            CredentialField(
                key: "cookie",
                label: "Session Cookie (可留空，自动读取 Cursor 登录态)",
                isSecret: true
            ),
        ]
    }

    /// Configured cookie present, or a token discoverable on disk.
    var isConfigured: Bool {
        config.secret(provider: id, key: "cookie") != nil || Self.discoverCookie() != nil
    }

    func fetch() async throws -> QuotaSnapshot {
        let data = try await rawResponse()
        let summary = try decodeJSON(UsageSummary.self, from: data)
        return summary.snapshot(providerID: id, name: name, billing: billing)
    }

    func rawResponse() async throws -> Data {
        guard let cookie = config.secret(provider: id, key: "cookie") ?? Self.discoverCookie() else {
            throw HTTPError(status: 401, body: "未找到 Cursor 登录态")
        }

        let url = URL(string: "https://cursor.com/api/usage-summary")!
        // Cursor returns a 307 to the login page when the session is stale,
        // rather than a 401 — the HTTP layer surfaces that as a failed status.
        let (data, _) = try await client.get(url, headers: [
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36",
        ])
        return data
    }

    // MARK: - Local token discovery

    /// Build the `WorkosCursorSessionToken` cookie from Cursor's local auth state.
    ///
    /// The token is read from Cursor's state database. Cursor also stores a copy
    /// in the login keychain, but that item's access list only allows Cursor, so
    /// reading it makes macOS ask for the login password on every launch.
    static func discoverCookie() -> String? {
        guard let token = readStateDBToken() else { return nil }
        return cookie(fromJWT: token)
    }

    /// Characters left untouched by `encodeURIComponent`. `:` is encoded, so
    /// `userID::accessToken` becomes `userID%3A%3AaccessToken` while JWT
    /// `.` `-` `_` stay literal.
    static let uriComponentAllowed: CharacterSet = {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    }()

    /// `WorkosCursorSessionToken` = URL-encoded `userID::accessToken`, where
    /// userID is the JWT's `sub` claim.
    static func cookie(fromJWT jwt: String) -> String? {
        guard let sub = jwtSubject(jwt) else { return nil }
        let raw = "\(sub)::\(jwt)"
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) else {
            return nil
        }
        return "WorkosCursorSessionToken=\(encoded)"
    }

    private static func jwtSubject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any],
              let sub = claims["sub"] as? String
        else { return nil }
        return sub
    }

    /// Cursor (a VS Code fork) keeps `cursorAuth/accessToken` in its globalState
    /// SQLite DB.
    private static func readStateDBToken() -> String? {
        let path = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb")
            .path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: cString)
    }
}

// MARK: - Response decoding

/// Response of `/api/usage-summary`. Money fields are integer cents; percent
/// fields are 0...100.
private struct UsageSummary: Decodable {
    struct Breakdown: Decodable {
        /// Allowance included with the plan (cents).
        let included: Double?
        /// Extra promotional/overage allowance (cents).
        let bonus: Double?
        /// included + bonus (cents).
        let total: Double?
    }

    struct Plan: Decodable {
        let enabled: Bool?
        /// Cents spent against the *included* allowance only.
        let used: Double?
        /// Cents of the *included* allowance only.
        let limit: Double?
        let remaining: Double?
        let breakdown: Breakdown?
        /// Weighted usage percentage — the figure Cursor's own dashboard shows.
        let totalPercentUsed: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
    }

    struct IndividualUsage: Decodable {
        let plan: Plan?
        let onDemand: Plan?
        let overall: Plan?
    }

    struct TeamUsage: Decodable {
        let pooled: Plan?
    }

    let billingCycleStart: Date?
    let billingCycleEnd: Date?
    let membershipType: String?
    let isUnlimited: Bool?
    let individualUsage: IndividualUsage?
    let teamUsage: TeamUsage?

    func snapshot(providerID: String, name: String, billing: BillingModel) -> QuotaSnapshot {
        var meters: [Meter] = []
        let cycleEnd = billingCycleEnd

        if let plan = individualUsage?.plan, plan.enabled == true {
            // `totalPercentUsed` and the `used`/`limit` cents measure different
            // things (weighted usage vs. dollars spent), so they are shown as
            // separate meters rather than merged into one contradictory line.
            meters.append(percentMeter(
                id: "plan",
                label: "本月用量",
                percent: plan.totalPercentUsed,
                resetsAt: cycleEnd
            ))
            if let auto = plan.autoPercentUsed {
                meters.append(percentMeter(
                    id: "plan-auto", label: "Cursor Models", percent: auto,
                    resetsAt: cycleEnd
                ))
            }
            if let api = plan.apiPercentUsed {
                meters.append(percentMeter(
                    id: "plan-api", label: "Other Models", percent: api,
                    resetsAt: cycleEnd
                ))
            }
            // `used`/`limit` cover only the plan's *included* allowance; the
            // `bonus` pool is separate and is what makes 55% and "$400/$400"
            // both true at once. Label them so they cannot be misread.
            if plan.used != nil || plan.limit != nil {
                meters.append(Meter(
                    id: "plan-included",
                    label: "套餐内额度",
                    kind: .counter,
                    used: plan.used.map { $0 / 100 },
                    total: plan.limit.map { $0 / 100 },
                    unit: "USD",
                    resetsAt: cycleEnd
                ))
            }
            if let breakdown = plan.breakdown, let total = breakdown.total {
                var label = "含赠送总额度 \(formatUSD(total / 100))"
                if let bonus = breakdown.bonus, bonus > 0 {
                    label += "（赠送 \(formatUSD(bonus / 100))）"
                }
                meters.append(Meter(
                    id: "plan-breakdown",
                    label: label,
                    kind: .counter,
                    unit: "USD",
                    resetsAt: cycleEnd
                ))
            }
        }

        if let pooled = teamUsage?.pooled, pooled.enabled == true, pooled.limit != nil {
            meters.append(Meter(
                id: "team-pooled",
                label: "团队共享额度",
                kind: .quota,
                fraction: (pooled.used != nil && (pooled.limit ?? 0) > 0)
                    ? pooled.used! / pooled.limit! : nil,
                used: pooled.used.map { $0 / 100 },
                total: pooled.limit.map { $0 / 100 },
                unit: "USD",
                resetsAt: cycleEnd
            ))
        }

        if let onDemand = individualUsage?.onDemand, onDemand.enabled == true, onDemand.used != nil {
            meters.append(Meter(
                id: "on-demand",
                label: "按量消费",
                kind: .counter,
                used: onDemand.used.map { $0 / 100 },
                total: onDemand.limit.map { $0 / 100 },
                unit: "USD",
                resetsAt: cycleEnd
            ))
        }

        if meters.isEmpty {
            meters.append(Meter(
                id: "plan", label: "本月用量", kind: .quota, resetsAt: cycleEnd
            ))
        }

        return QuotaSnapshot(
            providerID: providerID,
            displayName: name,
            planName: membershipType.map { "\($0) plan" },
            billing: billing,
            meters: meters,
            updatedAt: Date()
        )
    }

    /// A pure percentage bar. Money is deliberately not attached to it — the two
    /// metrics disagree by design and mixing them reads as a data error.
    private func percentMeter(
        id: String, label: String, percent: Double?, resetsAt: Date?
    ) -> Meter {
        Meter(
            id: id,
            label: label,
            kind: .quota,
            fraction: percent.map { $0 / 100 },
            unit: "%",
            resetsAt: resetsAt
        )
    }

    private func formatUSD(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
