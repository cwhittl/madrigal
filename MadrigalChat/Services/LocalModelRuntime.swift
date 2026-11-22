import Foundation
import os
#if os(iOS)
import UIKit
#endif
#if !targetEnvironment(simulator) && arch(arm64)
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

/// Keeps at most one on-device model in memory. Loading takes seconds and
/// gigabytes, so the model stays loaded between messages and is only dropped
/// when another model is needed, the system warns about memory, or the
/// model is deleted.
///
/// A generation holds its container until it finishes, so a different model
/// isn't loaded until every generation using the current one has ended.
/// Background work (chat summaries) is stopped instead of waited for.
actor LocalModelRuntime {
    static let shared = LocalModelRuntime()

    static let yieldedMessage = "Stopped so another on-device model could load."

    static let memoryMessage = "This model needs more memory than is available right now. Try a smaller model or close other apps."

    /// Drops a model from memory, if it's the loaded one. Safe to call on
    /// any device.
    static func unload(modelID: String) async {
        #if !targetEnvironment(simulator) && arch(arm64)
        await shared.unload(ifID: modelID)
        #endif
    }

    /// Memory this process can still allocate. On iOS that's the app's
    /// limit, not the device's RAM.
    static var availableMemory: UInt64 {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return ProcessInfo.processInfo.physicalMemory
        #endif
    }

    #if !targetEnvironment(simulator) && arch(arm64)

    /// `token` identifies one load, so a caller can tell its own load from
    /// a later one of the same model.
    private var loaded: (id: String, token: UUID, container: ModelContainer)?
    private var loading: (id: String, token: UUID, task: Task<ModelContainer, Error>)?
    private var generations = GenerationRegistry()
    /// Loads waiting for generations of another model to end.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init() {
        // A small buffer cache: generation is memory-bound on phones, and
        // MLX's default keeps far more than it needs.
        Memory.cacheLimit = 32 << 20
        // Backgrounding is handled by `GenerationLifecycle`, which has to act
        // before the notification returns and so can't wait for this actor.
        #if os(iOS)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { _ in
            Task { await LocalModelRuntime.shared.unload() }
        }
        #endif
    }

    /// The loaded container for `model`, loading it (and unloading any
    /// other) first if needed. `generation` is the caller's registration
    /// from `beginGeneration`; it's marked as using `model` until it ends.
    func container(for model: LocalModelReference, generation: UUID) async throws -> ModelContainer {
        // Wait for generations still holding another model, stopping any
        // that are only background work. Marking this one as a user before
        // the next await keeps a second caller from loading a third model.
        while generations.isModelInUse(otherThan: model.id) {
            generations.stopYielding(otherThan: model.id, reason: Self.yieldedMessage)
            await waitForGenerationToEnd()
            try Task.checkCancellation()
        }
        generations.markUsing(generation, modelID: model.id)

        if let loaded, loaded.id == model.id { return loaded.container }
        if let loading, loading.id == model.id {
            let container = try await loading.task.value
            // The load may have been dropped (memory warning, deletion)
            // while this caller waited.
            guard isCurrent(loading.token) else { throw CancellationError() }
            return container
        }

        loaded = nil
        loading?.task.cancel()
        loading = nil
        Memory.clearCache()

        // Not a gate: the model may still fit, and the user was warned when
        // they downloaded it. This only decides how a failure is explained.
        let likelyTooLarge = Self.availableMemory < UInt64(LocalModelFit.workingSet(forModelBytes: model.sizeBytes))

        let token = UUID()
        let task = Task { try await Self.load(model) }
        loading = (model.id, token, task)
        do {
            let container = try await task.value
            // Unloaded while loading, and maybe loaded again since: don't
            // hand out (or track) a model the runtime has replaced.
            guard loading?.token == token else { throw CancellationError() }
            loading = nil
            loaded = (model.id, token, container)
            return container
        } catch {
            if loading?.token == token { loading = nil }
            Memory.clearCache()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if likelyTooLarge { throw ChatProviderError.unavailable(reason: Self.memoryMessage) }
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw ChatProviderError.unavailable(reason: "Couldn't load \(model.name): \(detail)")
        }
    }

    /// Registers a running generation, both here (which model it uses) and
    /// with `GenerationLifecycle` (what it does when the app goes to the
    /// background). Both stop it through `control`.
    func beginGeneration(
        backgroundCompute: BackgroundComputeBox?,
        yieldsToOtherModels: Bool,
        control: GenerationControl
    ) -> UUID {
        let lifecycle = GenerationLifecycle.shared
        let id = lifecycle.begin(compute: backgroundCompute?.value ?? .pause, control: control)
        // The background task, and with it background GPU access, may only
        // arrive once the user leaves the app, after this has begun.
        if let backgroundCompute {
            let current = backgroundCompute.observe { lifecycle.update(id, compute: $0) }
            lifecycle.update(id, compute: current)
        }
        generations.begin(id, yieldsToOtherModels: yieldsToOtherModels) { reason in
            control.stop(reason: reason)
        }
        return id
    }

    func endGeneration(_ id: UUID) {
        GenerationLifecycle.shared.end(id)
        generations.end(id)
        // Waiting loads re-check whether their model can load now.
        let waiting = waiters
        waiters = [:]
        for continuation in waiting.values { continuation.resume() }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        loaded?.token == token || loading?.token == token
    }

    /// Returns when any generation ends, or when the caller is cancelled.
    private func waitForGenerationToEnd() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.resumeWaiter(id) }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    func unload() {
        loading?.task.cancel()
        loading = nil
        loaded = nil
        // A generation in flight keeps its own reference; the memory comes
        // back when it finishes.
        Memory.clearCache()
    }

    private func unload(ifID id: String) {
        if loaded?.id == id || loading?.id == id { unload() }
    }

    // MARK: - Loading

    private static func load(_ model: LocalModelReference) async throws -> ModelContainer {
        // Registry configs carry per-model fixes such as extra end-of-turn
        // tokens. Unknown IDs get a plain configuration.
        var configuration = LLMRegistry.shared.configuration(id: model.id)
        configuration.extraEOSTokens.formUnion(model.extraEOSTokens)
        let downloader = LocalDirectoryDownloader(directory: model.directory)
        // Turns MLX's internal errors into throws instead of a crash.
        return try await withError {
            try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: TransformersTokenizerLoader(),
                configuration: configuration
            )
        }
    }

    #endif
}

