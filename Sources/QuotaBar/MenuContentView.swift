import SwiftUI

/// Dropdown panel under the menu bar icon.
struct MenuContentView: View {
    @Bindable var store: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // A ScrollView inside MenuBarExtra reports a zero ideal height, so the
            // provider rows vanish and only the header and footer remain.
            ViewThatFits(in: .vertical) {
                providerList
                ScrollView { providerList }
                    .frame(height: 560)
            }
            footer
        }
        .frame(width: 300)
    }

    private var providerList: some View {
        VStack(spacing: 6) {
            ForEach(store.providers, id: \.id) { provider in
                ProviderCard(provider: provider, state: store.state(for: provider))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("额度")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let last = store.lastRefresh {
                Text(last.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            PanelButton(symbol: "arrow.clockwise", help: "刷新", disabled: isRefreshing) {
                Task { await store.refreshAll() }
            }
            Spacer()
            PanelButton(symbol: "gearshape", help: "设置") {
                SettingsPanel.show(store: store)
            }
            PanelButton(symbol: "power", help: "退出") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var isRefreshing: Bool {
        store.providers.contains { provider in
            if case .loading = store.state(for: provider) { return true }
            return false
        }
    }

}

/// Menu-bar apps have no app menu, so the SwiftUI Settings scene never opens.
/// This window is created directly and brought in front of the dropdown.
@MainActor
private final class SettingsPanel: NSObject, NSWindowDelegate {
    static let shared = SettingsPanel()
    private var window: NSWindow?

    static func show(store: QuotaStore) {
        shared.present(store: store)
    }

    private func present(store: QuotaStore) {
        let window = self.window ?? makeWindow(store: store)
        self.window = window
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func makeWindow(store: QuotaStore) -> NSWindow {
        let root = SettingsView(store: store) { [weak self] in
            self?.window?.performClose(nil)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowDidClose(_ notification: Notification) {
        window = nil
    }
}

private struct PanelButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }
}

/// One provider inside the dropdown.
private struct ProviderCard: View {
    let provider: any QuotaProvider
    let state: ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            switch state {
            case .idle:
                Text("等待刷新")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            case .ready(let snapshot):
                meters(snapshot)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var symbol: String {
        switch provider.id {
        case "cursor": return "cursorarrow.rays"
        case "codex": return "terminal"
        case "glm": return "sparkle"
        case "deepseek": return "bubble.left.and.bubble.right"
        case "mimo": return "wave.3.right"
        default: return "circle"
        }
    }

    private var statusText: String {
        switch state {
        case .ready(let snapshot):
            return snapshot.planName ?? ""
        case .failed:
            return "失败"
        case .loading:
            return "刷新中"
        case .idle:
            return ""
        }
    }

    private var statusColor: Color {
        if case .failed = state { return .orange }
        return .secondary
    }

    @ViewBuilder
    private func meters(_ snapshot: QuotaSnapshot) -> some View {
        let quotas = snapshot.meters.filter { $0.kind == .quota }
        let balances = snapshot.meters.filter { $0.kind == .balance }
        let counters = snapshot.meters.filter { $0.kind == .counter }
        let headlineIsBalance = quotas.isEmpty

        VStack(alignment: .leading, spacing: 8) {
            if let primary = quotas.first {
                QuotaLine(meter: primary, prominent: true)
                ForEach(Array(quotas.dropFirst())) { meter in
                    QuotaLine(meter: meter, prominent: false)
                }
            }
            ForEach(balances) { meter in
                BalanceLine(meter: meter, prominent: headlineIsBalance && meter.id == balances.first?.id)
            }
            if !counters.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(counters) { meter in
                        CounterLine(meter: meter)
                    }
                }
            }
        }
    }
}

private struct QuotaLine: View {
    let meter: Meter
    let prominent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 5 : 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label)
                    .font(.system(size: prominent ? 12 : 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.system(size: prominent ? 13 : 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(usageColor)
            }
            if let fraction = meter.consumedFraction {
                UsageBar(fraction: fraction, color: usageColor, height: prominent ? 6 : 4)
            }
            if let resets = meter.resetsAt {
                Text("\(resets.formatted(date: .abbreviated, time: .shortened)) 重置")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var valueText: String {
        if let used = meter.used, let total = meter.total {
            return "\(QuantityFormat.string(used, unit: meter.unit))/\(QuantityFormat.string(total, unit: meter.unit)) \(meter.unit)"
        }
        if let consumed = meter.consumedFraction {
            return "\(Int((consumed * 100).rounded()))%"
        }
        if let total = meter.total {
            return "\(QuantityFormat.string(total, unit: meter.unit)) \(meter.unit)"
        }
        return "—"
    }

    private var usageColor: Color {
        guard let consumed = meter.consumedFraction else { return .secondary }
        switch consumed {
        case ..<0.65: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = max(height, geo.size.width * min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: width)
            }
        }
        .frame(height: height)
    }
}

private struct BalanceLine: View {
    let meter: Meter
    let prominent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(meter.label)
                .font(.system(size: prominent ? 12 : 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(amount)
                .font(.system(size: prominent ? 18 : 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(amountColor)
        }
    }

    private var amount: String {
        guard let total = meter.total else { return "—" }
        let number = QuantityFormat.string(total, unit: meter.unit)
        return meter.unit.isEmpty ? number : "\(number) \(meter.unit)"
    }

    private var amountColor: Color {
        guard let total = meter.total else { return .secondary }
        return total <= 0 ? .red : .primary
    }
}

private struct CounterLine: View {
    let meter: Meter

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(meter.label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var value: String {
        if let used = meter.used, let total = meter.total {
            return "\(QuantityFormat.string(used, unit: meter.unit))/\(QuantityFormat.string(total, unit: meter.unit)) \(meter.unit)"
        }
        if let total = meter.total {
            let number = QuantityFormat.string(total, unit: meter.unit)
            return meter.unit.isEmpty ? number : "\(number) \(meter.unit)"
        }
        return "—"
    }
}
