import SwiftUI

/// Decides when the transcript follows a streaming reply, from the scroll
/// geometry alone. No gestures: a drag on a text-selection handle or a
/// momentum scroll both look like what they are, a change in offset.
///
/// - The content moving down (the user scrolling up) stops following.
/// - Reaching the bottom again, however it happens, resumes it.
/// - The content or the viewport changing height (streamed text, the
///   thinking box toggling, the keyboard) scrolls to the bottom only while
///   following and while no text is selected, so what's being read or
///   selected never moves.
struct TranscriptFollowState: Equatable {
    enum Action: Equatable {
        case none
        case scrollToBottom
    }

    /// How close to the bottom counts as being there.
    static let bottomTolerance: CGFloat = 24

    private(set) var following = true
    private(set) var distanceFromBottom: CGFloat = 0
    /// A text selection is holding the view still.
    private(set) var isHeld = false
    private var lastMinY: CGFloat?
    private var lastContentHeight: CGFloat = 0
    private var lastViewportHeight: CGFloat = 0

    /// Only when the latest text is genuinely out of view, so the button
    /// can't sit over a transcript that's already at the bottom.
    var showsJumpButton: Bool {
        (!following || isHeld) && distanceFromBottom > Self.bottomTolerance
    }

    /// - Parameters:
    ///   - contentMinY: the top of the content in the scroll view's
    ///     coordinate space; it falls as the user scrolls down.
    mutating func update(
        contentMinY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        selectionActive: Bool
    ) -> Action {
        defer {
            lastMinY = contentMinY
            lastContentHeight = contentHeight
            lastViewportHeight = viewportHeight
        }
        distanceFromBottom = contentMinY + contentHeight - viewportHeight
        isHeld = selectionActive

        // Content that shrinks (the thinking box collapsing) can push the
        // offset back, so only a move with no shrink is the user's.
        let movedDown = lastMinY.map { contentMinY > $0 + 1 } ?? false
        if movedDown, contentHeight >= lastContentHeight - 0.5, distanceFromBottom > 1 {
            following = false
            return .none
        }

        let resized = abs(contentHeight - lastContentHeight) > 0.5
            || abs(viewportHeight - lastViewportHeight) > 0.5
        if resized {
            guard following, !selectionActive, distanceFromBottom > 0.5 else { return .none }
            return .scrollToBottom
        }

        if distanceFromBottom <= Self.bottomTolerance { following = true }
        return .none
    }

    /// A message was sent or added: show it.
    mutating func resumeFollowing() {
        following = true
        isHeld = false
    }
}

/// Holds the follow state and the live text selections outside SwiftUI's
/// dependency tracking: geometry arrives every scroll frame, and storing it
/// in `@State` would re-render the whole transcript each time.
@MainActor
final class TranscriptScrollTracker {
    var state = TranscriptFollowState()
    var contentFrame: CGRect = .zero
    var viewportHeight: CGFloat = 0
    var selections: Set<ObjectIdentifier> = []

    func update() -> TranscriptFollowState.Action {
        state.update(
            contentMinY: contentFrame.minY,
            contentHeight: contentFrame.height,
            viewportHeight: viewportHeight,
            selectionActive: !selections.isEmpty
        )
    }

    /// The user asked for the latest text: a lingering selection no longer
    /// holds the view.
    func resumeFollowing() {
        selections.removeAll()
        state.resumeFollowing()
    }

    func selectionChanged(_ view: ObjectIdentifier, isSelecting: Bool) {
        if isSelecting {
            selections.insert(view)
        } else {
            selections.remove(view)
        }
    }
}

extension EnvironmentValues {
    /// Told by `SelectableText` when its selection starts or ends, so the
    /// transcript holds still while text is selected. A reference rather
    /// than a closure: a closure is new on every render and can't be
    /// compared, so it would update every text view each time.
    @Entry var transcriptScrollTracker: TranscriptScrollTracker?
}

extension View {
    /// Opens at the bottom without anchoring later size changes there: an
    /// anchored scroll view shifts the text being read as a reply grows.
    /// Before iOS 18 / macOS 15 the anchor can't be limited to the initial
    /// offset, so the first geometry update scrolls down instead.
    @ViewBuilder
    func transcriptStartsAtBottom() -> some View {
        if #available(iOS 18, macOS 15, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            self
        }
    }
}

extension Message {
    /// Stable for the object's lifetime. `persistentModelID` changes from a
    /// temporary ID to a permanent one on the first save, which would
    /// rebuild the row (and jump the scroll) as a reply finishes.
    var stableID: ObjectIdentifier { ObjectIdentifier(self) }
}
