import Foundation

/// `QuotaBar --dump`: fetch every provider once, print quota snapshots, exit.
///
/// Prints quota figures only — never tokens, cookies, or other credentials.
/// `--dump-raw` additionally prints each provider's raw response body, which is
/// usage data and safe to inspect while debugging a schema mismatch.
enum Dump {
    static func run() -> Never {
        let raw = CommandLine.arguments.contains("--dump-raw")

        // Kick off the work and pump the main run loop until it exits the
        // process. This avoids blocking waits inside async contexts.
        Task {
            let providers = ProviderRegistry.make()
            let results = await withTaskGroup(
                of: (String, Result<QuotaSnapshot, Error>).self,
                returning: [(String, Result<QuotaSnapshot, Error>)].self
            ) { group in
                for provider in providers {
                    group.addTask {
                        let result: Result<QuotaSnapshot, Error>
                        do {
                            guard provider.isConfigured else {
                                throw HTTPError(status: 401, body: "未配置")
                            }
                            result = .success(try await provider.fetch())
                        } catch {
                            result = .failure(error)
                        }
                        return (provider.name, result)
                    }
                }

                var collected: [(String, Result<QuotaSnapshot, Error>)] = []
                for await entry in group {
                    collected.append(entry)
                }
                return collected
            }

            // Preserve provider ordering for readable output.
            let ordered = providers.compactMap { provider in
                results.first { $0.0 == provider.name }
            }

            for (name, result) in ordered {
                switch result {
                case .success(let snapshot):
                    print("\(name) [\(snapshot.billing.rawValue)]:")
                    if let plan = snapshot.planName {
                        print("  plan: \(plan)")
                    }
                    for meter in snapshot.meters {
                        print("  - [\(meter.kind.rawValue)] \(meter.label): \(describe(meter))")
                    }
                case .failure(let error):
                    let message = (error as? HTTPError)?.description
                        ?? error.localizedDescription
                    print("\(name): ERROR \(message)")
                }
                print("")
            }

            if raw {
                await RawDump.printAll(providers: providers)
            }

            exit(0)
        }

        RunLoop.main.run()
        exit(0)
    }

    private static func describe(_ meter: Meter) -> String {
        var parts: [String] = []
        if let consumed = meter.consumedFraction {
            parts.append(String(format: "%.1f%% used", consumed * 100))
        }
        if let used = meter.used, let total = meter.total {
            parts.append("\(QuantityFormat.string(used, unit: meter.unit))/\(QuantityFormat.string(total, unit: meter.unit)) \(meter.unit)")
        } else if let total = meter.total {
            parts.append("\(QuantityFormat.string(total, unit: meter.unit)) \(meter.unit)")
        }
        if let resets = meter.resetsAt {
            parts.append("resets \(resets.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
}
