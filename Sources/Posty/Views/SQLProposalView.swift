import SwiftUI

struct SQLProposalView: View {
    let original: String
    let proposal: SQLProposal
    let apply: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Proposed SQL", systemImage: proposal.destructive ? "exclamationmark.triangle" : "sparkles")
                    .font(.title2.bold())
                Spacer()
                Button("Reject", role: .cancel, action: reject)
                Button("Apply", action: apply).buttonStyle(.borderedProminent)
            }
            Text(proposal.message).foregroundStyle(.secondary)
            SQLDiffView(original: original, proposed: proposal.sql)
            if !proposal.assumptions.isEmpty {
                Text("Assumptions").font(.headline)
                ForEach(proposal.assumptions, id: \.self) { Text("• \($0)") }
            }
        }
        .padding()
        .frame(minWidth: 780, minHeight: 560)
    }
}
