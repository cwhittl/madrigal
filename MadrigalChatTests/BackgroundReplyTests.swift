import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Madrigal

struct ReplyProgressTests {

    @Test func startsAtZero() {
        #expect(ReplyProgress.completedUnits(afterSnapshots: 0) == 0)
        #expect(ReplyProgress.completedUnits(afterSnapshots: -5) == 0)
    }

    @Test func risesAndStaysBelowTotal() {
        var previous: Int64 = 0
        // Up to about an hour of snapshots at 30 a second.
        for count in stride(from: 100, through: 108_000, by: 100) {
            let units = ReplyProgress.completedUnits(afterSnapshots: count)
            #expect(units > previous, "stalled at \(count) snapshots")
            #expect(units < ReplyProgress.totalUnitCount)
            previous = units
        }
    }

    @Test func neverReachesTotalEvenForHugeCounts() {
        #expect(ReplyProgress.completedUnits(afterSnapshots: Int.max / 2) < ReplyProgress.totalUnitCount)
    }

    @Test func halfwayIsNearHalf() {
        let units = ReplyProgress.completedUnits(afterSnapshots: Int(ReplyProgress.halfwaySnapshots))
        #expect(abs(Double(units) / Double(ReplyProgress.totalUnitCount) - 0.5) < 0.01)
    }
}

@MainActor
struct ReplyNotifierTests {

    private func notifier(active: Bool) -> (ReplyNotifier, () -> [UNNotificationRequest]) {
        var delivered: [UNNotificationRequest] = []
        let notifier = ReplyNotifier(presence: { active ? .active : .background }, deliver: { delivered.append($0) })
        return (notifier, { delivered })
    }

    @Test func doesNotPostWhileActive() {
        let (notifier, delivered) = notifier(active: true)
        let request = notifier.replyFinished(conversationID: UUID(), title: "Chat", outcome: .finished(answer: "Hi"))
        #expect(request == nil)
        #expect(delivered().isEmpty)
    }

    @Test func postsWhenInactive() throws {
        let (notifier, delivered) = notifier(active: false)
        let id = UUID()
        notifier.replyFinished(conversationID: id, title: "Trip plans", outcome: .finished(answer: "  Here you go.  "))
        let request = try #require(delivered().first)
        #expect(request.content.title == "Trip plans")
        #expect(request.content.body == "Here you go.")
        #expect(request.content.threadIdentifier == id.uuidString)
        #expect(request.content.userInfo[ReplyNotifier.conversationIDKey] as? String == id.uuidString)
    }

    @Test func pausedNotificationIsPostedOnlyInBackgroundAndWithdrawn() throws {
        var delivered: [UNNotificationRequest] = []
        var withdrawn: [String] = []
        var active = true
        let notifier = ReplyNotifier(
            presence: { active ? .active : .background },
            deliver: { delivered.append($0) },
            withdraw: { withdrawn += $0 }
        )
        let id = UUID()

        #expect(notifier.replyPaused(conversationID: id, title: "Chat") == nil)
        #expect(delivered.isEmpty)

        active = false
        notifier.replyPaused(conversationID: id, title: "")
        let request = try #require(delivered.first)
        #expect(request.identifier == ReplyNotifier.pausedIdentifier(for: id))
        #expect(request.content.title == "Madrigal")
        #expect(request.content.body == ReplyNotifier.pausedBody)
        #expect(request.content.userInfo[ReplyNotifier.conversationIDKey] as? String == id.uuidString)

        notifier.replyResumed(conversationID: id)
        #expect(withdrawn == [ReplyNotifier.pausedIdentifier(for: id)])
    }

    @Test func coveredAppHoldsTheNotificationUntilTheUserLeaves() {
        var delivered: [UNNotificationRequest] = []
        var presence = AppPresence.inactive
        let notifier = ReplyNotifier(presence: { presence }, deliver: { delivered.append($0) }, withdraw: { _ in })

        #expect(notifier.replyFinished(conversationID: UUID(), title: "A", outcome: .finished(answer: "Hi")) == nil)
        #expect(delivered.isEmpty, "held while Control Center is down")
        #expect(notifier.replyPaused(conversationID: UUID(), title: "A") == nil, "paused needs the background")

        presence = .background
        notifier.appDidEnterBackground()
        #expect(delivered.count == 1)
        #expect(notifier.held.isEmpty)
    }

