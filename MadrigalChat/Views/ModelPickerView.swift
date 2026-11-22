import SwiftUI
import SwiftData

/// Picks the provider and model for one conversation. Model IDs are free text
/// as well as a list, because discovery is optional for every provider kind.
struct ModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @Bindable var conversation: Conversation

    var body: some View {
        Form {
            if !agents.isEmpty {
                Section("Agents") {
                    ForEach(agents) { agent in
                        Button {
                            conversation.apply(agent, providers: providers)
                            dismiss()
                        } label: {
                            AgentRow(agent: agent, providers: providers) {
                                if conversation.agentID == agent.idString {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ForEach(providers) { config in
                Section(config.name) {
                    let models = config.modelIDs
                    if models.isEmpty {
                        Text(config.kind == .localMLX
                             ? "No models downloaded on this device. Download one in Settings."
                             : "No models fetched yet. Use Settings to fetch, or type an ID below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(models, id: \.self) { model in
                        Button {
                            choose(config: config, model: model)
                        } label: {
                            HStack {
                                if config.kind == .localMLX {
                                    LocalModelPickerLabel(modelID: model)
                                } else {
                                    Text(model)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if conversation.agentID.isEmpty,
                                   conversation.providerKeychainKey == config.keychainKey,
                                   conversation.chosenModel(config: config) == model {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .fullRowTappable()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Enter a model ID") {
                ManualModelField(placeholder: "for example @cf/meta/llama-3.1-8b-instruct",
                                 buttonTitle: "Use this model", stacked: true) { model in
                    if let config = conversation.resolveConfig(among: providers) {
                        choose(config: config, model: model)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Model & Agent")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    /// A raw model, so any agent is dropped.
    private func choose(config: ProviderConfig, model: String) {
        conversation.apply(model: model, config: config)
        dismiss()
    }
}
