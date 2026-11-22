import Foundation
import SwiftData
import Testing
@testable import Madrigal

@MainActor
struct ChatViewModelTests {

    private final class FakeScreenAwake: ScreenAwakeHolding {
        var begins = 0
        var ends = 0
        func begin() { begins += 1 }
        func end() { ends += 1 }
    }

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: MadrigalSchemaV1.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func viewModel(_ screen: FakeScreenAwake) -> ChatViewModel {
        ChatViewModel(
            notifier: ReplyNotifier(presence: { .active }, deliver: { _ in }, withdraw: { _ in }),
            screenAwake: screen
        )
    }

    @Test func sendWithoutProviderExplainsAndDoesNotHoldTheScreen() {
        let screen = FakeScreenAwake()
        let model = viewModel(screen)
        let conversation = Conversation()
        context.insert(conversation)

        model.draft = "Hello"
        model.send(in: conversation, configs: [], context: context)

        let messages = conversation.orderedMessages
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.last?.isError == true)
        #expect(!model.isStreaming)
        #expect(screen.begins == 0)
        #expect(model.draft.isEmpty)
    }

    @Test func blankDraftSendsNothing() {
        let model = viewModel(FakeScreenAwake())
        let conversation = Conversation()
        context.insert(conversation)

        model.draft = "   "
        model.send(in: conversation, configs: [], context: context)
        #expect((conversation.messages ?? []).isEmpty)
    }
}