    @Test func returningDropsHeldNotifications() {
        var delivered: [UNNotificationRequest] = []
        let notifier = ReplyNotifier(presence: { .inactive }, deliver: { delivered.append($0) }, withdraw: { _ in })
        notifier.replyFinished(conversationID: UUID(), title: "A", outcome: .failed)
        notifier.appDidBecomeActive()
        notifier.appDidEnterBackground()
        #expect(delivered.isEmpty)
    }

    @Test func truncatesLongAnswers() {
        let body = ReplyNotifier.body(for: .finished(answer: String(repeating: "a", count: 500)))
        #expect(body.count == ReplyNotifier.previewLength + 1)
        #expect(body.hasSuffix("…"))
    }

    @Test func failureAndCutOffText() {
        #expect(ReplyNotifier.body(for: .failed) == "Reply failed")
        #expect(ReplyNotifier.body(for: .cutOff(reason: nil)) == "Reply was cut off — tap to continue")
        let explained = ReplyNotifier.body(for: .cutOff(reason: "iOS ended the background task."))
        #expect(explained.hasPrefix("Reply was cut off"))
        #expect(explained.hasSuffix("\niOS ended the background task."))
    }
}

/// Counts calls from a `@Sendable` closure.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var reasons: [String] = []
    func hit(_ reason: String = "") { lock.withLock { value += 1; reasons.append(reason) } }
    var count: Int { lock.withLock { value } }
    var lastReason: String? { lock.withLock { reasons.last } }
}

struct BackgroundComputeTests {

    @Test func boxTellsObserversOfChanges() {
        let box = BackgroundComputeBox()
        #expect(box.value == .pause)
        let seen = CallCounter()
        let current = box.observe { seen.hit("\($0)") }
        #expect(current == .pause)

        box.set(.gpu)
        box.set(.gpu)
        #expect(box.value == .gpu)
        #expect(seen.count == 1, "an unchanged value isn't reported")
        #expect(seen.lastReason == "gpu")
    }
}

struct BackgroundRegistryTests {

    @Test func backgroundPausesAndLeavesGPU() throws {
        var registry = BackgroundRegistry()
        let stops = CallCounter()
        let pauseControl = GenerationControl { stops.hit($0) }
        let gpuControl = GenerationControl { stops.hit($0) }
        let pauseID = registry.begin(compute: .pause, control: pauseControl)
        let gpuID = registry.begin(compute: .gpu, control: gpuControl)

        let leaving = registry.enterBackground()

        #expect(pauseControl.isPaused)
        #expect(!gpuControl.isPaused)
        #expect(stops.count == 0, "nothing is stopped")
        #expect(leaving.map(ObjectIdentifier.init) == [ObjectIdentifier(pauseControl)])
        #expect(registry.count == 2, "nothing is forgotten")

        registry.end(pauseID)
        registry.end(gpuID)
        #expect(registry.count == 0)
    }

    @Test func upgradedToGPUBeforeLeavingKeepsRunning() {
        var registry = BackgroundRegistry()
        let control = GenerationControl()
        let id = registry.begin(compute: .pause, control: control)

        // The background task is submitted on resign active, before
        // didEnterBackground.
        registry.update(id, compute: .gpu)
        let leaving = registry.enterBackground()

        #expect(!control.isPaused)
        #expect(leaving.isEmpty)
        registry.enterForeground()
        #expect(!control.isPaused)
    }

    @Test func updateWhileInBackgroundPausesOrResumes() {
        var registry = BackgroundRegistry()
        let control = GenerationControl()
        let id = registry.begin(compute: .pause, control: control)
        _ = registry.enterBackground()
        #expect(control.isPaused)

        registry.update(id, compute: .gpu)
        #expect(!control.isPaused)
        registry.update(id, compute: .pause)
        #expect(control.isPaused)

        registry.end(id)
        registry.update(id, compute: .gpu)
        #expect(control.isPaused, "an ended generation is left alone")
    }

