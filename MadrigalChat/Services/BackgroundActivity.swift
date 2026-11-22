import Foundation
import os
#if os(iOS)
import UIKit
import BackgroundTasks
#endif

/// Keeps a reply streaming after the user leaves the app or locks the screen.
///
/// Every reply starts with a classic `beginBackgroundTask`, which has no UI.
/// The continued-processing task below, which always shows a system
/// progress banner, is only submitted when the app resigns active while the
/// reply is still running (or straight away if the app isn't active when
/// it starts), so staying in the app shows no banner.
///
/// - iOS 26+: a `BGContinuedProcessingTask`. The system shows its progress,
///   lets the user cancel it, and keeps the app running for as long as
///   progress keeps moving. On devices that support it (M3 and later iPads),
///   the task also asks for background GPU access for on-device MLX models.
///   Elsewhere, such as on iPhone, on-device replies get no task at all:
///   they pause in the background and carry on when the app returns.
/// - iOS 17–25, or if the system won't start one right now: a classic
///   `beginBackgroundTask`, which gives about 30 seconds. Hosted replies
///   only; an on-device reply pauses instead.
/// - macOS: apps aren't suspended, so this does nothing.
@MainActor
final class BackgroundActivity {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist,
    /// which allows `<prefix>*`.
    nonisolated static let identifierPrefix = "dev.whittle.madrigalchat.reply."

    /// True once the system ran out of time (or the user cancelled from the
    /// system UI) and `onExpiration` was called.
    private(set) var expired = false
    private var ended = false
    private var snapshots = 0
    private let onExpiration: @MainActor () -> Void

    /// Why the reply was cut off, in plain words for the notification, once
    /// `expired` is true. The timings go to the log instead.
    private(set) var expiryReason: String?
    private static let log = Logger(subsystem: Log.subsystem, category: "Background")
    private let name: String
    private let startedAt = Date.now
    private var lastProgressAt = Date.now
    private var leftAppAt: Date?
    private var launchedAt: Date?
    /// Why the continued-processing request wasn't accepted, if it wasn't.
    private var submitFailure: String?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Kept for submitting the continued-processing task later.
    private let title: String
    private let usesGPU: Bool
    /// Told `.gpu` once a task with background GPU access is submitted.
    private let computeBox: BackgroundComputeBox?
    /// True once a continued-processing request was made, accepted or not,
    /// so leaving the app again doesn't make another.
    private var triedContinuedProcessing = false
    /// Whether the app reached the background since that request. If not
    /// (Control Center or Notification Center was pulled down), the banner
    /// is withdrawn when the app becomes active again.
    private var enteredBackgroundSinceRequest = false

    #if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    /// A `BGContinuedProcessingTask` once the system launches it. Typed as
    /// `AnyObject` so the stored property doesn't need an availability check.
    private var continuedTask: AnyObject?
    private var completedSuccessfully = false
    /// The pooled identifier this activity's task uses, if any. Held until
    /// the task is completed, then returned to `slots`.
    private var slot: Int?

    /// `BGTaskScheduler` can't unregister an identifier, so a new one per
    /// reply would pile up registrations over a long session. A few are
    /// reused instead; see `TaskIdentifierPool`.
    private static var slots = TaskIdentifierPool(prefix: identifierPrefix, size: 4)
    /// Which activity each slot's next launch belongs to.
    private static var slotOwners: [Int: WeakActivity] = [:]

    private struct WeakActivity {
        weak var value: BackgroundActivity?
    }
    #endif

    /// What the work needs from the system to keep running in the background.
    enum Compute {
        /// Network or CPU work, such as a hosted reply.
        case cpu
        /// Metal work, such as on-device MLX models. Asks for background GPU
        /// access where the device supports it, and otherwise starts no task
        /// at all: the work pauses once the app is backgrounded.
        case gpuIfSupported
    }

    /// True once a continued-processing task was submitted (not launched:
    /// the launch is asynchronous), until it's withdrawn.
    private var runsInBackground = false

