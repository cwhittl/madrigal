import Foundation
import Observation
import HuggingFace

/// One open-weight model that can be downloaded from Hugging Face.
struct LocalModelInfo: Identifiable, Hashable, Codable, Sendable {
    /// The Hugging Face repo ID, for example mlx-community/Qwen3-1.7B-4bit.
    /// This is also what gets stored as a conversation's model.
    let id: String
    let name: String
    /// Weights plus config files, as downloaded.
    let sizeBytes: Int64
    /// End-of-turn tokens for models MLX's registry doesn't know about.
    var extraEOSTokens: [String] = []

    /// Short name for repo IDs typed in by hand.
    static func displayName(for id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}

/// How a model's size compares to this device's memory. Advice only: every
/// model can still be downloaded and tried.
enum LocalModelFit: Sendable, Equatable {
    case recommended
    case tight
    case tooLarge

    /// Room for the context window and activations on top of the weights.
    static let overheadBytes: Int64 = 512 << 20

    /// The share of physical memory an app can realistically use. iOS keeps
    /// a lot for itself, even with the increased memory limit entitlement.
    static var usableMemoryFraction: Double {
        #if os(iOS)
        return 0.6
        #else
        return 0.7
        #endif
    }

    /// Memory the model wants while running.
    static func workingSet(forModelBytes bytes: Int64) -> Int64 {
        Int64(Double(bytes) * 1.2) + overheadBytes
    }

    static func fit(
        modelBytes: Int64,
        physicalMemory: UInt64,
        usableFraction: Double = usableMemoryFraction
    ) -> LocalModelFit {
        let budget = Double(physicalMemory) * usableFraction
        let needed = Double(workingSet(forModelBytes: modelBytes))
        if needed <= budget * 0.75 { return .recommended }
        if needed <= budget { return .tight }
        return .tooLarge
    }

    /// The smallest device memory, in whole GB, the model fits on.
    static func recommendedMemoryGB(modelBytes: Int64, usableFraction: Double = usableMemoryFraction) -> Int {
        let needed = Double(workingSet(forModelBytes: modelBytes)) / usableFraction
        return Int((needed / Double(1 << 30)).rounded(.up))
    }

