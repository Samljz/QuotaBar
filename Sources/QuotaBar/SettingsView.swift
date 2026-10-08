import SwiftUI

/// Per-provider credential entry. Secrets go to the Keychain.
///
/// Secret fields are deliberately never prefilled or echoed back: showing a
/// stored token in a text field both leaks it on screen and lets a programmatic
/// prefill masquerade as user input. They show "已配置" instead.
struct SettingsView: View {
    @Bindable var store: QuotaStore
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var config = ConfigStore()
    /// Field drafts, keyed by "providerId.fieldKey". Secrets stay empty until typed.
    @State private var drafts: [String: String] = [:]
    /// Secrets the user has typed during this edit session only.
    @State private var pendingSecrets: [String: String] = [:]
    @State private var configuredSecrets: Set<String> = []
    @State private var saveError: String?
    @State private var didCommit = false
    /// False until drafts have been loaded, so a disappear-before-appear cannot
    /// write empty fields over the saved config.
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                ForEach(store.providers, id: \.id) { provider in
                    Section {
                        ForEach(provider.requiredCredentials, id: \.key) { field in
                            fieldView(provider: provider, field: field)
                        }
                    } header: {
                        Text(provider.name)
                    }
                }
                Section("刷新") {
                    Picker("刷新间隔", selection: $store.refreshInterval) {
                        Text("1 分钟").tag(TimeInterval(60))
                        Text("5 分钟").tag(TimeInterval(300))
                        Text("15 分钟").tag(TimeInterval(900))
                        Text("30 分钟").tag(TimeInterval(1800))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("Token 与 Cookie 保存在 macOS 钥匙串中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("完成") {
                        if commitDrafts() {
                            dismiss()
                            onClose?()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(10)
        }
        .frame(width: 480, height: 540)
        .onAppear(perform: loadNonSecretDrafts)
        .onDisappear(perform: commitIfNeeded)
    }

    @ViewBuilder
    private func fieldView(provider: any QuotaProvider, field: CredentialField) -> some View {
        let key = draftKey(provider, field)

        if field.isSecret {
            VStack(alignment: .leading, spacing: 3) {
                SecureField(field.label, text: binding(for: key), prompt: Text(field.placeholder ?? "粘贴凭据"))
                if configuredSecrets.contains(key) {
                    HStack(spacing: 8) {
                        Text("已配置（留空则保持不变）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清除") {
                            clearSecret(provider: provider, field: field, key: key)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                    }
                }
            }
        } else {
            TextField(field.label, text: binding(for: key), prompt: Text(field.placeholder ?? ""))
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { drafts[key] ?? "" },
            set: { newValue in
                drafts[key] = newValue
                if isSecretKey(key) {
                    // Secrets stay in memory until the sheet closes, so a
                    // half-typed token is never committed.
                    pendingSecrets[key] = newValue
                }
            }
        )
    }

    /// "providerId.fieldKey" -> is this a secret field?
    private func isSecretKey(_ key: String) -> Bool {
        for provider in store.providers {
            for field in provider.requiredCredentials
            where draftKey(provider, field) == key {
                return field.isSecret
            }
        }
        return false
    }

    private func draftKey(_ provider: any QuotaProvider, _ field: CredentialField) -> String {
        "\(provider.id).\(field.key)"
    }

    /// Write drafts once, when the settings window closes.
    /// Empty non-secret fields clear the stored value. Empty secrets keep
    /// whatever is already in the Keychain.
    private func commitDrafts() -> Bool {
        guard didLoad else { return false }
        guard !didCommit else { return saveError == nil }
        var errors: [String] = []
        for provider in store.providers {
            for field in provider.requiredCredentials {
                let key = draftKey(provider, field)
                if field.isSecret {
                    let typed = pendingSecrets[key] ?? ""
                    guard !typed.isEmpty else { continue }
                    do {
                        try config.setSecret(typed, provider: provider.id, key: field.key)
                        configuredSecrets.insert(key)
                    } catch {
                        errors.append("\(provider.name)：\(error.localizedDescription)")
                    }
                } else {
                    config.setValue(drafts[key] ?? "", provider: provider.id, key: field.key)
                }
            }
        }
        if errors.isEmpty {
            pendingSecrets.removeAll()
            saveError = nil
            didCommit = true
            return true
        }
        saveError = errors.joined(separator: "\n")
        return false
    }

    private func clearSecret(provider: any QuotaProvider, field: CredentialField, key: String) {
        do {
            try config.removeSecret(provider: provider.id, key: field.key)
            configuredSecrets.remove(key)
            pendingSecrets.removeValue(forKey: key)
            drafts[key] = ""
            saveError = nil
        } catch {
            saveError = "\(provider.name)：\(error.localizedDescription)"
        }
    }

    private func commitIfNeeded() {
        if commitDrafts() {
            Task { await store.refreshAll() }
        }
    }

    /// Prefill non-secret fields only, and note which secrets already exist.
    private func loadNonSecretDrafts() {
        for provider in store.providers {
            for field in provider.requiredCredentials {
                let key = draftKey(provider, field)
                if field.isSecret {
                    if config.secret(provider: provider.id, key: field.key) != nil {
                        configuredSecrets.insert(key)
                    }
                } else if let existing = config.value(provider: provider.id, key: field.key) {
                    drafts[key] = existing
                }
            }
        }
        didLoad = true
    }
}
