import SwiftUI

/// Brand colors from the app icon, fixed so the indicator ignores `.tint`.
private enum MadrigalPalette {
    static let lavender = Color(red: 161 / 255, green: 119 / 255, blue: 255 / 255) // #A177FF
    static let iris = Color(red: 142 / 255, green: 100 / 255, blue: 255 / 255)     // #8E64FF
    static let violet = Color(red: 91 / 255, green: 43 / 255, blue: 224 / 255)     // #5B2BE0
    static let indigo = Color(red: 30 / 255, green: 26 / 255, blue: 51 / 255)      // #1E1A33
}

/// A working indicator drawn from the Madrigal mark: a comet-tailed gradient
/// ring circling three "voices" that rise in turn. Under Reduce Motion the ring
/// holds still and the dots only pulse.
struct MadrigalIndicator: View {
    enum Size {
        case mini, small, regular

        var diameter: CGFloat {
            switch self {
            case .mini: 12
            case .small: 16
            case .regular: 22
            }
        }
    }

    var size: Size = .regular
    var label: String = "Working"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let ringPeriod = 1.2
    private static let voicePeriod = 0.9

    private var diameter: CGFloat { size.diameter }
    private var lineWidth: CGFloat { diameter * 0.12 }
    private var dotSize: CGFloat { diameter * (size == .mini ? 0.22 : 0.14) }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ring(at: t)
                voices(at: t)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func ring(at t: TimeInterval) -> some View {
        let turns = reduceMotion ? 0 : t.truncatingRemainder(dividingBy: Self.ringPeriod) / Self.ringPeriod
        return Circle()
            .inset(by: lineWidth / 2)
            .trim(from: 0, to: 0.7)
            .stroke(
                // Fades back to clear past the head so the tail's round cap,
                // which wraps to the end of the gradient, stays invisible.
                AngularGradient(
                    stops: [
                        .init(color: MadrigalPalette.violet.opacity(0), location: 0),
                        .init(color: MadrigalPalette.violet, location: 0.3),
                        .init(color: MadrigalPalette.iris, location: 0.55),
                        .init(color: MadrigalPalette.lavender, location: 0.75),
                        .init(color: MadrigalPalette.lavender.opacity(0), location: 1),
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.radians(turns * 2 * .pi))
    }

    @ViewBuilder
    private func voices(at t: TimeInterval) -> some View {
        if size == .mini {
            voice(level: level(at: t, phase: 0))
        } else {
            HStack(spacing: dotSize * 0.6) {
                ForEach(0..<3) { i in
                    voice(level: level(at: t, phase: Double(i) / 3))
                }
            }
        }
    }

    /// One dot: violet at rest, lifting and brightening to lavender at `level` 1.
    private func voice(level: Double) -> some View {
        Circle()
            .fill(MadrigalPalette.violet)
            .overlay(Circle().fill(MadrigalPalette.lavender).opacity(level))
            .frame(width: dotSize, height: dotSize)
            .opacity(reduceMotion ? 0.35 + 0.65 * level : 1)
            .offset(y: reduceMotion || size == .mini ? 0 : -level * dotSize * 0.6)
    }

    /// 0…1 sine wave, delayed by `phase` cycles so the voices enter in turn.
    private func level(at t: TimeInterval, phase: Double) -> Double {
        (sin(2 * .pi * (t / Self.voicePeriod - phase)) + 1) / 2
    }
}

#Preview {
    let sizes: [MadrigalIndicator.Size] = [.mini, .small, .regular]
    HStack(spacing: 0) {
        ForEach([Color.white, MadrigalPalette.indigo], id: \.self) { background in
            HStack(spacing: 20) {
                ForEach(sizes, id: \.self) { MadrigalIndicator(size: $0) }
            }
            .padding(24)
            .background(background)
        }
    }
}
