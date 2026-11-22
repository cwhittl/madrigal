import SwiftUI

/// Explains what leaves the device and where it goes. Shown once before
/// first use, with `onAccept`, and from Settings without it.
struct DataDisclosureView: View {
    var onAccept: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if onAccept != nil {
                    HStack {
                        Spacer()
                        Image(.madrigalMark)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                        Spacer()
                    }
                }

                Text(DataDisclosure.intro)

                ForEach(DataDisclosure.points()) { point in
                    self.point(point.symbol, title: point.title, text: point.text)
                }

                Link(destination: AppConfig.privacyPolicyURL) {
                    Label("Read the full privacy policy", systemImage: "hand.raised")
                }
                .padding(.leading, 40)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Your Data")
        .safeAreaInset(edge: .bottom) {
            if let onAccept {
                Button(action: onAccept) {
                    Text("I Understand").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .frame(maxWidth: 560)
            }
        }
    }

    private func point(_ symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
