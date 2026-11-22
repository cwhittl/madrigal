import Foundation
import SwiftData

/// The v1 schema, versioned from the start so later releases can add a
/// `SchemaMigrationPlan` with stages from here.
///
/// Once the CloudKit schema is deployed to Production it only accepts
/// additive changes: new properties with defaults, new optional
/// relationships, new models. Never rename or remove a property after v1
/// ships; add a new one and stop reading the old one instead.
///
/// Production also won't create a new field at runtime: uploads fail with
/// "Cannot create or modify field … in production schema" and nothing
/// syncs. After any model change, and before uploading to TestFlight:
/// 1. Run a Debug build and tap Settings › Data › Sync status › Initialize
///    CloudKit Schema (`CloudSchemaInitializer`), which pushes every record
///    type and field to Development. Or from the terminal, run the Debug
///    binary directly: `MadrigalChat.app/Contents/MacOS/MadrigalChat -initCloudKitSchema`.
/// 2. In CloudKit Console, deploy: Development › Schema › Deploy Schema
///    Changes to Production.
enum MadrigalSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Project.self,
            Conversation.self,
            Message.self,
            Attachment.self,
            ProjectFile.self,
            ProviderConfig.self,
            Agent.self
        ]
    }
}

extension PersistentModel {
    /// False once the object is deleted, or detached from its context after
    /// a deleting save. Async work that outlives a view (a stream, a
    /// summary) must check this before writing back.
    var isLive: Bool { modelContext != nil && !isDeleted }
}
