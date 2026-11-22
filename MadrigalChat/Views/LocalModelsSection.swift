import SwiftUI

/// Downloads and deletes on-device models, inside the MLX provider's edit
/// screen. Every row stays enabled: the fit rating is advice, and models
/// likely too large for this device only ask for confirmation first.
struct LocalModelsSection: View {
    @Bindable var config: ProviderConfig

    @State private var store: LocalModelStore
    @State private var repoID = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var confirmingLargeDownload: LocalModelInfo?
    @State private var confirmingDelete: LocalModelInfo?

    init(config: ProviderConfig, store: LocalModelStore = .shared) {
        self.config = config
        _store = State(initialValue: store)
    }

    var body: some View {
        Section {
            if let problem = config.configurationProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }

            ForEach(store.allModels) { model in
                row(for: model)
            }

            HStack {
                TextField("Add by repo ID", text: $repoID, prompt: Text("mlx-community/\u{2026}"))
                    .identifierEntry()
                    .onSubmit(add)
                if isAdding {
                    MadrigalIndicator(size: .small)
                } else {
                    Button("Add", action: add)
                        .buttonStyle(.borderless)
                        .disabled(repoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let addError {
                Label(addError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Models on this device")
        } footer: {
            Text("Models run privately on this device with no account or key. Downloads stay on this device and aren't backed up or synced, so each iPhone, iPad, or Mac downloads its own. Larger models answer better but need more memory.")
        }
        .confirmationDialog(
            "Download \(confirmingLargeDownload?.name ?? "model")?",
            isPresented: $confirmingLargeDownload.isPresent(),
            titleVisibility: .visible,
            presenting: confirmingLargeDownload
        ) { model in
            Button("Download Anyway") { store.download(model) }
            Button("Cancel", role: .cancel) { }
        } message: { model in
            Text("\(model.name) needs about \(LocalModelFit.recommendedMemoryGB(modelBytes: model.sizeBytes)) GB of memory, more than this device can give it. It may run very slowly, or the system may close Madrigal while it's answering.")
        }
        .confirmationDialog(
            "Delete \(confirmingDelete?.name ?? "model")?",
            isPresented: $confirmingDelete.isPresent(),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { model in
            Button("Delete", role: .destructive) {
                Task { await store.delete(model.id) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { model in
            Text("This frees \(Self.bytes(store.installed[model.id]?.sizeOnDisk ?? model.sizeBytes)) on this device. Chats that use it stay, and you can download it again later.")
        }
    }

    // MARK: - Rows

    private func row(for model: LocalModelInfo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .lineLimit(1)
                Group {
                    if let error = store.downloadErrors[model.id] {
                        Text(error)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else {
                        HStack(spacing: 6) {
                            Text(sizeText(for: model))
                                .foregroundStyle(.secondary)
                            LocalModelFitLabel(fit: store.fit(for: model), modelBytes: model.sizeBytes)
                        }
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            trailingControl(for: model)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailingControl(for model: LocalModelInfo) -> some View {
        if let progress = store.downloadProgress[model.id] {
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                Button {
                    store.cancelDownload(model.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel download")
            }
        } else if store.isInstalled(model.id) {
            Button(role: .destructive) {
                confirmingDelete = model
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(model.name)")
        } else {
            Button {
                if store.fit(for: model) == .tooLarge {
                    confirmingLargeDownload = model
                } else {
                    store.download(model)
                }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(config.configurationProblem != nil)
            .accessibilityLabel("Download \(model.name)")
        }
    }

    private func sizeText(for model: LocalModelInfo) -> String {
        if let installed = store.installed[model.id] {
            return "\(Self.bytes(installed.sizeOnDisk)) on disk"
        }
        return Self.bytes(model.sizeBytes)
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    // MARK: - Actions

    private func add() {
        let id = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !isAdding else { return }
        isAdding = true
        addError = nil
        Task {
            do {
                _ = try await store.addModel(repoID: id)
                repoID = ""
            } catch {
                addError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isAdding = false
        }
    }
}

/// A model's fit for this device, shown as a short coloured label.
struct LocalModelFitLabel: View {
    let fit: LocalModelFit
    let modelBytes: Int64

    var body: some View {
        switch fit {
        case .recommended:
            Text("Recommended")
                .foregroundStyle(.green)
        case .tight:
            // Yellow text is unreadable on light backgrounds; tint the icon.
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("May be slow or unstable")
                    .foregroundStyle(.secondary)
            }
        case .tooLarge:
            Text("Needs ~\(LocalModelFit.recommendedMemoryGB(modelBytes: modelBytes)) GB RAM")
                .foregroundStyle(.orange)
                .accessibilityLabel("Likely too large for this device. Needs about \(LocalModelFit.recommendedMemoryGB(modelBytes: modelBytes)) gigabytes of memory.")
        }
    }
}

/// An on-device model in the chat's model picker. Says when a model isn't
/// downloaded here (only possible in the screenshot demo, since the list is
/// this device's downloads), and warns when it's likely too large for this
/// device.
struct LocalModelPickerLabel: View {
    let modelID: String
    @State private var store: LocalModelStore

    init(modelID: String, store: LocalModelStore = .shared) {
        self.modelID = modelID
        _store = State(initialValue: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.info(for: modelID)?.name ?? LocalModelInfo.displayName(for: modelID))
                .lineLimit(1)
            if let installed = store.installed[modelID] {
                if LocalModelFit.current(forModelBytes: installed.sizeOnDisk) == .tooLarge {
                    LocalModelFitLabel(fit: .tooLarge, modelBytes: installed.sizeOnDisk)
                        .font(.caption)
                }
            } else {
                Text("Not downloaded on this device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