    static func current(forModelBytes bytes: Int64) -> LocalModelFit {
        fit(modelBytes: bytes, physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}

/// Downloads, lists, and deletes on-device models. Downloads are per device
/// and never sync: weights are gigabytes, and each device decides what fits.
@Observable
@MainActor
final class LocalModelStore {
    static let shared = LocalModelStore()

    /// mlx-community 4-bit conversions, smallest first. Sizes are what the
    /// Hub reports for the files that get downloaded.
    nonisolated static let catalog: [LocalModelInfo] = [
        LocalModelInfo(id: "mlx-community/Llama-3.2-1B-Instruct-4bit", name: "Llama 3.2 1B", sizeBytes: 712_575_975),
        LocalModelInfo(id: "mlx-community/gemma-3-1b-it-qat-4bit", name: "Gemma 3 1B", sizeBytes: 767_171_175),
        LocalModelInfo(id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B", sizeBytes: 982_341_391),
        LocalModelInfo(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama 3.2 3B", sizeBytes: 1_824_807_894),
        LocalModelInfo(id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B", sizeBytes: 2_277_297_903),
        LocalModelInfo(id: "mlx-community/gemma-3-4b-it-qat-4bit", name: "Gemma 3 4B", sizeBytes: 3_029_994_301,
                       extraEOSTokens: ["<end_of_turn>"]),
        LocalModelInfo(id: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", name: "Llama 3.1 8B", sizeBytes: 4_526_682_492),
        LocalModelInfo(id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B", sizeBytes: 4_622_110_691)
    ]

    /// The same files MLX itself fetches: weights, configs, chat templates.
    nonisolated static let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

    struct InstalledModel: Codable, Sendable {
        /// Snapshot folder relative to `rootDirectory`. Relative because the
        /// app container's path changes across iOS updates.
        let relativePath: String
        let sizeOnDisk: Int64
    }

    /// Download progress, 0...1, by model ID.
    private(set) var downloadProgress: [String: Double] = [:]
    /// Last download failure, by model ID.
    private(set) var downloadErrors: [String: String] = [:]
    private(set) var installed: [String: InstalledModel] = [:] {
        didSet { installedIDs = installed.keys.sorted() }
    }
    /// Sorted once per change rather than on every read: chat rows and
    /// pickers read it on each render.
    private(set) var installedIDs: [String] = []
    /// Models added by repo ID. Device-local, like the downloads.
    private(set) var customModels: [LocalModelInfo] = []

    private var downloadTasks: [String: Task<Void, Never>] = [:]

    private static let customModelsKey = "localModels.custom"

    private init() {
        installed = Self.readManifest()
        installedIDs = installed.keys.sorted()
        if let data = UserDefaults.standard.data(forKey: Self.customModelsKey),
           let models = try? JSONDecoder().decode([LocalModelInfo].self, from: data) {
            customModels = models
        }
    }

    // MARK: - Queries

    /// Catalog first, then models added by hand, then anything installed
    /// that neither list knows about.
    var allModels: [LocalModelInfo] {
        var models = Self.catalog
        let known = Set(models.map(\.id))
        models += customModels.filter { !known.contains($0.id) }
        let listed = Set(models.map(\.id))
        for (id, entry) in installed where !listed.contains(id) {
            models.append(LocalModelInfo(id: id, name: LocalModelInfo.displayName(for: id), sizeBytes: entry.sizeOnDisk))
        }
        return models
    }

    func info(for id: String) -> LocalModelInfo? {
        allModels.first { $0.id == id }
    }

    func isInstalled(_ id: String) -> Bool { installed[id] != nil }

    func isDownloading(_ id: String) -> Bool { downloadTasks[id] != nil }

    func fit(for model: LocalModelInfo) -> LocalModelFit {
        LocalModelFit.current(forModelBytes: installed[model.id]?.sizeOnDisk ?? model.sizeBytes)
    }

    /// Everything the runtime needs to load a model, or nil when it isn't
    /// downloaded on this device.
    func loadReference(for id: String) -> LocalModelReference? {
        guard let entry = installed[id] else { return nil }
        let info = info(for: id)
        return LocalModelReference(
            id: id,
            name: info?.name ?? LocalModelInfo.displayName(for: id),
            directory: Self.rootDirectory.appending(path: entry.relativePath, directoryHint: .isDirectory),
            sizeBytes: entry.sizeOnDisk,
            extraEOSTokens: Set(info?.extraEOSTokens ?? [])
        )
    }

    // MARK: - Adding by repo ID

    /// Looks a repo up on the Hub so it can be rated before downloading.
    func addModel(repoID raw: String) async throws -> LocalModelInfo {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = info(for: id) { return existing }
        guard let repo = Repo.ID(rawValue: id) else {
            throw ChatProviderError.unavailable(reason: "Use a Hugging Face repo ID like mlx-community/Qwen3-4B-4bit.")
        }

        let entries = try await Self.makeClient().listTree(in: repo, recursive: true).items
            .filter { $0.type == .file && Self.matchesDownloadPatterns($0.path) }
        guard entries.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw ChatProviderError.unavailable(reason: "\(id) has no MLX weights (.safetensors files). Look for a version from mlx-community.")
        }

        let size = entries.reduce(Int64(0)) { $0 + Int64($1.effectiveSize ?? 0) }
        let model = LocalModelInfo(id: id, name: LocalModelInfo.displayName(for: id), sizeBytes: size)
        customModels.append(model)
        saveCustomModels()
        return model
    }

    // MARK: - Download and delete

    func download(_ model: LocalModelInfo) {
        guard downloadTasks[model.id] == nil, !isInstalled(model.id) else { return }
        guard let repo = Repo.ID(rawValue: model.id) else {
            downloadErrors[model.id] = "\(model.id) isn't a valid repo ID."
            return
        }

        downloadErrors[model.id] = nil
        downloadProgress[model.id] = 0
        let id = model.id

        downloadTasks[id] = Task {
            do {
                let client = try Self.makeClient()
                let snapshot = try await client.downloadSnapshot(
                    of: repo,
                    matching: Self.downloadPatterns,
                    progressHandler: { [weak self] progress in
                        self?.downloadProgress[id] = progress.fractionCompleted
                    }
                )
                try Task.checkCancellation()

                let root = Self.rootDirectory.standardizedFileURL.path(percentEncoded: false)
                let path = snapshot.standardizedFileURL.path(percentEncoded: false)
                let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
                installed[id] = InstalledModel(
                    relativePath: relative.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    sizeOnDisk: Self.allocatedSize(of: Self.repoDirectory(for: repo))
                )
                writeManifest()
            } catch where error is CancellationError || Task.isCancelled {
                Self.removeFiles(for: repo)
            } catch {
                // Finished files stay in the cache, so retrying resumes.
                downloadErrors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            downloadTasks[id] = nil
            downloadProgress[id] = nil
        }
    }

    func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
    }

    func delete(_ id: String) async {
        cancelDownload(id)
        await LocalModelRuntime.unload(modelID: id)
        if let repo = Repo.ID(rawValue: id) {
            Self.removeFiles(for: repo)
        }
        installed[id] = nil
        downloadErrors[id] = nil
        writeManifest()
    }

    // MARK: - Files

    /// Application Support/Models. Excluded from backup: the weights can
    /// always be downloaded again.
    nonisolated static var rootDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    private nonisolated static var hubDirectory: URL {
        rootDirectory.appending(path: "hub", directoryHint: .isDirectory)
    }

    private nonisolated static var manifestURL: URL {
        rootDirectory.appending(path: "installed.json")
    }

    /// Where model lookups and downloads go. Named in the data disclosure.
    nonisolated static let hubHost = HubClient.defaultHost

    private nonisolated static func makeClient() throws -> HubClient {
        try prepareRootDirectory()
        return HubClient(host: hubHost, cache: HubCache(cacheDirectory: hubDirectory))
    }

    private nonisolated static func prepareRootDirectory() throws {
        var root = rootDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    private nonisolated static func repoDirectory(for repo: Repo.ID) -> URL {
        HubCache(cacheDirectory: hubDirectory).repoDirectory(repo: repo, kind: .model)
    }

    private nonisolated static func removeFiles(for repo: Repo.ID) {
        try? FileManager.default.removeItem(at: repoDirectory(for: repo))
    }

    private nonisolated static func matchesDownloadPatterns(_ path: String) -> Bool {
        downloadPatterns.contains { fnmatch($0, path, 0) == 0 }
    }

    /// Bytes actually used on disk. The cache's snapshot folder is all
    /// symlinks into blobs/, so links are skipped to avoid counting twice.
    private nonisolated static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private nonisolated static func readManifest() -> [String: InstalledModel] {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode([String: InstalledModel].self, from: data)
        else { return [:] }
        // Drop anything whose files went missing.
        return manifest.filter { _, entry in
            FileManager.default.fileExists(atPath: rootDirectory.appending(path: entry.relativePath).path(percentEncoded: false))
        }
    }

    private func writeManifest() {
        do {
            try Self.prepareRootDirectory()
            try JSONEncoder().encode(installed).write(to: Self.manifestURL, options: .atomic)
        } catch {
            // The files are still there; the next launch just won't list them.
            Log.localModels.error("Couldn't write the model manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveCustomModels() {
        if let data = try? JSONEncoder().encode(customModels) {
            UserDefaults.standard.set(data, forKey: Self.customModelsKey)
        }
    }
}

/// What the runtime needs to load one installed model.
struct LocalModelReference: Sendable {
    let id: String
    let name: String
    let directory: URL
    let sizeBytes: Int64
    let extraEOSTokens: Set<String>
}
