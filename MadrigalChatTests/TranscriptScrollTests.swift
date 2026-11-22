import CoreGraphics
import Testing
@testable import Madrigal

struct TranscriptScrollTests {
    /// A 600pt viewport over content scrolled so its bottom sits at the
    /// viewport's bottom: minY = viewport - height.
    private func atBottom(height: CGFloat = 2000, viewport: CGFloat = 600) -> CGFloat {
        viewport - height
    }

    private func settled(height: CGFloat = 2000) -> TranscriptFollowState {
        var state = TranscriptFollowState()
        _ = state.update(contentMinY: atBottom(height: height), contentHeight: height,
                         viewportHeight: 600, selectionActive: false)
        return state
    }

    @Test func growthWhileFollowingScrolls() {
        var state = settled()
        let action = state.update(contentMinY: atBottom(), contentHeight: 2040,
                                  viewportHeight: 600, selectionActive: false)
        #expect(action == .scrollToBottom)
        #expect(!state.showsJumpButton)
    }

    @Test func scrollingUpStopsFollowingAndShowsButton() {
        var state = settled()
        let action = state.update(contentMinY: atBottom() + 200, contentHeight: 2000,
                                  viewportHeight: 600, selectionActive: false)
        #expect(action == .none)
        #expect(!state.following)
        #expect(state.showsJumpButton)
    }

    @Test func scrollingUpDuringGrowthStillStopsFollowing() {
        var state = settled()
        let action = state.update(contentMinY: atBottom() + 10, contentHeight: 2040,
                                  viewportHeight: 600, selectionActive: false)
        #expect(action == .none)
        #expect(!state.following)
    }

    @Test func scrollingBackToBottomResumesAndHidesButton() {
        var state = settled()
        _ = state.update(contentMinY: atBottom() + 300, contentHeight: 2000,
                         viewportHeight: 600, selectionActive: false)
        _ = state.update(contentMinY: atBottom() + 10, contentHeight: 2000,
                         viewportHeight: 600, selectionActive: false)
        #expect(state.following)
        #expect(!state.showsJumpButton)
    }

    @Test func growthWhileNotFollowingLeavesTheViewAlone() {
        var state = settled()
        _ = state.update(contentMinY: atBottom() + 300, contentHeight: 2000,
                         viewportHeight: 600, selectionActive: false)
        let action = state.update(contentMinY: atBottom() + 300, contentHeight: 2100,
                                  viewportHeight: 600, selectionActive: false)
        #expect(action == .none)
        #expect(state.showsJumpButton)
    }

    @Test func growthWhileTextIsSelectedHoldsStill() {
        var state = settled()
        let action = state.update(contentMinY: atBottom(), contentHeight: 2100,
                                  viewportHeight: 600, selectionActive: true)
        #expect(action == .none)
        #expect(state.following)
        #expect(state.showsJumpButton)
    }

    @Test func shrinkingViewportWhileFollowingScrolls() {
        var state = settled()
        let action = state.update(contentMinY: atBottom(), contentHeight: 2000,
                                  viewportHeight: 300, selectionActive: false)
        #expect(action == .scrollToBottom)
    }

    @Test func shrinkingContentDoesNotCountAsScrollingUp() {
        var state = settled()
        // The thinking box collapses and the offset is clamped back.
        let action = state.update(contentMinY: atBottom(height: 1800), contentHeight: 1800,
                                  viewportHeight: 600, selectionActive: false)
        #expect(action == .none)
        #expect(state.following)
    }

    @Test func shortContentAlwaysFollows() {
        var state = TranscriptFollowState()
        _ = state.update(contentMinY: 0, contentHeight: 300, viewportHeight: 600, selectionActive: false)
        // Pulling down past the top: minY grows, but nothing is out of view.
        _ = state.update(contentMinY: 40, contentHeight: 300, viewportHeight: 600, selectionActive: false)
        #expect(state.following)
        #expect(!state.showsJumpButton)
    }

    @Test func resumeFollowingAfterSend() {
        var state = settled()
        _ = state.update(contentMinY: atBottom() + 300, contentHeight: 2000,
                         viewportHeight: 600, selectionActive: false)
        state.resumeFollowing()
        #expect(state.following)
        let action = state.update(contentMinY: atBottom() + 300, contentHeight: 2100,
                                  viewportHeight: 600, selectionActive: false)
        #expect(action == .scrollToBottom)
    }
}
