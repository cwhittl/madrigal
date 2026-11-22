import SwiftUI

extension View {
    /// Pads small icon buttons out to the 44pt touch minimum on iOS; no-op on
    /// macOS, where a pointer doesn't need the extra room.
    @ViewBuilder
    func touchTarget() -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        #else
        self
        #endif
    }

    /// Makes a `.plain` button's label respond across the whole row, including
    /// the empty space a `Spacer` leaves, rather than only where there's text.
    func fullRowTappable() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
