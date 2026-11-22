import Foundation
import Testing
@testable import Madrigal

@MainActor
struct ChatComposerTests {

    private func config(_ kind: ProviderKind) -> ProviderConfig {
        let config = ProviderConfig()
        config.kind = kind
        return config
    }

    @Test func onDeviceModelsSendOffline() {
        for kind in [ProviderKind.appleIntelligence, .localMLX] {
            let config = config(kind)
            #expect(ChatComposer.canSend(draft: "Hi", providers: [config], config: config, isOnline: false))
        }
    }

    @Test func hostedModelsNeedTheNetwork() {
        for kind in [ProviderKind.openAICompatible, .cloudflareWorkersAI] {
            let config = config(kind)
            #expect(!ChatComposer.canSend(draft: "Hi", providers: [config], config: config, isOnline: false))
            #expect(ChatComposer.canSend(draft: "Hi", providers: [config], config: config, isOnline: true))
        }
    }

    @Test func blankDraftsAndNoProvidersNeverSend() {
        let config = config(.localMLX)
        #expect(!ChatComposer.canSend(draft: " \n", providers: [config], config: config, isOnline: true))
        #expect(!ChatComposer.canSend(draft: "Hi", providers: [], config: nil, isOnline: true))
    }

    @Test func offlineNoticeOnlyWhenItMatters() {
        #expect(ChatComposer.offlineNotice(config: config(.openAICompatible), isOnline: true) == nil)
        #expect(ChatComposer.offlineNotice(config: config(.openAICompatible), isOnline: false) == "You're offline.")
        #expect(ChatComposer.offlineNotice(config: nil, isOnline: false) == "You're offline.")

        let local = config(.localMLX)
        #expect(ChatComposer.offlineNotice(config: local, isOnline: false) == nil)
        local.webSearchMode = .auto
        #expect(ChatComposer.offlineNotice(config: local, isOnline: false)?.contains("Web search") == true)
    }

    // MARK: - Newline insertion

    /// Runs the helper and returns the text plus the cursor as a character
    /// offset, so expectations are easy to read.
    private func newline(_ text: String, _ range: Range<String.Index>?) -> (String, Int) {
        let (result, cursor) = ChatComposer.insertingNewline(in: text, at: range)
        #expect(String.Index(cursor, within: result) != nil, "cursor must be on a character boundary")
        return (result, result.distance(from: result.startIndex, to: cursor))
    }

    private func offset(_ text: String, _ n: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: n)
    }

    @Test func newlineAtCursorInMiddle() {
        let text = "hello world"
        let point = offset(text, 5)
        let (result, cursor) = newline(text, point..<point)
        #expect(result == "hello\n world")
        #expect(cursor == 6)
    }

    @Test func newlineReplacesSelection() {
        let text = "hello world"
        let (result, cursor) = newline(text, offset(text, 5)..<offset(text, 6))
        #expect(result == "hello\nworld")
        #expect(cursor == 6)
    }

    @Test func newlineInEmptyText() {
        let (result, cursor) = newline("", "".startIndex..<"".endIndex)
        #expect(result == "\n")
        #expect(cursor == 1)

        let (noSelection, end) = newline("hi", nil)
        #expect(noSelection == "hi\n")
        #expect(end == 3)
    }

    @Test func staleIndexFromLongerStringAppendsAtEnd() {
        let longer = "hello there, world"
        let stale = offset(longer, 12)
        let (result, cursor) = newline("hi", stale..<longer.endIndex)
        #expect(result == "hi\n")
        #expect(cursor == 3)
    }

    @Test func indexInsideMultiByteCharacterAppendsAtEnd() {
        let text = "hi 👋 there"
        // One UTF-8 byte into the four-byte emoji: not a character boundary.
        let inside = text.utf8.index(offset(text, 3), offsetBy: 1)
        let (result, cursor) = newline(text, inside..<inside)
        #expect(result == "hi 👋 there\n")
        #expect(cursor == 11)
    }

    @Test func newlineNextToEmoji() {
        let text = "hi 👋👍🏽 there"
        let afterWave = offset(text, 4)
        let (result, cursor) = newline(text, afterWave..<afterWave)
        #expect(result == "hi 👋\n👍🏽 there")
        #expect(cursor == 5)

        // Cursor at the very end, right after an emoji.
        let ending = "bye 👋"
        let (atEnd, endCursor) = newline(ending, ending.endIndex..<ending.endIndex)
        #expect(atEnd == "bye 👋\n")
        #expect(endCursor == 6)
    }

    @Test func newlineWithUTF16Indices() {
        // AppKit hands back NSString-based (UTF-16) positions.
        let text = "hi 👋 there"
        let utf16 = text.utf16
        let point = utf16.index(utf16.startIndex, offsetBy: 5) // after the emoji
        let (result, cursor) = newline(text, point..<point)
        #expect(result == "hi 👋\n there")
        #expect(cursor == 5)
    }

    @Test func newlineAfterCarriageReturnDoesNotOvershoot() {
        // "\r" + "\n" merge into one character, which is what made a
        // character-offset cursor run past the end.
        let text = "line\r"
        let (result, cursor) = newline(text, text.endIndex..<text.endIndex)
        #expect(result == "line\r\n")
        #expect(cursor == 5)
    }
}
