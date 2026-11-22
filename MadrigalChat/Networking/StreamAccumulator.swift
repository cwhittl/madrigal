import Foundation
import os

/// Everything a stream has produced so far, split into answer and thinking.
struct StreamSnapshot: Sendable, Equatable {
    var answer: String = ""
    var reasoning: String = ""
    /// Whether any text or reasoning arrived at all.
    var received: Bool = false
    /// The provider's latest status, such as "Searching: …", until text
    /// arrives after it.
    var status: String = ""
    /// Web searches run for this reply, in order.
    var searches: [WebSearchRecord] = []
}

/// Turns a provider's per-token deltas into periodic snapshots, off the main
/// actor. Appending tokens and re-splitting inline `<think>` tags happen
/// here, so whoever consumes the snapshots (the UI, on the main actor) only
/// wakes up about once per `interval`, however fast tokens arrive.
enum StreamAccumulator {

    /// Yields a snapshot at most once per `interval` while there is new
    /// text, plus a final one when the stream ends, even if it ends with an
    /// error. Snapshots are cumulative, so a slow consumer only ever sees
    /// the newest. Cancelling the consumer cancels the underlying stream.
    static func snapshots(
        of deltas: AsyncThrowingStream<ChatDelta, Error>,
        every interval: Duration
    ) -> AsyncThrowingStream<StreamSnapshot, Error> {
        let (output, continuation) = AsyncThrowingStream<StreamSnapshot, Error>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        let buffer = Buffer()

        // Created from a nonisolated context, so this runs on the global
        // executor rather than the caller's actor.
        let task = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Reader: cheap appends only.
                    group.addTask {
                        for try await delta in deltas {
                            buffer.append(delta)
                            if delta.isFinal { break }
                        }
                    }
                    // Ticker: publishes on a clock rather than on token
                    // arrival, so text before a pause still shows up.
                    group.addTask {
                        while true {
                            try await Task.sleep(for: interval)
                            if let snapshot = buffer.snapshotIfChanged() {
                                continuation.yield(snapshot)
                            }
                        }
                    }
                    // The ticker never finishes on its own, so this is the
                    // reader ending (or throwing, which leaves the group).
                    try await group.next()
                    group.cancelAll()
                }
                if let snapshot = buffer.snapshotIfChanged() { continuation.yield(snapshot) }
                continuation.finish()
            } catch {
                if let snapshot = buffer.snapshotIfChanged() { continuation.yield(snapshot) }
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return output
    }

    /// The raw accumulated text, shared between the reader and the ticker.
    private final class Buffer: Sendable {
        private struct State {
            var rawText = ""
            var streamedReasoning = ""
            var received = false
            var status = ""
            var searches: [WebSearchRecord] = []
            var changed = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func append(_ delta: ChatDelta) {
            let hasText = !delta.textFragment.isEmpty || !delta.reasoningFragment.isEmpty
            guard hasText || !delta.status.isEmpty || delta.search != nil else { return }
            state.withLock {
                if let search = delta.search { $0.searches.append(search) }
                if !delta.status.isEmpty { $0.status = delta.status }
                if hasText {
                    // Accumulated raw so inline <think> tags can be re-split as
                    // they arrive, possibly across chunk boundaries.
                    $0.rawText += delta.textFragment
                    $0.streamedReasoning += delta.reasoningFragment
                    $0.received = true
                    $0.status = ""
                }
                $0.changed = true
            }
        }

        /// nil if nothing arrived since the last snapshot. The split runs
        /// outside the lock; the copies taken under it are copy-on-write.
        func snapshotIfChanged() -> StreamSnapshot? {
            let copy: State? = state.withLock {
                guard $0.changed else { return nil }
                $0.changed = false
                return $0
            }
            guard let copy else { return nil }

            let (inlineReasoning, answer) = InlineThinking.split(copy.rawText)
            let reasoning = [copy.streamedReasoning, inlineReasoning]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            return StreamSnapshot(
                answer: answer, reasoning: reasoning, received: copy.received,
                status: copy.status, searches: copy.searches
            )
        }
    }
}