    @Test func updateInForegroundOnlyChangesLaterBehaviour() {
        var registry = BackgroundRegistry()
        let control = GenerationControl()
        let id = registry.begin(compute: .gpu, control: control)
        registry.update(id, compute: .pause)
        #expect(!control.isPaused)
        _ = registry.enterBackground()
        #expect(control.isPaused)
    }

    @Test func foregroundResumes() {
        var registry = BackgroundRegistry()
        let control = GenerationControl()
        _ = registry.begin(compute: .pause, control: control)

        _ = registry.enterBackground()
        #expect(control.isPaused)
        registry.enterForeground()
        #expect(!control.isPaused)
        _ = registry.enterBackground()
        #expect(control.isPaused)
    }

    @Test func beginningInBackgroundStartsPaused() {
        var registry = BackgroundRegistry()
        _ = registry.enterBackground()

        let paused = GenerationControl()
        _ = registry.begin(compute: .pause, control: paused)
        #expect(paused.isPaused)
        let gpu = GenerationControl()
        _ = registry.begin(compute: .gpu, control: gpu)
        #expect(!gpu.isPaused)
        #expect(registry.count == 2)

        registry.enterForeground()
        #expect(!paused.isPaused)
        let later = GenerationControl()
        _ = registry.begin(compute: .pause, control: later)
        #expect(!later.isPaused)
    }
}

struct GenerationControlTests {

    @Test func pauseCancelsTheRunAndAsksToResume() async throws {
        let control = GenerationControl()
        let cancels = CallCounter()
        try await control.startRun()
        #expect(control.isRunning)
        control.attach { cancels.hit() }

        control.pause()
        control.pause()
        #expect(cancels.count == 1)
        #expect(control.finishRun(), "the run was cut short by the pause")
        #expect(!control.isRunning)
    }

    @Test func pauseBeforeAttachCancelsOnAttach() async throws {
        let control = GenerationControl()
        let cancels = CallCounter()
        try await control.startRun()
        control.pause()
        control.attach { cancels.hit() }
        #expect(cancels.count == 1)
        #expect(control.finishRun())
    }

    @Test func pauseWhileIdleDoesNotAskToResumeTheNextRun() async throws {
        let control = GenerationControl()
        control.pause()
        control.resume()
        try await control.startRun()
        let cancels = CallCounter()
        control.attach { cancels.hit() }
        #expect(cancels.count == 0)
        #expect(control.finishRun() == false)
    }

    @Test func startRunWaitsWhilePausedAndReturnsAfterResume() async throws {
        let control = GenerationControl()
        control.pause()
        let started = CallCounter()
        let run = Task.detached {
            try await control.startRun()
            started.hit()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(started.count == 0, "still waiting while paused")
        #expect(!control.isRunning)

        control.resume()
        try await run.value
        #expect(started.count == 1)
        #expect(control.isRunning)
        #expect(control.finishRun() == false)
    }

    @Test func stopWhilePausedThrows() async throws {
        let stops = CallCounter()
        let control = GenerationControl { stops.hit($0) }
        control.pause()
        let run = Task.detached { try await control.startRun() }
        try await Task.sleep(for: .milliseconds(50))

        control.stop(reason: "stopped")
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(stops.count == 1)
    }

    @Test func cancellingTheWaitThrows() async throws {
        let control = GenerationControl()
        control.pause()
        let run = Task.detached { try await control.startRun() }
        try await Task.sleep(for: .milliseconds(50))

        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(!control.isRunning)
        // A later resume has nothing left to wake.
        control.resume()
        #expect(!control.isRunning)
    }

    @Test func stopCancelsOnceAndBlocksNewRuns() async throws {
        let stops = CallCounter(), cancels = CallCounter()
        let control = GenerationControl { stops.hit($0) }
        try await control.startRun()
        control.attach { cancels.hit() }

        control.stop(reason: "gone")
        control.stop(reason: "again")
        #expect(stops.count == 1)
        #expect(stops.lastReason == "gone")
        #expect(cancels.count == 1)
        #expect(control.finishRun() == false, "a stopped generation doesn't resume")
        await #expect(throws: CancellationError.self) { try await control.startRun() }
    }

    @Test func waitReturnsAtOnceWhenIdle() {
        let control = GenerationControl()
        #expect(control.waitUntilGPUIdle(deadline: .now()))
    }

    @Test func waitTimesOutWhileBusy() async throws {
        let control = GenerationControl()
        try await control.startRun()
        #expect(control.waitUntilGPUIdle(deadline: .now() + .milliseconds(20)) == false)
        _ = control.finishRun()
    }

    @Test func waitEndsWhenTheRunFinishes() async throws {
        let control = GenerationControl()
        try await control.startRun()
        let finisher = Task.detached {
            try await Task.sleep(for: .milliseconds(50))
            _ = control.finishRun()
        }
        let idle = await Task.detached {
            control.waitUntilGPUIdle(deadline: .now() + .seconds(5))
        }.value
        #expect(idle)
        try await finisher.value
    }
}

struct GenerationResumeTests {