    /// Whether this device and OS let a continued-processing task use the GPU
    /// in the background. Always true on macOS, which doesn't suspend apps.
    static var canRunGPUInBackground: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return BGTaskScheduler.supportedResources.contains(.gpu)
        }
        return false
        #else
        return true
        #endif
    }

    /// - Parameters:
    ///   - title: shown under "Madrigal is replying" in the system's progress
    ///     UI. Usually the chat's title.
    ///   - compute: `.gpuIfSupported` for Metal work such as on-device MLX
    ///     models.
    ///   - computeBox: set to `.gpu` once a task with background GPU access
    ///     is submitted, which may be well after `init`, when the user
    ///     leaves the app. On-device replies read it when the app goes to
    ///     the background.
    ///   - onExpiration: runs if the time runs out first. The activity ends
    ///     itself right after.
    init(name: String,
         title: String = "",
         compute: Compute = .cpu,
         computeBox: BackgroundComputeBox? = nil,
         onExpiration: @escaping @MainActor () -> Void) {
        self.onExpiration = onExpiration
        self.name = name
        self.title = title
        self.usesGPU = compute == .gpuIfSupported
        self.computeBox = computeBox
        #if os(iOS)
        if usesGPU, !Self.canRunGPUInBackground {
            // Nothing to keep running: the reply pauses in the background,
            // and a task would only show a banner and expire.
            Self.log.notice("\(name, privacy: .public): no background GPU, so no background task; the reply pauses when the app leaves")
            return
        }
        observeLifecycle()
        // No UI, and it covers the moment of leaving the app until the
        // continued-processing task (if any) launches.
        beginLegacyTask(name: name)
        if UIApplication.shared.applicationState != .active {
            upgradeToContinuedProcessing()
        }
        #endif
    }

    /// The timings and system error behind a cut-off, for the log.
    private func expiryDetails(legacy: Bool) -> String {
        let now = Date.now
        func seconds(_ since: Date) -> String { "\(Int(now.timeIntervalSince(since).rounded())) s" }
        var details = [legacy ? "short background task" : "continued processing", "\(seconds(startedAt)) into the reply"]
        if let leftAppAt { details.append("\(seconds(leftAppAt)) after leaving the app") }
        details.append("\(seconds(lastProgressAt)) since new text")
        if ProcessInfo.processInfo.isLowPowerModeEnabled { details.append("Low Power Mode on") }
        if legacy, let submitFailure { details.append("continued processing refused: \(submitFailure)") }
        return details.joined(separator: ", ")
    }

    /// Why a reply was cut off, for the notification.
    nonisolated static func expiryReason(legacy: Bool, refusedLongTask: Bool, lowPowerMode: Bool) -> String {
        let reason = if !legacy {
            "iOS stopped it in the background, or it was cancelled from the progress banner."
        } else if refusedLongTask {
            "iOS only allowed about 30 seconds in the background this time."
        } else {
            "It ran out of background time."
        }
        return lowPowerMode ? reason + " Low Power Mode can shorten background time." : reason
    }

    #if os(iOS)
    private func observeLifecycle() {
        let center = NotificationCenter.default
        // The app still counts as in the foreground here, which submitting
        // a continued-processing task requires. It always comes before
        // didEnterBackground, so on-device replies see the new compute in
        // time.
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.upgradeToContinuedProcessing() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.ended else { return }
                self.leftAppAt = .now
                self.enteredBackgroundSinceRequest = true
                Self.log.notice("\(self.name, privacy: .public): app entered background \(Int(Date.now.timeIntervalSince(self.startedAt))) s into the reply (task launched: \(self.launchedAt != nil))")
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.ended else { return }
                self.leftAppAt = nil
                Self.log.notice("\(self.name, privacy: .public): app returned to the foreground")
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.ended, self.triedContinuedProcessing,
                      !self.enteredBackgroundSinceRequest else { return }
                self.withdrawContinuedProcessing()
            }
        })
    }
    #endif

    /// Call once per stream snapshot. Continued processing is expired if
    /// its progress stops moving, so this keeps it alive.
    func update() {
        guard !ended else { return }
        snapshots += 1
        lastProgressAt = .now
        #if os(iOS)
        if #available(iOS 26.0, *) { applyProgress() }
        #endif
    }

    /// Safe to call more than once.
    func end(success: Bool = true) {
        guard !ended else { return }
        ended = true
        Self.log.notice("\(self.name, privacy: .public): ended after \(Int(Date.now.timeIntervalSince(self.startedAt))) s (success \(success), expired \(self.expired))")
        #if os(iOS)
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers = []
        completedSuccessfully = success
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
            continuedTask = nil
            releaseSlot()
        }
        // If the launch handler hasn't run yet, it completes the task as
        // soon as it does (see `adopt`).
        endLegacyTask()
        #endif
    }

    private func expire(legacy: Bool) {
        guard !ended else { return }
        expired = true
        expiryReason = Self.expiryReason(
            legacy: legacy,
            refusedLongTask: submitFailure != nil,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        Self.log.error("\(self.name, privacy: .public): cut off (\(self.expiryDetails(legacy: legacy), privacy: .public))")
        onExpiration()
        end(success: false)
    }

    #if os(iOS)
    /// Submits the continued-processing task, once. On success the legacy
    /// task is ended when the new one launches (see `adopt`), so something
    /// always holds the app. On failure a CPU reply keeps the legacy task
    /// (about 30 s); a GPU reply drops it and pauses instead, since a short
    /// task can't keep GPU work going and its expiry would stop the reply.
    private func upgradeToContinuedProcessing() {
        guard !ended, !triedContinuedProcessing else { return }
        triedContinuedProcessing = true
        enteredBackgroundSinceRequest = UIApplication.shared.applicationState == .background
        if #available(iOS 26.0, *) {
            if submitContinuedProcessing(subtitle: title, usesGPU: usesGPU) {
                runsInBackground = true
                if usesGPU { computeBox?.set(.gpu) }
                Self.log.notice("\(self.name, privacy: .public): continued processing submitted on leaving the app \(Int(Date.now.timeIntervalSince(self.startedAt))) s into the reply (GPU \(self.usesGPU), Low Power Mode \(ProcessInfo.processInfo.isLowPowerModeEnabled))")
                return
            }
            Self.log.error("\(self.name, privacy: .public): continued processing refused: \(self.submitFailure ?? "unknown", privacy: .public)")
        } else {
            submitFailure = "needs iOS 26"
        }
        if usesGPU { endLegacyTask() }
    }

    /// The app resigned active without leaving (Control Center or
    /// Notification Center), so the banner isn't wanted: completes the
    /// continued-processing task and goes back to the short, invisible
    /// one, ready to submit again when the user really leaves. A task the
    /// system hasn't launched yet is left alone; it can't be withdrawn.
    private func withdrawContinuedProcessing() {
        if runsInBackground {
            guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
            task.expirationHandler = nil
            task.setTaskCompleted(success: true)
            continuedTask = nil
            launchedAt = nil
            releaseSlot()
            runsInBackground = false
            computeBox?.set(.pause)
            Self.log.notice("\(self.name, privacy: .public): withdrew continued processing; the app never left")
        }
        triedContinuedProcessing = false
        submitFailure = nil
        if identifier == .invalid { beginLegacyTask(name: name) }
    }

    private func endLegacyTask() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    private func beginLegacyTask(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.expire(legacy: true) }
        }
    }

    @available(iOS 26.0, *)
    private func submitContinuedProcessing(subtitle: String, usesGPU: Bool) -> Bool {
        guard let identifier = reserveIdentifier() else {
            submitFailure = "couldn't register a task identifier"
            return false
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Madrigal is replying",
            subtitle: subtitle.isEmpty ? Conversation.defaultTitle : subtitle
        )
        // Start now or not at all; a reply queued for later is useless.
        request.strategy = .fail
        if usesGPU { request.requiredResources = .gpu }
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            submitFailure = "\(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]"
            releaseSlot()
            return false
        }
    }

    /// A pooled identifier, registered on first use, or a one-off one
    /// (registered for this activity alone) if every slot is still busy.
    @available(iOS 26.0, *)
    private func reserveIdentifier() -> String? {
        if let (slot, needsRegistering) = Self.slots.acquire() {
            let identifier = Self.slots.identifier(forSlot: slot)
            if needsRegistering {
                let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                    MainActor.assumeIsolated { BackgroundActivity.launch(task, slot: slot) }
                }
                guard registered else {
                    Self.slots.release(slot, registered: false)
                    return nil
                }
            }
            self.slot = slot
            Self.slotOwners[slot] = WeakActivity(value: self)
            return identifier
        }

        let identifier = Self.identifierPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask, let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.adopt(task)
            }
        }
        return registered ? identifier : nil
    }

    /// A pooled slot's task launched: hands it to the activity that
    /// submitted it, or completes it if that activity is gone.
    @available(iOS 26.0, *)
    private static func launch(_ task: BGTask, slot: Int) {
        guard let task = task as? BGContinuedProcessingTask, let owner = slotOwners[slot]?.value else {
            task.setTaskCompleted(success: false)
            slotOwners[slot] = nil
            slots.release(slot)
            return
        }
        owner.adopt(task)
    }

    private func releaseSlot() {
        guard let slot else { return }
        self.slot = nil
        Self.slotOwners[slot] = nil
        Self.slots.release(slot)
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = ReplyProgress.totalUnitCount
        if ended {
            // The reply finished before the system launched the task.
            task.progress.completedUnitCount = ReplyProgress.totalUnitCount
            task.setTaskCompleted(success: completedSuccessfully)
            releaseSlot()
            return
        }
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(legacy: false) }
        }
        continuedTask = task
        launchedAt = .now
        Self.log.notice("\(self.name, privacy: .public): continued processing launched \(Int(Date.now.timeIntervalSince(self.startedAt))) s into the reply")
        applyProgress()
        // The continued-processing task holds the app now.
        endLegacyTask()
    }

    @available(iOS 26.0, *)
    private func applyProgress() {
        guard let task = continuedTask as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = ReplyProgress.completedUnits(afterSnapshots: snapshots)
    }
    #endif
}

