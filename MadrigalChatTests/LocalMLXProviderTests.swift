import Foundation
import Testing
@testable import Madrigal

struct LocalMLXProviderTests {

    private func message(_ role: MessageRole, _ content: String) -> OutgoingMessage {
        OutgoingMessage(role: role, content: content)
    }

    private func pairs(_ turns: [OutgoingMessage]) -> [[String]] {
        turns.map { [$0.role.rawValue, $0.content] }
    }

    // MARK: - Preset

    @MainActor
    @Test func presetSetsContextLimitAndNeedsNoSecret() {
        let config = ProviderConfig()
        let preset = ProviderPreset.all.first { $0.kind == .localMLX }!
        preset.apply(to: config)
        #expect(config.kind == .localMLX)
        #expect(!config.needsSecret)
        #expect(config.effectiveContextLimit == LocalMLX.defaultContextCharacterLimit)
        #expect(config.resolvedBaseURL.isEmpty)
        // Counts this device's downloads, not a synced list.
        let count = LocalModelStore.shared.installedIDs.count
        #expect(config.subtitle == "On-device \u{00B7} \(count) model\(count == 1 ? "" : "s")")
    }

    @Test func configWithoutPresetIDResolvesByKind() {
        let config = ProviderConfig()
        config.kind = .localMLX
        config.baseURL = ""
        #expect(config.preset.kind == .localMLX)
    }

    // MARK: - Chat mapping

    @Test func systemMessagesFoldIntoOneLeadingMessage() throws {
        let turns = try LocalMLX.chatTurns(for: [
            message(.system, "Be brief."),
            message(.system, "Project notes."),
            message(.user, "Hi"),
            message(.assistant, "Hello!"),
            message(.user, "What's 2+2?")
        ])
        #expect(pairs(turns) == [
            ["system", "Be brief.\n\nProject notes."],
            ["user", "Hi"],
            ["assistant", "Hello!"],
            ["user", "What's 2+2?"]
        ])
    }

    @Test func turnsAlternateAndEndWithTheUser() throws {
        let turns = try LocalMLX.chatTurns(for: [
            message(.assistant, "Greeting from an agent"),
            message(.user, "One"),
            message(.user, "Two"),
            message(.assistant, ""),
            message(.assistant, "Reply"),
            message(.user, "Three"),
            message(.assistant, "Trailing")
        ])
        #expect(pairs(turns) == [
            ["user", "One\n\nTwo"],
            ["assistant", "Reply"],
            ["user", "Three"]
        ])
    }

    @Test func noUserMessageThrows() {
        #expect(throws: ChatProviderError.self) {
            try LocalMLX.chatTurns(for: [message(.system, "x"), message(.assistant, "y")])
        }
    }

    // MARK: - Reasoning

    /// MLX streams detokenized text with the tags inline, split anywhere.
    @Test func thinkTagsAcrossChunksBecomeReasoning() async throws {
        let (deltas, input) = AsyncThrowingStream<ChatDelta, Error>.makeStream()
        for chunk in ["<th", "ink>\nLet me", " count.\n</th", "ink>\n\nFour."] {
            input.yield(ChatDelta(textFragment: chunk, isFinal: false))
        }
        input.yield(ChatDelta(textFragment: "", isFinal: true))
        input.finish()

        var last = StreamSnapshot()
        for try await snapshot in StreamAccumulator.snapshots(of: deltas, every: .milliseconds(20)) {
            last = snapshot
        }
        #expect(last.reasoning == "Let me count.")
        #expect(last.answer == "Four.")
    }

    /// Templates that open the think block themselves only stream the close.
    @Test func prefilledThinkOpenerStillSplits() {
        let (reasoning, answer) = InlineThinking.split("Planning.\n</think>\n\nDone.")
        #expect(reasoning == "Planning.")
        #expect(answer == "Done.")
    }

    // MARK: - Fit rating

    private let gib: UInt64 = 1 << 30

    private func size(_ id: String) -> Int64 {
        LocalModelStore.catalog.first { $0.id == id }!.sizeBytes
    }

    @Test func fitOnAnEightGigabytePhone() {
        let ram = 8 * gib
        #expect(LocalModelFit.fit(modelBytes: size("mlx-community/Qwen3-1.7B-4bit"), physicalMemory: ram, usableFraction: 0.6) == .recommended)
        #expect(LocalModelFit.fit(modelBytes: size("mlx-community/gemma-3-4b-it-qat-4bit"), physicalMemory: ram, usableFraction: 0.6) == .tight)
        #expect(LocalModelFit.fit(modelBytes: size("mlx-community/Qwen3-8B-4bit"), physicalMemory: ram, usableFraction: 0.6) == .tooLarge)
    }

    @Test func eightBillionFitsASixteenGigabyteMac() {
        #expect(LocalModelFit.fit(modelBytes: size("mlx-community/Qwen3-8B-4bit"), physicalMemory: 16 * gib, usableFraction: 0.7) == .recommended)
    }

    @Test func recommendedMemoryRoundsUpToWholeGigabytes() {
        // (4.62 GB × 1.2 + 0.5 GiB) / 0.6 ≈ 9.4 GiB.
        #expect(LocalModelFit.recommendedMemoryGB(modelBytes: size("mlx-community/Qwen3-8B-4bit"), usableFraction: 0.6) == 10)
    }

    // MARK: - Not downloaded

    #if !targetEnvironment(simulator) && arch(arm64)
    @Test func modelNotOnThisDeviceExplainsWhy() async throws {
        let model = "mlx-community/not-a-real-model-\(UUID().uuidString)"
        let stream = LocalMLXProvider().streamCompletion(
            messages: [message(.user, "Hi")],
            model: model,
            options: GenerationOptions()
        )
        do {
            for try await _ in stream { }
            Issue.record("Expected the stream to fail")
        } catch ChatProviderError.unavailable(let reason) {
            #expect(reason == LocalMLX.notDownloadedMessage(for: model))
            #expect(reason.hasSuffix("isn't downloaded on this device. Download it in Settings."))
        }
    }
    #endif
}