    /// One token per character, so counts are easy to check.
    private func encode(_ text: String) -> [Int] {
        text.unicodeScalars.map { Int($0.value) }
    }

    @Test func appendsPartialReplyRightAfterTheTemplate() throws {
        let template = [1, 2, 3]
        let resume = try #require(GenerationResume.continuation(
            templateTokens: template, partialText: "Hi", maxTokens: 10, encode: encode
        ))
        // No end-of-turn or anything else between the two.
        #expect(resume.prompt == [1, 2, 3, 72, 105])
        #expect(resume.maxTokens == 8)
    }

    @Test func emptyPartialKeepsTheTemplateAndBudget() throws {
        let resume = try #require(GenerationResume.continuation(
            templateTokens: [7], partialText: "", maxTokens: 10, encode: { _ in Issue.record("encoded empty text"); return [] }
        ))
        #expect(resume.prompt == [7])
        #expect(resume.maxTokens == 10)
    }

    @Test func nilOnceTheBudgetIsSpent() {
        #expect(GenerationResume.continuation(
            templateTokens: [1], partialText: "abc", maxTokens: 3, encode: encode
        ) == nil)
    }
}

struct GenerationRegistryTests {

    @Test func otherModelBlocksLoadUntilItsGenerationsEnd() {
        var registry = GenerationRegistry()
        let reply = CallCounter(), summary = CallCounter()
        let replyID = UUID(), summaryID = UUID()
        registry.begin(replyID) { reply.hit($0) }
        registry.begin(summaryID, yieldsToOtherModels: true) { summary.hit($0) }

        // Registered but not yet using a model: nothing blocks.
        #expect(!registry.isModelInUse(otherThan: "y"))

        registry.markUsing(replyID, modelID: "x")
        registry.markUsing(summaryID, modelID: "x")
        #expect(registry.isModelInUse(otherThan: "y"))
        #expect(!registry.isModelInUse(otherThan: "x"))

        // Only background work is stopped, and only once.
        registry.stopYielding(otherThan: "y", reason: "r")
        registry.stopYielding(otherThan: "y", reason: "r")
        #expect(summary.count == 1)
        #expect(summary.lastReason == "r")
        #expect(reply.count == 0)

        // The stopped summary still holds the model until it ends.
        registry.end(replyID)
        #expect(registry.isModelInUse(otherThan: "y"))
        registry.end(summaryID)
        #expect(!registry.isModelInUse(otherThan: "y"))
    }
}

struct TaskIdentifierPoolTests {

