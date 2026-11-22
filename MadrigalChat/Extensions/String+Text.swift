import Foundation

extension String {
    /// nil for an empty string, so `?? fallback` reads naturally.
    var nonEmpty: String? { isEmpty ? nil : self }

    /// At most `limit` characters, ending in an ellipsis when cut.
    func truncated(to limit: Int) -> String {
        count > limit ? String(prefix(max(limit - 1, 0))) + "\u{2026}" : self
    }

    /// Removes every trailing copy of `suffix`, but never the whole string.
    func trimmingSuffix(_ suffix: String) -> String {
        var result = self
        while result.hasSuffix(suffix) && result.count > suffix.count {
            result.removeLast(suffix.count)
        }
        return result
    }
}
