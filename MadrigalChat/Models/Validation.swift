import Foundation

// What each editable object needs before its editor can be left. Editors
// show these issues inline and block Done (and swipe or Esc) until the list
// is empty. Keep the checks pure, so they're testable without a view.

extension String {
    /// Empty once surrounding whitespace is trimmed.
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension Project {
    var validationIssues: [String] {
        name.isBlank ? ["Name is required."] : []
    }

    var isValid: Bool { validationIssues.isEmpty }
}

extension Agent {
    func validationIssues(providers: [ProviderConfig]) -> [String] {
        var issues: [String] = []
        if name.isBlank { issues.append("Name is required.") }
        if providers.isEmpty {
            issues.append("Add a provider first.")
        } else if !providers.contains(where: { $0.keychainKey == providerKeychainKey }) {
            issues.append("Choose a provider.")
        }
        return issues
    }

    func isValid(providers: [ProviderConfig]) -> Bool {
        validationIssues(providers: providers).isEmpty
    }
}

extension ProviderConfig {
    /// `hasSecret` is true when a secret is saved in the Keychain or typed
    /// into the editor but not yet saved.
    func validationIssues(hasSecret: Bool) -> [String] {
        var issues: [String] = []
        if name.isBlank { issues.append("Name is required.") }

        switch kind {
        case .openAICompatible where preset.editsBaseURL || preset.isCustom:
            if baseURL.isBlank {
                issues.append("Base URL is required.")
            } else if !Self.isWebURL(baseURL) {
                issues.append("Base URL must be an http:// or https:// address.")
            } else if let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let problem = Self.plainHTTPProblem(url) {
                issues.append(problem)
            }
        case .cloudflareWorkersAI:
            if cloudflareAccountID.isBlank { issues.append("Account ID is required.") }
        default:
            break
        }

        if needsSecret, !hasSecret {
            issues.append("\(kind.secretFieldLabel) is required.")
        }

        if supportsWebSearch, webSearchMode != .off, webSearchBackend == .searxng {
            if searxngURL.isBlank {
                issues.append("SearXNG URL is required.")
            } else if !Self.isWebURL(searxngURL) {
                issues.append("SearXNG URL must be an http:// or https:// address.")
            }
        }
        return issues
    }

    func isValid(hasSecret: Bool) -> Bool {
        validationIssues(hasSecret: hasSecret).isEmpty
    }

    /// An http(s) URL with a host, ignoring surrounding whitespace.
    nonisolated static func isWebURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }
}

extension Conversation {
    /// A chat nothing was ever sent in. It's deleted when the user leaves it
    /// instead of piling up as "New Chat" rows.
    var isDisposable: Bool { (messages ?? []).isEmpty }
}
