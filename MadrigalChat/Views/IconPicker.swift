import SwiftUI

/// A grid rather than a Picker: a menu of ~40 symbol names is a long
/// scroll on touch, and the names mean little next to the icons.
struct IconPicker: View {
    @Binding var selection: String

    private static let icons = [
        // Folders / documents
        "folder", "folder.fill", "tray", "archivebox", "doc", "paperclip",
        // Work / tools
        "briefcase", "hammer", "wrench.and.screwdriver", "gear",
        // Learning / ideas
        "book", "lightbulb", "brain", "graduationcap", "pencil", "sparkles",
        // Data / tech
        "chart.bar", "chart.line.uptrend.xyaxis", "cube", "terminal", "cpu",
        // Creative
        "paintbrush", "film", "music.note", "camera",
        // Communication
        "paperplane", "bubble.left.and.bubble.right", "envelope",
        // People / places
        "person", "house", "building.2", "globe",
        // Misc
        "flask", "star", "heart", "flag", "tag", "bolt", "leaf", "lock.shield",
    ]

    var body: some View {
        DisclosureGroup {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 4) {
                ForEach(Self.icons, id: \.self) { icon in
                    let selected = selection == icon
                    Button {
                        selection = icon
                    } label: {
                        Image(systemName: icon)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(.tint.opacity(selected ? 0.2 : 0), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    // Borderless so each icon gets its own tap inside the
                    // List-backed Form row.
                    .buttonStyle(.borderless)
                    .accessibilityLabel(icon)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        } label: {
            LabeledContent("Icon") {
                Image(systemName: selection)
            }
        }
    }
}

/// A row of preset color swatches, stored as hex strings.
struct ColorPalettePicker: View {
    @Binding var selection: String

    private static let colors = [Palette.defaultHex, "#9B6BDF", "#E5609A", "#E5534B", "#F0883E", "#D4A72C", "#3FB27F", "#2BA3B5", "#8B949E"]

    var body: some View {
        LabeledContent("Color") {
            HStack(spacing: 6) {
                ForEach(Self.colors, id: \.self) { hex in
                    let selected = selection.caseInsensitiveCompare(hex) == .orderedSame
                    Button {
                        selection = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay {
                                if selected {
                                    Circle().strokeBorder(.primary, lineWidth: 2)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(hex)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

extension Color {
    /// Parses `#RRGGBB`. Anything else falls back to the accent color.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .accentColor
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
