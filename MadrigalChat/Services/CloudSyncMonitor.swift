import CloudKit
import CoreData
import Foundation
import Observation
import SwiftData
import SwiftUI

/// Watches SwiftData's CloudKit mirroring, which otherwise fails silently,
/// so Settings can show the iCloud account state, when the last setup,
/// upload and download happened, and the exact CloudKit error.
@Observable
@MainActor
final class CloudSyncMonitor {
    static let shared = CloudSyncMonitor()

    /// The latest finished event of each kind.
    private(set) var events: [SyncEvent.Kind: SyncEvent] = [:]
    /// Kinds with an event that has started but not finished yet.
    private(set) var inProgress: Set<SyncEvent.Kind> = []
    private(set) var account: AccountState = .unknown

    private var observers: [NSObjectProtocol] = []
    /// The account check in flight, so a newer one replaces it instead of
    /// racing it.
    private var accountCheck: Task<Void, Never>?

    private init() {
        guard AppConfig.enableCloudKitSync, !AppConfig.isHostingTests else { return }

        // SwiftData's CloudKit store posts these from its internal
        // NSPersistentCloudKitContainer, so observe every sender.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            #if DEBUG
            // The schema initializer's throwaway stack isn't the live store.
            if (note.object as? NSPersistentContainer)?.name == CloudSchemaInitializer.containerName { return }
            #endif
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  let snapshot = SyncEvent(event) else { return }
            MainActor.assumeIsolated { self?.record(snapshot) }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccountStatus() }
        })

        refreshAccountStatus()
    }

    var summary: SyncSummary {
        Self.summary(enabled: AppConfig.enableCloudKitSync, account: account, events: events)
    }

    func refreshAccountStatus() {
        accountCheck?.cancel()
        accountCheck = Task {
            do {
                let status = try await CKContainer(identifier: AppConfig.cloudKitContainerID).accountStatus()
                guard !Task.isCancelled else { return }
                account = AccountState(status)
            } catch {
                guard !Task.isCancelled else { return }
                let detail = Self.errorDetail(error)
                Log.sync.error("Account status check failed: \(detail, privacy: .public)")
                account = .checkFailed(detail)
            }
        }
    }

    private func record(_ event: SyncEvent) {
        guard event.endDate != nil else {
            inProgress.insert(event.kind)
            return
        }
        inProgress.remove(event.kind)
        events[event.kind] = event
        if let detail = event.errorDetail {
            Log.sync.error("CloudKit \(event.kind.title, privacy: .public) failed: \(detail, privacy: .public)")
        }
    }

    /// Plain text for "Copy Details", to paste into a bug report.
    func report() -> String {
        Self.report(account: account, events: events, inProgress: inProgress)
    }
}

// MARK: - Values

/// A finished or running CloudKit mirroring event, copied out of
/// `NSPersistentCloudKitContainer.Event` so it can be stored and tested.
struct SyncEvent: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case setup, `import`, export

        var title: String {
            switch self {
            case .setup: "Setup"
            case .import: "Download"
            case .export: "Upload"
            }
        }
    }

    var kind: Kind
    var startDate: Date
    var endDate: Date?
    var succeeded: Bool
    var errorDetail: String?
    /// The failure is one CloudKit retries by itself, such as no network
    /// or a rate limit, so it isn't shown as an error.
    var isTransient = false
}

extension SyncEvent {
    nonisolated init?(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: Kind
        switch event.type {
        case .setup: kind = .setup
        case .import: kind = .import
        case .export: kind = .export
        @unknown default: return nil
        }
        self.init(
            kind: kind,
            startDate: event.startDate,
            endDate: event.endDate,
            succeeded: event.succeeded,
            errorDetail: event.error.map(CloudSyncMonitor.errorDetail),
            isTransient: event.error.map(CloudSyncMonitor.isTransient) ?? false
        )
    }
}

enum AccountState: Equatable, Sendable {
    /// Not checked yet.
    case unknown
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
    case checkFailed(String)

    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .couldNotDetermine
        @unknown default: self = .couldNotDetermine
        }
    }

    var title: String {
        switch self {
        case .unknown: "Checking…"
        case .available: "Available"
        case .noAccount: "Not signed in"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily unavailable"
        case .couldNotDetermine: "Could not determine"
        case .checkFailed: "Check failed"
        }
    }

    /// Whether this state rules out syncing.
    var blocksSync: Bool {
        switch self {
        case .noAccount, .restricted, .temporarilyUnavailable: true
        default: false
        }
    }
}

