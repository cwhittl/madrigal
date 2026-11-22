import SwiftUI

extension Binding {
    /// True while the optional holds a value; setting it to false clears
    /// it. For alerts, dialogs and sheets driven by an optional.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        // Only ever used on the main actor, by SwiftUI, like the bindings
        // this replaces; the optionals are often SwiftData models, which
        // aren't Sendable.
        nonisolated(unsafe) let binding = self
        return Binding<Bool>(
            get: { binding.wrappedValue != nil },
            set: { if !$0 { binding.wrappedValue = nil } }
        )
    }
}

extension View {
    /// For IDs, keys and URLs: on iOS, no autocapitalization or
    /// autocorrection, and the URL keyboard when `url` is true.
    @ViewBuilder
    func identifierEntry(url: Bool = false) -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(url ? .URL : .default)
        #else
        self
        #endif
    }

    /// A sheet's size on macOS, where sheets otherwise shrink to fit their
    /// content. No-op on iOS.
    @ViewBuilder
    func macSheetSize(
        minWidth: CGFloat, minHeight: CGFloat,
        idealWidth: CGFloat? = nil, idealHeight: CGFloat? = nil
    ) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight)
        #else
        self
        #endif
    }
}