/// In-flight on-device generations: which model each is using, and which
/// give way when another model is needed. What they do when the app goes to
/// the background is `BackgroundRegistry`'s job. Kept apart from
/// `LocalModelRuntime` so it builds (and can be tested) where MLX doesn't.
struct GenerationRegistry {
    /// Ends the generation's stream with `reason` as the error.
    typealias Stop = @Sendable (_ reason: String) -> Void

    private struct Entry {
        let stop: Stop
        let yieldsToOtherModels: Bool
        /// Set once the generation has passed the model-switch check.
        var modelID: String?
        var isStopping = false
    }

    private var entries: [UUID: Entry] = [:]

    var count: Int { entries.count }

    /// `id` comes from `GenerationLifecycle.begin`, so both registries
    /// share it.
    mutating func begin(_ id: UUID, yieldsToOtherModels: Bool = false, stop: @escaping Stop) {
        entries[id] = Entry(stop: stop, yieldsToOtherModels: yieldsToOtherModels)
    }

    mutating func end(_ id: UUID) {
        entries[id] = nil
    }

    mutating func markUsing(_ id: UUID, modelID: String) {
        entries[id]?.modelID = modelID
    }

    /// True while a generation is still using a model other than `modelID`.
    func isModelInUse(otherThan modelID: String) -> Bool {
        entries.values.contains { $0.modelID != nil && $0.modelID != modelID }
    }

    /// Stops background work using another model. The entries stay until
    /// `end`, so a load waits for them to let go of their model.
    mutating func stopYielding(otherThan modelID: String, reason: String) {
        for (id, entry) in entries
        where entry.yieldsToOtherModels && !entry.isStopping
            && entry.modelID != nil && entry.modelID != modelID {
            entries[id]?.isStopping = true
            entry.stop(reason)
        }
    }
}

// MARK: - Background

/// One on-device generation's link to the app lifecycle: whether it's
/// paused, whether it has work in flight on the GPU, and how to stop it.
/// Kept apart from MLX so it builds (and can be tested) anywhere.
///
/// The generation calls `startRun` before each stretch of MLX work (it
/// waits there while paused), `attach` once that work can be cancelled, and
/// `finishRun` once it has fully ended. The lifecycle side calls `pause`,
/// `resume`, `stop`, and `waitUntilGPUIdle`.
final class GenerationControl: Sendable {
    private struct State {
        var isPaused = false
        var isStopped = false
        /// A run is in progress, between `startRun` and `finishRun`.
        var isRunning = false
        /// The run in progress was cut short by `pause`.
        var pausedDuringRun = false
        var cancelRun: (@Sendable () -> Void)?
        var idleWaiters: [DispatchSemaphore] = []
        /// `startRun` calls waiting for `resume`.
        var resumeWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

