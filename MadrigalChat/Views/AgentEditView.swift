import SwiftUI
import SwiftData

/// Edits one agent: its look, the provider and model it talks to, its
/// instructions, and optional sampling overrides.
struct AgentEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]

    @Bindable var agent: Agent
    /// Just created from "Add Agent", so it can be discarded instead of
    /// fixed.
    var isNew: Bool = false

    private var provider: ProviderConfig? {
        providers.first { $0.keychainKey == agent.providerKeychainKey }
    }

    private var issues: [String] { agent.validationIssues(providers: providers) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $agent.name)
                IconPicker(selection: $agent.iconSystemName)
                ColorPalettePicker(selection: $agent.colorHex)
            } header: {
                Text("Agent")
            } footer: {
                ValidationIssuesView(issues: issues)
            }

            modelSection

            Section {
                TextEditor(text: $agent.instructions)
                    .frame(minHeight: 120)
                    .font(.body)
                Toggle("Replace global instructions", isOn: $agent.replacesGlobalInstructions)
            } header: {
                Text("Instructions")
            } footer: {
                Text(agent.replacesGlobalInstructions
                     ? "Sent instead of your instructions from Settings. Project instructions still follow."
                     : "Sent after your instructions from Settings and before a project's.")
            }

            generationSection
        }
        .formStyle(.grouped)
        .navigationTitle(agent.name.isEmpty ? "Agent" : agent.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .disabled(!issues.isEmpty)
            }
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) {
                        context.delete(agent)
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(!issues.isEmpty)
        .onAppear {
            if provider == nil, let fallback = providers.defaultProvider {
                agent.providerKeychainKey = fallback.keychainKey
            }
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            if providers.isEmpty {
                Text("Add a provider first.")
                    .foregroundStyle(.secondary)
            } else {
                // Only bind tags the Picker has: a deleted provider reads as
                // blank otherwise, with an invalid-selection warning.
                Picker("Provider", selection: Binding(
                    get: { provider?.keychainKey ?? "" },
                    set: { key in
                        guard key != agent.providerKeychainKey else { return }
                        agent.providerKeychainKey = key
                        agent.modelID = ""
                    }
                )) {
                    if provider == nil { Text("None").tag("") }
                    ForEach(providers) { config in
                        Text(config.name).tag(config.keychainKey)
                    }
                }
            }

            if let provider, !provider.modelIDs.isEmpty {
                ModelIDPicker(title: "Model", noneLabel: "Provider's preferred",
                              models: provider.modelIDs, selection: $agent.modelID)
            }

            if let provider {
                // An MLX model has to be downloaded before it can be used.
                if provider.kind != .localMLX {
                    ManualModelField { agent.modelID = $0 }
                }

                if !agent.modelID.isEmpty {
                    LabeledContent("Selected") {
                        Text(agent.modelID)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Fetch a provider's models in its settings to list them here.")
        }
    }

    // MARK: - Generation

    private var generationSection: some View {
        Section {
            GenerationFields(temperature: $agent.temperature, maxTokens: $agent.maxTokens, maxTokensPrompt: "Provider setting")
        } header: {
            Text("Generation")
        } footer: {
            Text("Leave these alone to use the provider's settings.")
        }
    }
}
