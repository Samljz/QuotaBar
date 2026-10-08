import Foundation

/// Builds the list of enabled providers. Add a provider here to surface it.
enum ProviderRegistry {
    static func make() -> [any QuotaProvider] {
        let config = ConfigStore()
        return [
            GLMProvider(config: config),
            MiMoProvider(config: config),
            DeepSeekProvider(config: config),
            CursorProvider(config: config),
            CodexProvider(config: config),
        ]
    }
}
