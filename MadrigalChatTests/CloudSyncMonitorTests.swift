import CloudKit
import Foundation
import Testing
@testable import Madrigal

struct CloudSyncMonitorTests {

    // MARK: - errorDetail

    @Test func plainNSErrorShowsDomainCodeAndDescription() {
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something broke"])
        #expect(CloudSyncMonitor.errorDetail(error) == "TestDomain 42: Something broke")
    }

    @Test func ckErrorShowsCodeName() {
        let error = CKError(.notAuthenticated)
        let detail = CloudSyncMonitor.errorDetail(error)
        #expect(detail.hasPrefix("CKError.notAuthenticated (9): "))
    }

    @Test func partialFailureListsEachItemError() {
        let zone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: "abc", zoneID: zone)
        let itemError = NSError(domain: CKErrorDomain, code: CKError.Code.serverRejectedRequest.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Cannot create or modify field 'CD_name' in record type 'CD_Agent' in production schema"
        ])
        let error = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Partial failure",
            CKPartialErrorsByItemIDKey: [recordID: itemError]
        ])
        let lines = CloudSyncMonitor.errorDetail(error).components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "CKError.partialFailure (2): Partial failure")
        #expect(lines[1].hasPrefix("• com.apple.coredata.cloudkit.zone/abc: CKError.serverRejectedRequest (15): "))
        #expect(lines[1].contains("in production schema"))
    }

    @Test func underlyingErrorIsIncluded() {
        let underlying = CKError(.quotaExceeded)
        let error = NSError(domain: NSCocoaErrorDomain, code: 134400, userInfo: [
            NSLocalizedDescriptionKey: "Mirroring failed",
            NSUnderlyingErrorKey: underlying
        ])
        let detail = CloudSyncMonitor.errorDetail(error)
        #expect(detail.hasPrefix("NSCocoaErrorDomain 134400: Mirroring failed\nUnderlying: CKError.quotaExceeded (25)"))
    }

    // MARK: - summary

    private func event(_ kind: SyncEvent.Kind, succeeded: Bool = true, transient: Bool = false,
                       end: Date = .now) -> SyncEvent {
        SyncEvent(kind: kind, startDate: end.addingTimeInterval(-1), endDate: end,
                  succeeded: succeeded, errorDetail: succeeded ? nil : "boom", isTransient: transient)
    }

    @Test func offWhenSyncDisabled() {
        #expect(CloudSyncMonitor.summary(enabled: false, account: .available, events: [:]) == .off)
    }

    @Test func waitingBeforeAnyEvents() {
        #expect(CloudSyncMonitor.summary(enabled: true, account: .available, events: [:]) == .waiting)
        #expect(CloudSyncMonitor.summary(enabled: true, account: .unknown, events: [:]) == .waiting)
    }

    @Test func syncingReportsLatestTransfer() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        let events: [SyncEvent.Kind: SyncEvent] = [
            .setup: event(.setup, end: Date(timeIntervalSince1970: 3_000)),
            .import: event(.import, end: early),
            .export: event(.export, end: late)
        ]
        #expect(CloudSyncMonitor.summary(enabled: true, account: .available, events: events) == .syncing(lastSynced: late))
    }

    @Test func setupOnlyIsSyncingWithoutDate() {
        let events: [SyncEvent.Kind: SyncEvent] = [.setup: event(.setup)]
        #expect(CloudSyncMonitor.summary(enabled: true, account: .available, events: events) == .syncing(lastSynced: nil))
    }

    @Test func anyFailedEventIsAnError() {
        let events: [SyncEvent.Kind: SyncEvent] = [
            .import: event(.import),
            .export: event(.export, succeeded: false)
        ]
        #expect(CloudSyncMonitor.summary(enabled: true, account: .available, events: events) == .error)
    }

    @Test func transientFailureIsRetrying() {
        let events: [SyncEvent.Kind: SyncEvent] = [
            .import: event(.import),
            .export: event(.export, succeeded: false, transient: true)
        ]
        #expect(CloudSyncMonitor.summary(enabled: true, account: .available, events: events) == .retrying)
    }

    @Test func lastingFailureOutranksTransientOne() {
        let events: [SyncEvent.Kind: SyncEvent] = [
            .import: event(.import, succeeded: false, transient: true),
            .export: event(.export, succeeded: false)
        ]
        #expect(CloudSyncMonitor.summary(enabled: true, account: .available, events: events) == .error)
    }

    @Test func classifiesTransientCloudKitErrors() {
        for code in [CKError.Code.networkUnavailable, .networkFailure, .zoneBusy,
                     .requestRateLimited, .serviceUnavailable, .serverResponseLost] {
            #expect(CloudSyncMonitor.isTransient(CKError(code)), "\(code.name)")
        }
        for code in [CKError.Code.partialFailure, .quotaExceeded, .notAuthenticated] {
            #expect(!CloudSyncMonitor.isTransient(CKError(code)), "\(code.name)")
        }
        #expect(!CloudSyncMonitor.isTransient(NSError(domain: NSCocoaErrorDomain, code: 134400)))
    }

    @Test func noAccountIsUnavailableEvenWithEvents() {
        let events: [SyncEvent.Kind: SyncEvent] = [.export: event(.export, succeeded: false)]
        #expect(CloudSyncMonitor.summary(enabled: true, account: .noAccount, events: events) == .unavailable(.noAccount))
        #expect(CloudSyncMonitor.summary(enabled: true, account: .restricted, events: [:]) == .unavailable(.restricted))
    }

    @Test func reportListsEveryEventKind() {
        let report = CloudSyncMonitor.report(
            account: .available,
            events: [.export: event(.export, succeeded: false)],
            inProgress: [.import]
        )
        #expect(report.contains("Account: Available"))
        #expect(report.contains("Setup: none yet"))
        #expect(report.contains("Download: none yet (running now)"))
        #expect(report.contains("Upload: FAILED at "))
        #expect(report.contains("boom"))
    }
}
