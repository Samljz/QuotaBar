import SwiftUI

@main
struct QuotaBarApp: App {
    @State private var store: QuotaStore

    /// `QuotaBar --dump` fetches every provider once and prints the resulting
    /// quota snapshots as text, then exits. Used to verify the providers end to
    /// end without a UI. It prints quota figures, never credentials.
    init() {
        if CommandLine.arguments.contains("--dump") {
            Dump.run()
        }
        // App.init runs once. Starting here — rather than in QuotaStore.init —
        // avoids a refresh loop for every discarded @State initial value.
        let store = QuotaStore(providers: ProviderRegistry.make())
        _store = State(initialValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            Image(systemName: "gauge")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
