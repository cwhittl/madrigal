import SwiftUI

/// An on-device provider's web search settings: the mode, the backend,
/// and what that backend needs.
struct WebSearchSection: View {
    @Bindable var config: ProviderConfig
    @Bindable var viewModel: ProviderEditViewModel

    var body: some View {
        Section {
            Picker("Search the web", selection: Binding(
                get: { config.webSearchMode },
                set: { config.webSearchMode = $0 }
            )) {
                ForEach(WebSearchMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if config.webSearchMode != .off {
                Picker("Search with", selection: Binding(
                    get: { config.webSearchBackend },
                    set: { config.webSearchBackend = $0 }
                )) {
                    ForEach(WebSearchBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                if config.webSearchBackend == .brave {
                    SecureField(
                        viewModel.hasStoredBraveKey ? "Brave API key (saved, enter a new one to replace it)" : "Brave API key",
                        text: $viewModel.braveKeyDraft
                    )
                    .identifierEntry()

                    if viewModel.hasStoredBraveKey {
                        Button("Remove saved Brave API key", role: .destructive) {
                            viewModel.clearBraveKey(for: config)
                        }
                    } else if viewModel.braveKeyDraft.isEmpty {
                        Label("Searches will fail until a key is saved.", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if config.webSearchBackend == .searxng {
                    TextField("SearXNG URL", text: $config.searxngURL, prompt: Text("https://search.example.com"))
                        .identifierEntry(url: true)
                    if let problem = config.webSearchProblem {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Web search")
        } footer: {
            Text(config.webSearchMode.settingsFooter(backend: config.webSearchBackend))
        }
    }
}

extension WebSearchMode {
    /// What the setting does and where queries go, under the setting.
    func settingsFooter(backend: WebSearchBackend) -> String {
        switch self {
        case .off:
            return "Lets the model look things up on the web, from this device, with a Brave Search API key, or through your own SearXNG server."
        case .always:
            return "Every message you send is searched first and the results are given to the model. This is the most reliable choice for on-device models. " + backend.privacyNote(mode: self)
        case .auto:
            return "The model searches when it thinks it needs to. Small on-device models often don't, and answer that they can't browse; if that happens, use Always search. " + backend.privacyNote(mode: self)
        }
    }
}

extension WebSearchBackend {
    /// Who sees searches with this backend, and what else a search contacts.
    func privacyNote(mode: WebSearchMode) -> String {
        let backend: String
        switch self {
        case .onDevice:
            backend = "Search queries go straight from this device to DuckDuckGo and Wikipedia, which see the query and your IP address. DuckDuckGo sometimes blocks searches from apps; Brave Search is more reliable. Replies are still generated on this device."
        case .brave:
            backend = "Search queries are sent to Brave with your API key, which you can get at api-dashboard.search.brave.com. The key is stored in the Keychain. Replies are still generated on this device."
        case .searxng:
            let note = "Search queries are sent to your SearXNG server. Replies are still generated on this device."
            backend = mode == .always ? note + " The server needs json in search.formats in its settings.yml." : note
        }
        return backend + " To answer from the results, the top result pages are opened from this device, and weather questions get a forecast from Open-Meteo."
    }
}
