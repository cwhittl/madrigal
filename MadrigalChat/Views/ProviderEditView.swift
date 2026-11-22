import SwiftUI
import SwiftData

/// Edits one provider. Only the fields its preset needs are shown: hosted
/// services just take a key, Cloudflare an account ID and token, local
/// servers a base URL, Apple Intelligence nothing but a status, on-device
/// MLX a model manager, and Custom gets everything. See spec section 6.4.
struct ProviderEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Query(sort: \ProviderConfig.createdAt) private var allProviders: [ProviderConfig]

    @Bindable var config: ProviderConfig
    /// Just created from "Add Provider", so it can be discarded instead of
    /// fixed.
    var isNew: Bool = false
    @State private var viewModel = ProviderEditViewModel()
    @State private var confirmingDelete = false
    @State private var contextLimitText: String = ""

    private var preset: ProviderPreset { config.preset }

    /// A typed key counts: it's saved when the sheet closes.
    private var issues: [String] {
        let hasSecret = viewModel.hasStoredSecret || !viewModel.secretDraft.isBlank
        return config.validationIssues(hasSecret: hasSecret)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $config.name)
            } header: {
                Text("Provider")
            } footer: {
                ValidationIssuesView(issues: issues)
            }

            if config.kind == .cloudflareWorkersAI {
                cloudflareSection
            } else if config.kind == .appleIntelligence {
                appleIntelligenceSection
            } else if config.kind == .localMLX {
                LocalModelsSection(config: config)
            } else if preset.editsBaseURL {
                openAISection
            }

            if config.supportsWebSearch {
                WebSearchSection(config: config, viewModel: viewModel)
            }

            if preset.isCustom {
                cfAccessSection

                Section {
                    Toggle("Requires \(config.kind.secretFieldLabel)", isOn: $config.apiKeyRequired)
                }
            }

            if config.needsSecret {
                secretSection
            }

            modelSection

            generationSection

            Section {
                Toggle("Use as default provider", isOn: Binding(
                    get: { config.isDefault },
                    set: { newValue in
                        // Exactly one default at a time.
                        if newValue {
                            SettingsActions.setDefault(config, among: allProviders)
                        } else {
                            config.isDefault = false
                        }
                    }
                ))
            }

            Section {
                Button("Delete Provider", role: .destructive) {
                    confirmingDelete = true
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(config.name.isEmpty ? "Provider" : config.name)
        .onAppear {
            viewModel.refreshSecretState(for: config)
            contextLimitText = config.contextCharacterLimit > 0 ? String(config.contextCharacterLimit) : ""
        }
        // Swipe-to-dismiss on iOS and Esc on macOS skip the Done button, and
        // a typed key must not be silently thrown away. A deleted provider
        // must not get its secret written back, though.
        .onDisappear {
            if config.isLive { viewModel.commitSecretIfNeeded(for: config) }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    viewModel.commitSecretIfNeeded(for: config)
                    dismiss()
                }
                .disabled(!issues.isEmpty)
            }
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    // Deleting first means onDisappear won't save a typed
                    // key for it.
                    Button("Discard", role: .destructive) {
                        SettingsActions.delete(config, from: allProviders, context: context)
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(!issues.isEmpty)
        .confirmationDialog("Delete \(config.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Provider", role: .destructive) {
                SettingsActions.delete(config, from: allProviders, context: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove the provider and its saved API key.")
        }
    }

    // MARK: - Kind-specific fields

    private var cfAccessSection: some View {
        Section {
            TextField("Client ID", text: $config.cfAccessClientID)
                .identifierEntry()

            SecureField(
                viewModel.hasStoredCFAccessSecret ? "Client Secret (saved, enter a new one to replace it)" : "Client Secret",
                text: $viewModel.cfAccessSecretDraft
            )
            .identifierEntry()

            if viewModel.hasStoredCFAccessSecret {
                Button("Remove saved client secret", role: .destructive) {
                    viewModel.clearCFAccessSecret(for: config)
                }
            }
        } header: {
            Text("Cloudflare Access")
        } footer: {
            Text("Required when the endpoint is protected by Cloudflare Access. The Client ID and Client Secret are issued from the Cloudflare Zero Trust dashboard. The secret is stored in the Keychain.")
        }
    }

    private var openAISection: some View {
        Section {
            TextField("Base URL", text: $config.baseURL)
                .identifierEntry(url: true)
            if let problem = config.configurationProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Endpoint")
        } footer: {
            Text(preset.baseURLHint)
        }
    }

    private var cloudflareSection: some View {
        Section {
            TextField("Account ID", text: $config.cloudflareAccountID)
                .identifierEntry()

            if let problem = config.configurationProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Endpoint") {
                    Text(config.resolvedBaseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Cloudflare account")
        } footer: {
            Text("Find the account ID in the Cloudflare dashboard sidebar, or in the URL of your account's overview page. It's 32 hexadecimal characters.")
        }
    }

    private var appleIntelligenceSection: some View {
        Section {
            if let problem = config.configurationProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("Ready", systemImage: "checkmark.circle")
            }
        } header: {
            Text("On-device model")
        } footer: {
            Text("Runs privately on this device with no account or key. Its context is small, about 4,000 tokens, so long chats and project files are trimmed to fit.")
        }
    }

    // MARK: - Secret

    private var secretSection: some View {
        Section {
            if let masked = viewModel.storedSecretMask, viewModel.secretDraft.isEmpty {
                LabeledContent("Saved") {
                    Text(masked)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            SecureField(
                viewModel.hasStoredSecret
                    ? "Enter a new \(config.kind.secretFieldLabel.lowercased()) to replace it"
                    : config.kind.secretFieldLabel,
                text: $viewModel.secretDraft
            )
            .identifierEntry()

            if viewModel.hasStoredSecret {
                Button("Remove saved \(config.kind.secretFieldLabel.lowercased())", role: .destructive) {
                    viewModel.clearSecret(for: config)
                }
            }

            if let error = viewModel.saveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(config.kind.secretFieldLabel)
        } footer: {
            Text(preset.secretHint)
        }
    }

    // MARK: - Generation

    private var generationSection: some View {
        Section {
            GenerationFields(temperature: $config.temperature, maxTokens: $config.maxTokens, maxTokensPrompt: "Provider default")

            TextField("Context limit (characters)", text: $contextLimitText,
                      prompt: Text("\(ContextAssembler.totalCharacterCap)"))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: contextLimitText) { _, text in
                    config.contextCharacterLimit = Int(text.filter(\.isNumber)) ?? 0
                }
        } header: {
            Text("Generation")
        } footer: {
            Text("Leave these alone to use each model's defaults. The context limit is how much chat history is sent with each message, roughly 4 characters per token: lower it for small-context models, such as 30000 for an 8k-token model.")
        }
    }

    // MARK: - Models

    private var modelSection: some View {
        Section {
            Button {
                Task { await viewModel.fetchModels(for: config) }
            } label: {
                HStack {
                    Label("Fetch models", systemImage: "arrow.clockwise")
                    if viewModel.isFetchingModels {
                        Spacer()
                        MadrigalIndicator(size: .small)
                    }
                }
            }
            .disabled(viewModel.isFetchingModels)

            if let status = viewModel.fetchStatus {
                Label(status, systemImage: viewModel.fetchFailed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let models = config.modelIDs
            if !models.isEmpty {
                ModelIDPicker(title: "Preferred model", noneLabel: "None",
                              models: models, selection: $config.defaultModelID,
                              showsNone: config.kind != .localMLX)
            }

            // An MLX model has to be downloaded above before it can be used.
            if config.kind != .localMLX {
                ManualModelField { config.useManualModel($0) }
            }

            if !config.defaultModelID.isEmpty {
                LabeledContent("Selected") {
                    Text(config.defaultModelID)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !models.isEmpty {
                ModelIDPicker(title: "Project summary model", noneLabel: "Same as chat",
                              models: models, selection: $config.summaryModel)
            }
        } header: {
            Text("Models")
        } footer: {
            switch config.kind {
            case .cloudflareWorkersAI:
                Text("Workers AI model IDs look like @cf/meta/llama-3.1-8b-instruct. If the list can't be fetched, known IDs are offered instead.")
            case .appleIntelligence:
                Text("Apple Intelligence has a single on-device model, \(AppleIntelligence.modelID).")
            case .localMLX:
                Text("Lists the models downloaded on this device. Download and delete them above. These choices stay on this device.")
            case .openAICompatible:
                Text("Some endpoints don't serve a model list. You can always type an ID by hand.")
            }
        }
    }
}
