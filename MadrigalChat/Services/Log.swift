import Foundation
import os
import SwiftData

/// One `Logger` per area, so failures the app recovers from quietly still
/// leave a trace in Console. Filter by subsystem `dev.whittle.madrigalchat`.
enum Log {
    static let subsystem = "dev.whittle.madrigalchat"

    static let data = Logger(subsystem: subsystem, category: "Data")
    static let keychain = Logger(subsystem: subsystem, category: "Keychain")
    static let localModels = Logger(subsystem: subsystem, category: "LocalModels")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
}

extension ModelContext {
    /// Saves, logging a failure instead of throwing. For saves the user
    /// can't act on: SwiftData autosaves as well, so the change is usually
    /// written later anyway.
    func saveOrLog(_ operation: StaticString) {
        do {
            try save()
        } catch {
            Log.data.error("Save failed (\(operation, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }
}
