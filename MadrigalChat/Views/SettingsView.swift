import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.cloudSync) private var cloudSync
    /// Runs when Delete All Data is confirmed. The owner closes this sheet
    /// and deletes once it's gone.
    var onDeleteAll: () -> Void = {}
    /// Opens the provider presets right away, for "Add Provider" buttons
    /// elsewhere in the app.
    var addsProviderOnAppear = false

    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    @State private var editing: ProviderConfig?
    @State private var editingAgent: Agent?
    @State private var pendingEdit: ProviderConfig?
    @State private var showingPresets = false
    /// The presets open automatically once; `.task` reruns whenever the
    /// root view reappears, such as on coming back from a pushed screen.
    @State private var didAutoPresentPresets = false
    @State private var confirmingDeleteAll = false
    /// The provider or agent just created, so its editor offers Discard.
    @State private var newProviderID: PersistentIdentifier?
    @State private var newAgentID: PersistentIdentifier?
    /// Keychain keys of providers with no secret saved. Read from the
    /// Keychain when the list or an edit changes, never in `body`.
    @State private var keysMissingSecrets: Set<String> = []
    @AppStorage(AppConfig.globalInstructionsKey) private var globalInstructions = ""
    @AppStorage(AppConfig.appearanceKey) private var appearance: AppAppearance = .system
    @AppStorage(AppConfig.expandThinkingKey) private var expandThinking = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// Read when Settings appears and when the app returns, since the user
    /// may have just changed it in system settings.
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section {
                if providers.isEmpty {
                    Text("No providers yet. Add one to start chatting.")
                        .foregroundStyle(.secondary)
                }
                ForEach(providers) { config in
                    Button {
                        editing = config
                    } label: {
                        ProviderRow(config: config, isMissingSecret: keysMissingSecrets.contains(config.keychainKey))
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(config) }
                    }
                    .contextMenu {
                        Button("Edit") { editing = config }
                        Button("Delete", role: .destructive) { delete(config) }
                    }
                }

                Button {
                    showingPresets = true
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys, tokens, and other secrets are stored in the Keychain, never in iCloud records.")
            }

            agentsSection

            if providers.count > 1 {
                Section("Default") {
                    Picker("Default provider", selection: Binding(
                        get: { providers.defaultProvider?.persistentModelID ?? providers[0].persistentModelID },
                        set: { id in
                            if let match = providers.first(where: { $0.persistentModelID == id }) {
                                SettingsActions.setDefault(match, among: providers)
                            }
                        }
                    )) {
                        ForEach(providers) { config in
                            Text(config.name).tag(config.persistentModelID)
                        }
                    }
                }
            }

            Section {
                TextEditor(text: $globalInstructions)
                    .frame(minHeight: 90)
                    .font(.body)
            } header: {
                Text("Custom instructions")
            } footer: {
                Text("Sent with every chat on this device, for example how you'd like replies formatted. Projects add their own instructions after these.")
            }

            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show thinking while it streams", isOn: $expandThinking)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Reasoning models' thought process opens while they think. Off keeps it collapsed; tap to read it.")
            }

            if notificationsDenied {
                Section {
                    Label("Notifications are off", systemImage: "bell.slash")
                    if let url = ReplyNotifier.systemSettingsURL {
                        Button("Turn On in Settings") { openURL(url) }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Madrigal can't tell you when a reply finishes, pauses, or is cut off while you're in another app.")
                }
            }

            Section {
                NavigationLink("What gets sent, and where") {
                    DataDisclosureView()
                }
            } header: {
                Text("Privacy")
            }

            Section {
                if AppConfig.enableCloudKitSync, let cloudSync {
                    NavigationLink {
                        SyncStatusView(monitor: cloudSync)
                    } label: {
                        SyncStatusLabel(summary: cloudSync.summary)
                    }
                } else {
                    Label(AppConfig.enableCloudKitSync ? "Syncing with iCloud" : "Stored on this device only",
                          systemImage: AppConfig.enableCloudKitSync ? "checkmark.icloud" : "icloud.slash")
                        .foregroundStyle(.secondary)
                }
                Button("Delete All Data", role: .destructive) {
                    confirmingDeleteAll = true
                }
            } header: {
                Text("Data")
            } footer: {
                Text(AppConfig.enableCloudKitSync
                     ? "Chats and projects sync through your private iCloud database."
                     : "Sync is off. Everything stays on this device.")
            }

            Section {
                LabeledContent("Version", value: "\(AppConfig.version) (\(AppConfig.build))")
                Link("Help & Support", destination: AppConfig.supportURL)
                Link("Privacy Policy", destination: AppConfig.privacyPolicyURL)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            notificationsDenied = await ReplyNotifier.isDenied()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        // The editor is opened from onDismiss, not inline: SwiftUI won't
        // present a second sheet while the first is still going away, and the
        // new config's persistent ID is only stable after the save below.
        .sheet(isPresented: $showingPresets, onDismiss: {
            if let pending = pendingEdit {
                pendingEdit = nil
                newProviderID = pending.persistentModelID
                editing = pending
            }
        }) {
            NavigationStack {
                ProviderPresetPicker { preset in
                    let config = SettingsActions.makeProvider(from: preset, context: context, existing: providers)
                    context.saveOrLog("new provider")
                    pendingEdit = config
                    showingPresets = false
                }
            }
            .macSheetSize(minWidth: 420, minHeight: 380)
        }
        .sheet(item: $editingAgent, onDismiss: { newAgentID = nil }) { agent in
            NavigationStack {
                AgentEditView(agent: agent, isNew: agent.persistentModelID == newAgentID)
            }
            .macSheetSize(minWidth: 480, minHeight: 460)
        }
        .sheet(item: $editing, onDismiss: { newProviderID = nil }) { config in
            NavigationStack {
                ProviderEditView(config: config, isNew: config.persistentModelID == newProviderID)
            }
            .macSheetSize(minWidth: 520, minHeight: 460)
        }
        .task(id: providers.map(\.keychainKey)) { refreshMissingSecrets() }
        // Delayed: a nested sheet won't present while this one is still
        // animating in.
        .task {
            guard addsProviderOnAppear, !didAutoPresentPresets else { return }
            // Cancelled if the view goes away first: don't present then.
            guard (try? await Task.sleep(for: .milliseconds(350))) != nil else { return }
            didAutoPresentPresets = true
            showingPresets = true
        }
        // A secret may have been saved or removed in the edit sheet.
        .onChange(of: editing == nil) { _, closed in
            if closed { refreshMissingSecrets() }
        }
        .confirmationDialog("Delete everything?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete All Data", role: .destructive) {
                onDeleteAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(AppConfig.enableCloudKitSync
                 ? "Removes every chat, project, agent, and provider from all your devices signed in to this iCloud account, along with their saved keys. This can't be undone."
                 : "Removes every chat, project, agent, and provider on this device, along with their saved keys. This can't be undone.")
        }
    }

    private func delete(_ config: ProviderConfig) {
        SettingsActions.delete(config, from: providers, context: context)
    }

    private func refreshMissingSecrets() {
        #if DEBUG
        // Demo providers have no saved keys, and screenshots shouldn't say so.
        if ScreenshotDemo.isActive { return }
        #endif
        keysMissingSecrets = Set(providers
            .filter { $0.needsSecret && !KeychainService.hasKey(forKey: $0.keychainKey) }
            .map(\.keychainKey))
    }

    private var agentsSection: some View {
        Section {
            ForEach(agents) { agent in
                Button {
                    editingAgent = agent
                } label: {
                    AgentRow(agent: agent, providers: providers) {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", role: .destructive) { context.delete(agent) }
                }
                .contextMenu {
                    Button("Edit") { editingAgent = agent }
                    Button("Delete", role: .destructive) { context.delete(agent) }
                }
            }

            Button {
                let agent = SettingsActions.makeAgent(providers: providers, context: context)
                context.saveOrLog("new agent")
                newAgentID = agent.persistentModelID
                editingAgent = agent
            } label: {
                Label("Add Agent", systemImage: "plus")
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("An agent is a model with its own instructions. Pick one from a chat's model menu.")
        }
    }
}

/// A provider in the Settings list: its name, whether it's the default,
/// where it points, and a warning when its secret is missing.
private struct ProviderRow: View {
    let config: ProviderConfig
    let isMissingSecret: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name)
                    if config.isDefault {
                        Text("Default")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text(config.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isMissingSecret {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help("No \(config.kind.secretFieldLabel.lowercased()) saved")
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .fullRowTappable()
    }
}

struct ProviderPresetPicker: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (ProviderPreset) -> Void

    var body: some View {
        List(ProviderPreset.selectable) { preset in
            Button {
                onSelect(preset)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                    Text(Self.detail(for: preset))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .fullRowTappable()
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Add Provider")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private static func detail(for preset: ProviderPreset) -> String {
        switch preset.kind {
        case .cloudflareWorkersAI: return "Account ID and API token"
        case .appleIntelligence: return "Private, on this device"
        case .localMLX: return "Download open models to run on this device"
        case .openAICompatible: return preset.baseURL.isEmpty ? "Your own endpoint" : preset.baseURL
        }
    }
}
