import SwiftUI

/// What still has to be fixed before an editor can be left, shown in red as
/// a section footer. Renders nothing when there are no issues.
struct ValidationIssuesView: View {
    let issues: [String]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }
}
