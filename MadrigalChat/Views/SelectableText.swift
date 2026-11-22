import SwiftUI

/// Styled text in a native, read-only text view sized to its content, so a
/// selection can run across paragraphs, lists and headings. SwiftUI's `Text`
/// selection stops at each `Text` and, on iOS, only copies a whole one.
struct SelectableText {
    let text: NSAttributedString
    @Environment(\.transcriptScrollTracker) private var scrollTracker

    /// Tells the transcript when this view's selection starts and ends, so it
    /// doesn't scroll text out from under the user mid-selection.
    @MainActor
    final class Coordinator: NSObject {
        weak var scrollTracker: TranscriptScrollTracker?
        private var isSelecting = false

        nonisolated override init() { super.init() }

        func report(_ selecting: Bool, from view: AnyObject) {
            guard selecting != isSelecting else { return }
            isSelecting = selecting
            scrollTracker?.selectionChanged(ObjectIdentifier(view), isSelecting: selecting)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// What a copy puts on the pasteboard: no colours, so the text takes the
    /// destination's (dark-mode label colours would paste as white), and
    /// line separators as plain newlines.
    nonisolated static func copyable(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: copy.length))
        copy.mutableString.replaceOccurrences(
            of: "\u{2028}", with: "\n", options: [], range: NSRange(location: 0, length: copy.length)
        )
        return copy
    }
}

#if os(iOS)
extension SelectableText.Coordinator: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        report(textView.selectedRange.length > 0, from: textView)
    }
}

extension SelectableText: UIViewRepresentable {
    func makeUIView(context: Context) -> TextView {
        // TextKit 1, laid out in full, so new lines draw as soon as the height grows.
        // TextKit 2 draws lazily and leaves a blank gap while a reply streams in.
        let view = TextView(usingTextLayoutManager: false)
        view.layoutManager.allowsNonContiguousLayout = false
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.scrollTracker = scrollTracker
        // Only on a real change, so a selection survives unrelated updates.
        guard !view.attributedText.isEqual(to: text) else { return }
        let selection = view.selectedRange
        view.attributedText = text
        if selection.length > 0, NSMaxRange(selection) <= text.length {
            view.selectedRange = selection
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: TextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let size = view.sizeThatFits(CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        return CGSize(width: width ?? ceil(size.width), height: ceil(size.height))
    }

    static func dismantleUIView(_ view: TextView, coordinator: Coordinator) {
        coordinator.report(false, from: view)
    }

    final class TextView: UITextView {
        override func copy(_ sender: Any?) {
            guard selectedRange.length > 0 else { return }
            Clipboard.copy(SelectableText.copyable(attributedText.attributedSubstring(from: selectedRange)))
        }
    }
}
#else
extension SelectableText.Coordinator: NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        report(textView.selectedRange().length > 0, from: textView)
    }
}

extension SelectableText: NSViewRepresentable {
    func makeNSView(context: Context) -> TextView {
        // TextKit 1, so the layout manager can measure the height directly.
        let view = TextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        context.coordinator.scrollTracker = scrollTracker
        // Only on a real change, so a selection survives unrelated updates.
        guard let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        let selection = view.selectedRange()
        storage.setAttributedString(text)
        if selection.length > 0, NSMaxRange(selection) <= text.length {
            view.setSelectedRange(selection)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layoutManager = view.layoutManager else { return nil }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        // Measure at the proposed width, then put the container back to the
        // view's own width. SwiftUI probes with several widths, and if the
        // frame it settles on is unchanged, nothing else resets the
        // container, so the text would draw wrapped to the last probe and
        // spill over whatever is below it.
        let restore = view.bounds.width > 0 ? NSSize(width: view.bounds.width, height: container.size.height) : container.size
        container.size = NSSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        container.size = restore
        return CGSize(width: width ?? ceil(used.width), height: ceil(used.height))
    }

    static func dismantleNSView(_ view: TextView, coordinator: Coordinator) {
        coordinator.report(false, from: view)
    }

    final class TextView: NSTextView {
        override func copy(_ sender: Any?) {
            let range = selectedRange()
            guard range.length > 0, let storage = textStorage else { return }
            Clipboard.copy(SelectableText.copyable(storage.attributedSubstring(from: range)))
        }
    }
}
#endif
