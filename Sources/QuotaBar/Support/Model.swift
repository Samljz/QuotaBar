import Foundation

/// How a provider charges. Determines which figure is the headline number:
/// a subscription burns down a windowed quota, a prepaid account burns down a
/// cash balance.
enum BillingModel: String, Sendable, Codable {
    /// Monthly/period quota with a reset (GLM, Codex, Cursor).
    case subscription
    /// Topped-up money spent per call (MiMo, DeepSeek).
    case prepaid
}

/// What a meter represents, which decides how the UI renders it.
enum MeterKind: String, Hashable, Codable {
    /// A windowed quota being consumed — render as a progress bar.
    case quota
    /// A cash balance that only goes down — render as an amount, no bar.
    case balance
    /// A plain count (reset credits, request tallies).
    case counter
}

/// One measurable quota dimension, e.g. "Tokens (5h)", "Balance", "Weekly premium requests".
struct Meter: Identifiable, Hashable, Codable {
    /// Stable identity for the meter within a provider, e.g. "tokens-5h".
    var id: String
    /// Human-readable label, e.g. "5h window", "Balance", "Weekly".
    var label: String
    /// How the UI should present this meter.
    var kind: MeterKind
    /// Fraction consumed, 0.0 ... 1.0. Nil when the provider only reports an absolute value.
    var fraction: Double?
    /// Raw used/total when the provider reports counts or currency.
    var used: Double?
    var total: Double?
    /// Display unit for used/total: "tokens", "requests", "USD", "%", etc.
    var unit: String
    /// When the window resets, if the provider reports it.
    var resetsAt: Date?

    /// Consumed fraction, meaningful only for windowed quotas. Balance and
    /// counter meters are not "X% full", so they report nil and the UI shows
    /// the raw amount instead of a misleading percentage.
    var consumedFraction: Double? {
        guard kind == .quota else { return nil }
        if let fraction { return fraction }
        if let used, let total, total > 0 { return used / total }
        return nil
    }

    /// Convenience initializer defaulting to a quota-style meter.
    init(
        id: String,
        label: String,
        kind: MeterKind = .quota,
        fraction: Double? = nil,
        used: Double? = nil,
        total: Double? = nil,
        unit: String = "",
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.fraction = fraction
        self.used = used
        self.total = total
        self.unit = unit
        self.resetsAt = resetsAt
    }
}

/// Point-in-time snapshot of one provider's quota state.
struct QuotaSnapshot: Identifiable, Hashable, Codable {
    var id: String { providerID }
    var providerID: String
    var displayName: String
    /// Plan/subscription name if known, e.g. "GLM Coding Pro".
    var planName: String?
    /// How this account is billed; drives how meters are presented.
    var billing: BillingModel
    var meters: [Meter]
    var updatedAt: Date
}

/// Outcome of a single provider fetch attempt.
enum ProviderState {
    case idle
    case loading
    case ready(QuotaSnapshot)
    case failed(String)
}

/// A source of quota data (GLM, MiMo, DeepSeek, Cursor, Codex, ...).
///
/// Implementations own their own auth and endpoint details. `fetch` must be
/// safe to call from any thread and should complete quickly; the caller handles
/// caching and refresh scheduling.
protocol QuotaProvider: Sendable {
    /// Stable key used in config and as `QuotaSnapshot.providerID`.
    var id: String { get }
    /// Display name shown in the menu.
    var name: String { get }
    /// How this provider charges (subscription window vs. prepaid balance).
    var billing: BillingModel { get }
    /// Whether the provider has enough configuration (token, etc.) to attempt a fetch.
    var isConfigured: Bool { get }
    /// Which config keys this provider needs, for the settings UI.
    var requiredCredentials: [CredentialField] { get }
    /// Compact name for the status item. Defaults to `name`.
    var menuTitle: String { get }

    func fetch() async throws -> QuotaSnapshot
}

extension QuotaProvider {
    var menuTitle: String { name }
}

/// Display formatting shared by the status item and the popover.
enum QuantityFormat {
    static func string(_ value: Double, unit: String) -> String {
        if isMoney(unit) {
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0f", value)
            }
            return String(format: "%.2f", value)
        }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        if value.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(value)) }
        return String(format: "%.2f", value)
    }

    static func isMoney(_ unit: String) -> Bool {
        switch unit.uppercased() {
        case "USD", "CNY", "EUR", "GBP", "JPY", "RMB":
            return true
        default:
            return false
        }
    }
}

/// A credential the user must supply for a provider.
struct CredentialField: Sendable {
    /// Config key, e.g. "apiKey", "baseUrl".
    var key: String
    var label: String
    /// Render as a secure field (password/token) in the UI.
    var isSecret: Bool
    /// Prefill value if a sensible default exists (e.g. a base URL).
    var placeholder: String?
}
