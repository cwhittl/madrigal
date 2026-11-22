import SwiftUI

/// Temperature and max tokens overrides, for a provider or an agent. nil
/// leaves each to whatever comes below.
struct GenerationFields: View {
    @Binding var temperature: Double?
    @Binding var maxTokens: Int?
    /// What an empty max tokens field means.
    let maxTokensPrompt: String

    @State private var maxTokensText = ""

    var body: some View {
        Toggle("Custom temperature", isOn: Binding(
            get: { temperature != nil },
            set: { temperature = $0 ? 0.7 : nil }
        ))
        if let temperature {
            HStack {
                Slider(
                    value: Binding(get: { temperature }, set: { self.temperature = ($0 * 10).rounded() / 10 }),
                    in: 0...2
                )
                Text(temperature.formatted(.number.precision(.fractionLength(1))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Temperature")
        }

        TextField("Max tokens", text: $maxTokensText, prompt: Text(maxTokensPrompt))
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .onAppear { maxTokensText = maxTokens.map(String.init) ?? "" }
            .onChange(of: maxTokensText) { _, text in
                maxTokens = Int(text.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
            }
    }
}

/// Picks one of a provider's model IDs, with `noneLabel` for "".
struct ModelIDPicker: View {
    let title: String
    let noneLabel: String
    let models: [String]
    @Binding var selection: String
    /// Off where an empty selection can't stick, such as an MLX provider's
    /// preferred model, which falls back to a download.
    var showsNone = true

    var body: some View {
        // Only binds a value that's one of the tags: otherwise SwiftUI logs
        // an invalid-selection warning and renders blank.
        Picker(title, selection: Binding(
            get: { models.contains(selection) ? selection : showsNone ? "" : models.first ?? "" },
            set: { selection = $0 }
        )) {
            if showsNone {
                Text(noneLabel).tag("")
            }
            ForEach(models, id: \.self) { model in
                Text(model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tag(model)
            }
        }
    }
}

/// A field for typing a model ID by hand, since model lists are optional.
/// `onUse` gets the trimmed ID.
struct ManualModelField: View {
    var placeholder = "Or type a model ID"
    var buttonTitle = "Use"
    /// The button on its own row instead of beside the field.
    var stacked = false
    let onUse: (String) -> Void

    @State private var text = ""

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if stacked {
            field
            button
        } else {
            HStack {
                field
                // Borderless so only the button responds, not the whole
                // Form row around the text field.
                button.buttonStyle(.borderless)
            }
        }
    }

    private var field: some View {
        TextField(placeholder, text: $text).identifierEntry()
    }

    private var button: some View {
        Button(buttonTitle) {
            guard !trimmed.isEmpty else { return }
            onUse(trimmed)
            text = ""
        }
        .disabled(trimmed.isEmpty)
    }
}

/// An agent in a list: its icon, name and provider, with `accessory` at
/// the end of the row.
struct AgentRow<Accessory: View>: View {
    let agent: Agent
    let providers: [ProviderConfig]
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Image(systemName: agent.iconSystemName)
                .foregroundStyle(Color(hex: agent.colorHex))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                Text(agent.subtitle(providers: providers))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            accessory
        }
        .fullRowTappable()
    }
}