enum SyncSummary: Equatable {
    /// `AppConfig.enableCloudKitSync` is off.
    case off
    case unavailable(AccountState)
    case error
    /// The last attempt hit a temporary problem (network, rate limit,
    /// busy server) that CloudKit retries by itself.
    case retrying
    case waiting
    case syncing(lastSynced: Date?)
}

// MARK: - Pure logic

extension CloudSyncMonitor {
    nonisolated static func summary(
        enabled: Bool,
        account: AccountState,
        events: [SyncEvent.Kind: SyncEvent]
    ) -> SyncSummary {
        guard enabled else { return .off }
        if account.blocksSync { return .unavailable(account) }
        let failures = events.values.filter { !$0.succeeded }
        if failures.contains(where: { !$0.isTransient }) { return .error }
        if !failures.isEmpty { return .retrying }
        if events.isEmpty { return .waiting }
        let transfers = [events[.import], events[.export]].compactMap { $0?.endDate }
        return .syncing(lastSynced: transfers.max())
    }

    /// Errors CloudKit retries by itself. Anything else, such as a schema
    /// mismatch (`partialFailure`), `quotaExceeded` or `notAuthenticated`,
    /// needs attention.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == CKError.errorDomain else { return false }
        switch CKError.Code(rawValue: ns.code) {
        case .networkUnavailable, .networkFailure, .zoneBusy, .requestRateLimited,
             .serviceUnavailable, .serverResponseLost:
            return true
        default:
            return false
        }
    }

    /// One readable description of a sync error. CloudKit hides the useful
    /// part of a partial failure, such as "Cannot create or modify field …
    /// in production schema", in the per-item errors, so those are listed.
    nonisolated static func errorDetail(_ error: Error) -> String {
        let ns = error as NSError
        var lines: [String]
        if ns.domain == CKErrorDomain {
            let code = CKError.Code(rawValue: ns.code)
            let name = code.map(\.name) ?? "code \(ns.code)"
            lines = ["CKError.\(name) (\(ns.code)): \(ns.localizedDescription)"]
            if code == .partialFailure,
               let partial = ns.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any] {
                let items = partial.compactMap { key, value -> String? in
                    guard let itemError = value as? Error else { return nil }
                    return "• \(itemName(key)): \(errorDetail(itemError))"
                }
                lines += items.sorted()
            }
        } else {
            lines = ["\(ns.domain) \(ns.code): \(ns.localizedDescription)"]
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            lines.append("Underlying: " + errorDetail(underlying))
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func itemName(_ key: AnyHashable) -> String {
        if let id = key.base as? CKRecord.ID { return "\(id.zoneID.zoneName)/\(id.recordName)" }
        if let id = key.base as? CKRecordZone.ID { return id.zoneName }
        return "\(key.base)"
    }

    nonisolated static var environmentName: String {
        #if DEBUG
        "Development"
        #else
        "Production"
        #endif
    }

    nonisolated static func report(
        account: AccountState,
        events: [SyncEvent.Kind: SyncEvent],
        inProgress: Set<SyncEvent.Kind>
    ) -> String {
        var lines = [
            "Madrigal \(AppConfig.version) (\(AppConfig.build))",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Container: \(AppConfig.cloudKitContainerID)",
            "Environment: \(environmentName)",
            "Account: \(account.title)"
        ]
        if case .checkFailed(let detail) = account {
            lines.append("Account error: \(detail)")
        }
        let formatter = ISO8601DateFormatter()
        for kind in SyncEvent.Kind.allCases {
            var line = "\(kind.title): "
            if let event = events[kind], let end = event.endDate {
                line += "\(event.succeeded ? "succeeded" : event.isTransient ? "failed (will retry)" : "FAILED") at \(formatter.string(from: end))"
            } else {
                line += "none yet"
            }
            if inProgress.contains(kind) { line += " (running now)" }
            lines.append(line)
            if let detail = events[kind]?.errorDetail {
                lines.append(detail)
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension CKError.Code {
    var name: String {
        switch self {
        case .internalError: "internalError"
        case .partialFailure: "partialFailure"
        case .networkUnavailable: "networkUnavailable"
        case .networkFailure: "networkFailure"
        case .badContainer: "badContainer"
        case .serviceUnavailable: "serviceUnavailable"
        case .requestRateLimited: "requestRateLimited"
        case .missingEntitlement: "missingEntitlement"
        case .notAuthenticated: "notAuthenticated"
        case .permissionFailure: "permissionFailure"
        case .unknownItem: "unknownItem"
        case .invalidArguments: "invalidArguments"
        case .serverRecordChanged: "serverRecordChanged"
        case .serverRejectedRequest: "serverRejectedRequest"
        case .assetFileNotFound: "assetFileNotFound"
        case .assetFileModified: "assetFileModified"
        case .incompatibleVersion: "incompatibleVersion"
        case .constraintViolation: "constraintViolation"
        case .operationCancelled: "operationCancelled"
        case .changeTokenExpired: "changeTokenExpired"
        case .batchRequestFailed: "batchRequestFailed"
        case .zoneBusy: "zoneBusy"
        case .badDatabase: "badDatabase"
        case .quotaExceeded: "quotaExceeded"
        case .zoneNotFound: "zoneNotFound"
        case .limitExceeded: "limitExceeded"
        case .userDeletedZone: "userDeletedZone"
        case .tooManyParticipants: "tooManyParticipants"
        case .alreadyShared: "alreadyShared"
        case .referenceViolation: "referenceViolation"
        case .managedAccountRestricted: "managedAccountRestricted"
        case .participantMayNeedVerification: "participantMayNeedVerification"
        case .serverResponseLost: "serverResponseLost"
        case .assetNotAvailable: "assetNotAvailable"
        case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
        default: "code \(rawValue)"
        }
    }
}

extension EnvironmentValues {
    /// Set from `CloudSyncMonitor.shared` at the root. Nil in previews and
    /// tests, which then show sync as not monitored.
    @Entry var cloudSync: CloudSyncMonitor? = nil
}

// MARK: - Schema initializer

#if DEBUG
/// Pushes every record type and field in the SwiftData schema to the
/// CloudKit Development environment, so the whole schema can then be
/// deployed to Production. Uses Apple's documented pattern for SwiftData:
/// a separate Core Data stack on a throwaway store, so the live store is
/// never touched.
///
/// Apple runs this before the live container loads; here it runs while
/// the live store is mirroring the same zone, so the throwaway store may
/// also start setting up and importing. That's harmless for a Debug tool,
/// and `CloudSyncMonitor` ignores its events (by `containerName`).
enum CloudSchemaInitializer {
    nonisolated static let containerName = "MadrigalSchemaInit"

    struct ModelError: LocalizedError {
        var errorDescription: String? { "Couldn't build a Core Data model from the SwiftData schema." }
    }

    static func run() async throws {
        try await Task.detached(priority: .userInitiated) {
            try initialize()
        }.value
    }

    /// Pushes the schema and exits when launched with `-initCloudKitSchema`,
    /// before the live store opens. Lets the push run from the command line.
    /// The push runs off the main thread while the main run loop spins,
    /// since CloudKit setup delivers callbacks on the main queue.
    nonisolated static func runFromCommandLineIfRequested() {
        guard CommandLine.arguments.contains("-initCloudKitSchema") else { return }
        Thread.detachNewThread {
            do {
                try initialize()
                FileHandle.standardError.write(Data("CloudKit schema initialized in Development.\n".utf8))
                exit(0)
            } catch {
                let detail = CloudSyncMonitor.errorDetail(error) + "\nuserInfo: \((error as NSError).userInfo)\n"
                FileHandle.standardError.write(Data(detail.utf8))
                exit(1)
            }
        }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    private nonisolated static func initialize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CloudSchemaInit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: MadrigalSchemaV1.models) else {
            throw ModelError()
        }
        let description = NSPersistentStoreDescription(url: directory.appending(path: "schema.store"))
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: AppConfig.cloudKitContainerID
        )
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentCloudKitContainer(name: containerName, managedObjectModel: model)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        defer {
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }
        try container.initializeCloudKitSchema()
    }
}
#endif