        mutating func beginRun() {
            isRunning = true
            pausedDuringRun = false
            cancelRun = nil
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onStop: @Sendable (_ reason: String) -> Void

    /// - Parameter onStop: ends the generation from outside, such as by
    ///   finishing its stream with `reason` as the error.
    init(onStop: @escaping @Sendable (_ reason: String) -> Void = { _ in }) {
        self.onStop = onStop
    }

    var isPaused: Bool { state.withLock { $0.isPaused } }
    var isStopped: Bool { state.withLock { $0.isStopped } }
    /// True while a run is in progress, so it may have work on the GPU.
    var isRunning: Bool { state.withLock { $0.isRunning } }

    // MARK: Lifecycle side

    /// Pauses the generation: the run in progress is cancelled (once its
    /// MLX work can be), and the next one waits in `startRun` until
    /// `resume`.
    func pause() {
        let (changed, cancel) = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            guard !state.isPaused, !state.isStopped else { return (false, nil) }
            state.isPaused = true
            guard state.isRunning else { return (true, nil) }
            state.pausedDuringRun = true
            return (true, state.cancelRun)
        }
        guard changed else { return }
        Log.localModels.notice("Pausing on-device generation (app left the foreground)")
        cancel?()
    }

    /// Lets a paused generation carry on.
    func resume() {
        let (changed, waiters) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Error>]) in
            guard state.isPaused else { return (false, []) }
            state.isPaused = false
            let waiters = Array(state.resumeWaiters.values)
            state.resumeWaiters = [:]
            if !waiters.isEmpty, !state.isStopped { state.beginRun() }
            return (true, waiters)
        }
        guard changed else { return }
        Log.localModels.notice("Resuming on-device generation (app returned)")
        for waiter in waiters { waiter.resume() }
    }

    /// Stops the generation for good, cancelling any run in progress and
    /// ending a wait in `startRun`. Only the first call has an effect.
    func stop(reason: String) {
        let (first, cancel, waiters) = state.withLock { state in
            defer {
                state.isStopped = true
                state.resumeWaiters = [:]
            }
            return (!state.isStopped, state.cancelRun, Array(state.resumeWaiters.values))
        }
        guard first else { return }
        cancel?()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        onStop(reason)
    }

    /// Blocks until the generation has nothing in flight on the GPU, or
    /// until `deadline`. Returns false on timeout.
    @discardableResult
    func waitUntilGPUIdle(deadline: DispatchTime) -> Bool {
        let semaphore: DispatchSemaphore? = state.withLock { state in
            guard state.isRunning else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            state.idleWaiters.append(semaphore)
            return semaphore
        }
        guard let semaphore else { return true }
        return semaphore.wait(timeout: deadline) == .success
    }

    // MARK: Generation side

    /// Call before any MLX work. Waits while paused, so nothing new reaches
    /// the GPU in the background. Throws `CancellationError` once stopped,
    /// or if the calling task is cancelled while waiting.
    func startRun() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = state.withLock { state in
                    if state.isStopped || Task.isCancelled { return .failure(CancellationError()) }
                    if state.isPaused {
                        state.resumeWaiters[id] = continuation
                        return nil
                    }
                    state.beginRun()
                    return .success(())
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.resumeWaiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Lets `pause` and `stop` cancel the current run. Cancels right away
    /// if either happened since `startRun`.
    func attach(cancel: @escaping @Sendable () -> Void) {
        let cancelNow = state.withLock { state in
            state.cancelRun = cancel
            return state.isStopped || state.isPaused
        }
        if cancelNow { cancel() }
    }

    /// Call once the run's MLX work has fully ended, including any
    /// pipelined GPU evaluation. Returns true if the run was interrupted by
    /// a pause, so the generation should resume from the text so far.
    func finishRun() -> Bool {
        let (paused, waiters) = state.withLock { state in
            let paused = state.isRunning && state.pausedDuringRun && !state.isStopped
            let waiters = state.idleWaiters
            state.isRunning = false
            state.pausedDuringRun = false
            state.cancelRun = nil
            state.idleWaiters = []
            return (paused, waiters)
        }
        for waiter in waiters { waiter.signal() }
        return paused
    }
}

/// What each in-flight on-device generation does when the app goes to the
/// background. See `BackgroundCompute`.
struct BackgroundRegistry: Sendable {
    private var entries: [UUID: (compute: BackgroundCompute, control: GenerationControl)] = [:]
    private(set) var isInBackground: Bool

    var count: Int { entries.count }

    init(isInBackground: Bool = false) {
        self.isInBackground = isInBackground
    }

    /// A `.pause` generation that begins in the background starts paused.
    mutating func begin(compute: BackgroundCompute, control: GenerationControl) -> UUID {
        if isInBackground, compute == .pause { control.pause() }
        let id = UUID()
        entries[id] = (compute, control)
        return id
    }

    mutating func end(_ id: UUID) {
        entries[id] = nil
    }

