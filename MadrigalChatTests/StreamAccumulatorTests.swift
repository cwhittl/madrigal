import Foundation
import Testing
@testable import Madrigal

struct StreamAccumulatorTests {

    private func text(_ fragment: String, final: Bool = false) -> ChatDelta {
        ChatDelta(textFragment: fragment, isFinal: final)
    }

    private func collect(_ stream: AsyncThrowingStream<StreamSnapshot, Error>) async throws -> [StreamSnapshot] {
        var snapshots: [StreamSnapshot] = []
        for try await snapshot in stream { snapshots.append(snapshot) }
        return snapshots
    }

    @Test func burstIsCoalescedAndFinalIsComplete() async throws {
        let (deltas, input) = AsyncThrowingStream<ChatDelta, Error>.makeStream()
        for index in 0..<500 { input.yield(text("\(index % 10)")) }
        input.yield(text("", final: true))
        input.finish()

        let snapshots = try await collect(StreamAccumulator.snapshots(of: deltas, every: .milliseconds(50)))

        #expect(snapshots.count < 10)
        #expect(snapshots.last?.answer.count == 500)
        #expect(snapshots.last?.received == true)
    }

    @Test func splitsThinkingAndStreamedReasoning() async throws {
        let (deltas, input) = AsyncThrowingStream<ChatDelta, Error>.makeStream()
        input.yield(ChatDelta(textFragment: "", reasoningFragment: "native", isFinal: false))
        input.yield(text("<think>inl"))
        input.yield(text("ine</think>Answer"))
        input.finish()

        let last = try #require(try await collect(StreamAccumulator.snapshots(of: deltas, every: .milliseconds(20))).last)
        #expect(last == StreamSnapshot(answer: "Answer", reasoning: "native\n\ninline", received: true))
    }

    @Test func textBeforeAPauseIsPublished() async throws {
        let (deltas, input) = AsyncThrowingStream<ChatDelta, Error>.makeStream()
        var iterator = StreamAccumulator.snapshots(of: deltas, every: .milliseconds(20)).makeAsyncIterator()

        input.yield(text("first"))
        // No further tokens and no end of stream: the ticker must still
        // deliver what arrived.
        let snapshot = try await iterator.next()
        #expect(snapshot?.answer == "first")
        input.finish()
    }

    @Test func emptyStreamYieldsNothing() async throws {
        let (deltas, input) = AsyncThrowingStream<ChatDelta, Error>.makeStream()
        input.yield(text("", final: true))
        input.finish()
        #expect(try await collect(StreamAccumulator.snapshots(of: deltas, every: .milliseconds(20))).isEmpty)
    }

    @Test func errorArrivesAfterThePartialText() async throws {
        let (deltas, input) = AsyncThrowingStream<ChatDelta, Error>.makeStream()
        input.yield(text("partial"))
        input.finish(throwing: ChatProviderError.streamError(message: "boom"))

        var received: [StreamSnapshot] = []
        await #expect(throws: ChatProviderError.self) {
            for try await snapshot in StreamAccumulator.snapshots(of: deltas, every: .seconds(10)) {
                received.append(snapshot)
            }
        }
        #expect(received.last?.answer == "partial")
    }

    @Test func cancellingTheConsumerCancelsTheSource() async throws {
        let (deltas, input) = AsyncThrowingStream<ChatDelta, Error>.makeStream()
        let terminated = AsyncStream<Void>.makeStream()
        input.onTermination = { _ in terminated.continuation.yield(); terminated.continuation.finish() }

        let consumer = Task {
            for try await _ in StreamAccumulator.snapshots(of: deltas, every: .milliseconds(20)) {}
        }
        input.yield(text("x"))
        consumer.cancel()

        var signal = terminated.stream.makeAsyncIterator()
        #expect(await signal.next() != nil)
    }
}
