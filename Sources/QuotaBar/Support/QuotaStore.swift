import Foundation
import SwiftUI

/// Owns all providers and their latest fetch results; drives periodic refresh.
@MainActor
@Observable
final class QuotaStore {
    private(set) var states: [String: ProviderState] = [:]
    private(set) var lastRefresh: Date?

    /// How often to re-poll providers, in seconds. Persisted across launches.
    var refreshInterval: TimeInterval = 300 {
        didSet {
            guard refreshInterval != oldValue else { return }
            config.setRefreshInterval(refreshInterval)
            guard refreshTask != nil else { return }
            stop()
            start()
        }
    }

    let providers: [any QuotaProvider]
    private var refreshTask: Task<Void, Never>?
    private let config: ConfigStore

    init(providers: [any QuotaProvider], config: ConfigStore = ConfigStore()) {
        self.providers = providers
        self.config = config
        if let saved = config.refreshInterval, saved >= 60 {
            self.refreshInterval = saved
        }
        for provider in providers {
            states[provider.id] = .idle
        }
    }

    func state(for provider: any QuotaProvider) -> ProviderState {
        states[provider.id] ?? .idle
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                guard let interval = self?.refreshInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { [weak self] in
                    await self?.refresh(provider)
                }
            }
        }
        lastRefresh = Date()
    }

    func refresh(_ provider: any QuotaProvider) async {
        guard provider.isConfigured else {
            states[provider.id] = .failed("未配置凭据")
            return
        }
        states[provider.id] = .loading
        do {
            let snapshot = try await provider.fetch()
            states[provider.id] = .ready(snapshot)
        } catch {
            states[provider.id] = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if let http = error as? HTTPError { return http.description }
        if error is DecodingError { return "响应格式异常" }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "网络未连接"
            case NSURLErrorTimedOut: return "请求超时"
            default: break
            }
        }
        return error.localizedDescription
    }
}
