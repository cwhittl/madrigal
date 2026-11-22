import SwiftUI

/// A user message in a native, read-only text view, so part of it can be
/// selected. On iOS a SwiftUI `Text` only copies whole. Replies don't need
/// this: they're drawn selectable in place by `SelectableText`.
struct SelectableTextSheet: View {
    let content: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                SelectableText(text: NSAttributedString(string: content, attributes: SelectableStyle.base))
                    .padding(16)
            }
            .navigationTitle("Select Text")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Copy All") { Clipboard.copy(content) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .macSheetSize(minWidth: 520, minHeight: 420, idealWidth: 640, idealHeight: 560)
    }
}