/// A fixed set of background task identifiers, `<prefix>slot<n>`, each
/// registered once and reused. A slot is busy from submitting a request
/// until its task is completed, so a late launch can't reach the wrong
/// reply. Kept apart from `BGTaskScheduler` so it can be tested.
struct TaskIdentifierPool {
    let prefix: String
    let size: Int
    private var busy: Set<Int> = []
    private(set) var registered: Set<Int> = []

    init(prefix: String, size: Int) {
        self.prefix = prefix
        self.size = size
    }

    func identifier(forSlot slot: Int) -> String {
        prefix + "slot\(slot)"
    }

    /// The lowest free slot, and whether it still needs registering, or
    /// nil when every slot is busy.
    mutating func acquire() -> (slot: Int, needsRegistering: Bool)? {
        guard let slot = (0..<size).first(where: { !busy.contains($0) }) else { return nil }
        busy.insert(slot)
        let needsRegistering = registered.insert(slot).inserted
        return (slot, needsRegistering)
    }

    /// Frees `slot`. Pass `registered: false` if registering it failed, so
    /// the next acquire tries again.
    mutating func release(_ slot: Int, registered: Bool = true) {
        busy.remove(slot)
        if !registered { self.registered.remove(slot) }
    }
}

/// Progress for a stream of unknown length: it rises with every snapshot,
/// slows down over time, and never reaches the total until the reply ends.
///
/// The total is larger than 100 so the integer count keeps ticking during
/// long replies; the system treats stalled progress as a stuck task.
enum ReplyProgress {
    static let totalUnitCount: Int64 = 1_000_000
    /// Snapshots at which progress reaches half. Snapshots arrive at most
    /// about 30 times a second, so this is roughly a minute of streaming.
    static let halfwaySnapshots = 1_800.0

    static func completedUnits(afterSnapshots count: Int) -> Int64 {
        let n = Double(max(count, 0))
        let ceiling = Double(totalUnitCount - 1)
        return Int64(ceiling * n / (n + halfwaySnapshots))
    }
}
