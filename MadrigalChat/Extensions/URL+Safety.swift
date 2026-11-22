import Foundation

extension URL {
    /// Schemes the app will open from untrusted text: model output and
    /// search results. Anything else (`tel:`, `sms:`, app deep links) could
    /// be planted by a web page the model read.
    nonisolated static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    /// True if a tap on this link may open it.
    nonisolated var isSafeToOpen: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return Self.openableSchemes.contains(scheme)
    }

    /// True if the web page reader may fetch it: http(s) to a public host.
    /// Search results can point anywhere, and `NSAllowsLocalNetworking`
    /// would otherwise let a poisoned result make the device request
    /// routers and other machines on the LAN.
    nonisolated var isPublicWebPage: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = host(), !host.isEmpty else { return false }
        // Every IP literal counts as local there, which is stricter than
        // needed but fine: search results are almost never bare addresses.
        return !ProviderConfig.isLocalNetworkHost(host)
    }
}
