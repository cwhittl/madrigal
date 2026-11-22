import Foundation
import Testing
@testable import Madrigal
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleIntelligenceProviderTests {

    @MainActor
    @Test func presetSetsSmallContextAndTheOnlyModel() {
        let config = ProviderConfig()
        let preset = ProviderPreset.all.first { $0.kind == .appleIntelligence }!
        preset.apply(to: config)
        #expect(config.kind == .appleIntelligence)
        #expect(!config.needsSecret)
        #expect(config.effectiveContextLimit == AppleIntelligence.defaultContextCharacterLimit)
        #expect(config.preferredModelID == AppleIntelligence.modelID)
        #expect(config.subtitle == "On-device")
    }

    @Test func configWithoutPresetIDResolvesByKind() {
        let config = ProviderConfig()
        config.kind = .appleIntelligence
        config.baseURL = ""
        #expect(config.preset.kind == .appleIntelligence)
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    @Test func systemMessagesBecomeInstructionsAndLastUserIsThePrompt() throws {
        let (transcript, prompt) = try AppleIntelligenceProvider.transcript(for: [
            OutgoingMessage(role: .system, content: "Be brief."),
            OutgoingMessage(role: .user, content: "Hi"),
            OutgoingMessage(role: .assistant, content: "Hello!"),
            OutgoingMessage(role: .user, content: "What's 2+2?")
        ])
        #expect(prompt == "What's 2+2?")
        #expect(transcript.count == 3)
        guard case .instructions = transcript[0],
              case .prompt = transcript[1],
              case .response = transcript[2]
        else {
            Issue.record("Unexpected entries: \(Array(transcript))")
            return
        }
    }

    @available(iOS 26, macOS 26, *)
    @Test func noUserMessageThrows() {
        #expect(throws: ChatProviderError.self) {
            try AppleIntelligenceProvider.transcript(for: [OutgoingMessage(role: .system, content: "x")])
        }
    }
    #endif
}
