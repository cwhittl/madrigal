import SwiftUI

/// The Settings › Data row: a one-line summary of iCloud sync.
struct SyncStatusLabel: View {
    let summary: SyncSummary

    var body: some View {
        // Redrawn every 30 seconds so "Last synced" stays current.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if case .syncing(let date?) = summary {
                        Text("Last synced \(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(summary == .error ? .red : .secondary)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch summary {
        case .off: "Stored on this device only"
        case .unavailable: "iCloud unavailable"
        case .error: "Sync error"
        case .retrying: "Sync will retry"
        case .waiting: "Waiting for first sync"
        case .syncing: "Syncing with iCloud"
        }
    }

    private var icon: String {
        switch summary {
        case .off, .unavailable: "icloud.slash"
        case .error: "exclamationmark.icloud"
        case .retrying: "arrow.clockwise.icloud"
        case .waiting: "icloud"
        case .syncing: "checkmark.icloud"
        }
    }
}

/// Details of SwiftData's CloudKit mirroring, so a TestFlight build can show
/// why sync isn't working.
struct SyncStatusView: View {
    let monitor: CloudSyncMonitor

    #if DEBUG
    @State private var initializingSchema = false
    @State private var schemaResult: String?
    #endif

    var body: some View {
        Form {
            Section {
                SyncStatusLabel(summary: monitor.summary)
            }

            Section("iCloud") {
                LabeledContent("Account", value: monitor.account.title)
                if case .checkFailed(let detail) = monitor.account {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Container") {
                    Text(AppConfig.cloudKitContainerID)
                        .textSelection(.enabled)
                }
                LabeledContent("Environment", value: CloudSyncMonitor.environmentName)
            }

            Section("Activity") {
                ForEach(SyncEvent.Kind.allCases, id: \.self) { kind in
                    eventRow(kind)
                }
            }

            if errors.isEmpty == false {
                Section("Error") {
                    ForEach(errors, id: \.kind) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.kind.title).font(.caption.bold())
                            Text(item.detail)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                Button("Copy Details") { Clipboard.copy(monitor.report()) }
                Button("Check Account Again") { monitor.refreshAccountStatus() }
            }

            #if DEBUG
            developerSection
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Sync Status")
    }

    private var errors: [(kind: SyncEvent.Kind, detail: String)] {
        SyncEvent.Kind.allCases.compactMap { kind in
            monitor.events[kind]?.errorDetail.map { (kind, $0) }
        }
    }

    @ViewBuilder
    private func eventRow(_ kind: SyncEvent.Kind) -> some View {
        LabeledContent(kind.title) {
            if monitor.inProgress.contains(kind) {
                Text("Running…")
            } else if let event = monitor.events[kind], let end = event.endDate {
                HStack(spacing: 4) {
                    Image(systemName: event.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(event.succeeded ? .green : .red)
                    Text(end, format: .dateTime.hour().minute().second())
                }
            } else {
                Text("None yet")
            }
        }
    }

    #if DEBUG
    private var developerSection: some View {
        Section {
            Button {
                initializingSchema = true
                schemaResult = nil
                Task {
                    do {
                        try await CloudSchemaInitializer.run()
                        schemaResult = "Schema sent to Development. Deploy it to Production in CloudKit Console."
                    } catch {
                        schemaResult = CloudSyncMonitor.errorDetail(error)
                    }
                    initializingSchema = false
                }
            } label: {
                HStack {
                    Text("Initialize CloudKit Schema")
                    if initializingSchema {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(initializingSchema)
            if let schemaResult {
                Text(schemaResult)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Debug builds only. Creates every record type and field in the Development environment.")
        }
    }
    #endif
}