    @Test func slotsAreReusedAndRegisteredOnce() throws {
        var pool = TaskIdentifierPool(prefix: "p.", size: 2)
        let first = pool.acquire()
        #expect(first?.slot == 0 && first?.needsRegistering == true)
        #expect(pool.identifier(forSlot: 0) == "p.slot0")
        let second = pool.acquire()
        #expect(second?.slot == 1 && second?.needsRegistering == true)

        // Full: the caller falls back to a one-off identifier.
        let full = pool.acquire()
        #expect(full == nil)

        pool.release(0)
        let reused = pool.acquire()
        #expect(reused?.slot == 0 && reused?.needsRegistering == false)
    }

    @Test func failedRegistrationIsRetried() {
        var pool = TaskIdentifierPool(prefix: "p.", size: 1)
        _ = pool.acquire()
        pool.release(0, registered: false)
        let retry = pool.acquire()
        #expect(retry?.needsRegistering == true)
    }
}

struct ExpiryReasonTests {

    @Test func plainWordsWithoutTimings() {
        let continued = BackgroundActivity.expiryReason(legacy: false, refusedLongTask: false, lowPowerMode: false)
        #expect(continued.contains("progress banner"))
        let refused = BackgroundActivity.expiryReason(legacy: true, refusedLongTask: true, lowPowerMode: false)
        #expect(refused.contains("30 seconds"))
        let ranOut = BackgroundActivity.expiryReason(legacy: true, refusedLongTask: false, lowPowerMode: true)
        #expect(ranOut.hasSuffix("Low Power Mode can shorten background time."))
        for reason in [continued, refused, ranOut] {
            #expect(!reason.contains(" s,") && !reason.contains("["), "no timings or error codes")
        }
    }
}

@MainActor
struct InterruptedRepliesTests {

    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let replies: InterruptedReplies

    init() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: MadrigalSchemaV1.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let suite = "InterruptedRepliesTests.\(UUID().uuidString)"
        replies = InterruptedReplies(defaults: try #require(UserDefaults(suiteName: suite)))
    }

    private var notifier: ReplyNotifier {
        ReplyNotifier(presence: { .active }, deliver: { _ in }, withdraw: { _ in })
    }

    private func chat(_ messages: [(MessageRole, String)]) -> Conversation {
        let conversation = Conversation()
        context.insert(conversation)
        for (offset, (role, text)) in messages.enumerated() {
            let message = Message(role: role, content: text)
            message.createdAt = Date(timeIntervalSince1970: TimeInterval(offset))
            context.insert(message)
            message.conversation = conversation
        }
        return conversation
    }

    @Test func endedRepliesAreForgotten() {
        let a = UUID(), b = UUID()
        replies.begin(a)
        replies.begin(b)
        replies.end(a)
        #expect(replies.takeLeftovers() == [b])
        #expect(replies.takeLeftovers().isEmpty)
    }

    @Test func leftoverReplyIsMarkedAndKeepsItsText() throws {
        let conversation = chat([(.user, "Hi"), (.assistant, "Half an ans")])
        replies.begin(conversation.stableID)

        var withdrawn: [String] = []
        let notifier = ReplyNotifier(presence: { .active }, deliver: { _ in }, withdraw: { withdrawn += $0 })
        replies.recover(in: context, notifier: notifier)

        let reply = try #require(conversation.orderedMessages.last)
        #expect(reply.isError)
        #expect(reply.content == "Half an ans")
        #expect(reply.errorDescription == InterruptedReplies.message)
        #expect(withdrawn == [ReplyNotifier.pausedIdentifier(for: conversation.stableID)])
    }

    @Test func leftoverWithNoReplyTextGetsAnErrorReply() throws {
        let conversation = chat([(.user, "Hi")])
        replies.begin(conversation.stableID)
        replies.recover(in: context, notifier: notifier)

        #expect(conversation.orderedMessages.count == 2)
        let reply = try #require(conversation.orderedMessages.last)
        #expect(reply.role == .assistant)
        #expect(reply.isError)
    }

    @Test func finishedRepliesAreLeftAlone() throws {
        let conversation = chat([(.user, "Hi"), (.assistant, "Done")])
        replies.recover(in: context, notifier: notifier)
        #expect(conversation.orderedMessages.last?.isError == false)
    }
}