    /// Changes what a generation does in the background, such as when its
    /// background task is submitted as the user leaves the app. If the app
    /// is already in the background, a newly `.gpu` generation resumes and
    /// a newly `.pause` one pauses. Unknown ids are ignored.
    mutating func update(_ id: UUID, compute: BackgroundCompute) {
        guard let entry = entries[id], entry.compute != compute else { return }
        entries[id] = (compute, entry.control)
        guard isInBackground else { return }
        switch compute {
        case .gpu: entry.control.resume()
        case .pause: entry.control.pause()
        }
    }

    /// Pauses `.pause` generations and leaves `.gpu` ones running. Returns
    /// the controls of the paused ones, to wait for their GPU work.
    mutating func enterBackground() -> [GenerationControl] {
        isInBackground = true
        var leaving: [GenerationControl] = []
        for entry in entries.values where entry.compute == .pause {
            entry.control.pause()
            leaving.append(entry.control)
        }
        return leaving
    }

    /// Resumes `.pause` generations.
    mutating func enterForeground() {
        isInBackground = false
        for entry in entries.values where entry.compute == .pause {
            entry.control.resume()
        }
    }
}

/// Pauses on-device generations when the app goes to the background
/// without background GPU access, and resumes them when it returns. Metal
/// faults if a backgrounded app without background GPU access submits work,
/// so this runs synchronously in the notification (on the main thread) and
/// waits briefly for the GPU to go idle before the app finishes
/// backgrounding. There's no hop to `LocalModelRuntime`: the wait has to
/// happen before the notification returns.
final class GenerationLifecycle: Sendable {
    static let shared = GenerationLifecycle()

    /// How long backgrounding waits for GPU work already in flight, such
    /// as a prompt being processed, to finish.
    static let gpuIdleTimeout: DispatchTimeInterval = .seconds(2)

    private let registry: OSAllocatedUnfairLock<BackgroundRegistry>

    /// Observes from creation, so leaving the app before the first
    /// generation is still seen. `MadrigalChatApp` creates `shared` at launch.
    private init() {
        registry = OSAllocatedUnfairLock(initialState: BackgroundRegistry(isInBackground: Self.launchedInBackground))
        #if os(iOS)
        let center = NotificationCenter.default
        // With no queue, the block runs synchronously on the posting (main)
        // thread, before the app finishes entering the background.
        _ = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in
            GenerationLifecycle.shared.enterBackground()
        }
        _ = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in
            GenerationLifecycle.shared.enterForeground()
        }
        #endif
    }

    /// True if the app is already in the background, such as when launched
    /// for a background task.
    private static var launchedInBackground: Bool {
        #if os(iOS)
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { UIApplication.shared.applicationState == .background }
        #else
        return false
        #endif
    }

    /// Registers a generation for its lifetime.
    func begin(compute: BackgroundCompute, control: GenerationControl) -> UUID {
        registry.withLock { $0.begin(compute: compute, control: control) }
    }

    func end(_ id: UUID) {
        registry.withLock { $0.end(id) }
    }

    func update(_ id: UUID, compute: BackgroundCompute) {
        registry.withLock { $0.update(id, compute: compute) }
    }

    func enterBackground() {
        let leaving = registry.withLock { $0.enterBackground() }
        let deadline = DispatchTime.now() + Self.gpuIdleTimeout
        for control in leaving where !control.waitUntilGPUIdle(deadline: deadline) {
            Log.localModels.notice("On-device generation still busy on the GPU when the app left")
        }
    }

    func enterForeground() {
        registry.withLock { $0.enterForeground() }
    }
}

/// Builds the prompt that continues a reply after a pause: the
/// chat template with its generation prompt, followed directly by what the
/// model has written so far, with no end of turn in between. The model then
/// picks up mid-reply.
enum GenerationResume {
    /// - Returns: the prompt tokens and the token budget left, or nil if
    ///   the reply has already used it all.
    static func continuation(
        templateTokens: [Int],
        partialText: String,
        maxTokens: Int,
        encode: (String) -> [Int]
    ) -> (prompt: [Int], maxTokens: Int)? {
        let partial = partialText.isEmpty ? [] : encode(partialText)
        let remaining = maxTokens - partial.count
        guard remaining > 0 else { return nil }
        return (templateTokens + partial, remaining)
    }
}

#if !targetEnvironment(simulator) && arch(arm64)

/// Models are downloaded by `LocalModelStore` ahead of time, so "downloading"
/// here just points MLX at the files already on disk.
private struct LocalDirectoryDownloader: MLXLMCommon.Downloader {
    let directory: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        directory
    }
}

/// Loads swift-transformers tokenizers, which read the chat template from
/// the model's own files.
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

#endif
