import SwiftUI

struct QueryHistoryView: View {
    let history: [QueryRunSummary]
    let restore: (QueryRunSummary) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Query History").font(.title2.bold())
                Spacer()
                Button("Done", action: dismiss)
            }
            .padding()
            Divider()
            if history.isEmpty {
                ContentUnavailableView("No Query History", systemImage: "clock")
            } else {
                List(history) { run in
                    Button { restore(run) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: run.status == .succeeded ? "checkmark.circle.fill" : run.status == .cancelled ? "stop.circle" : "xmark.circle.fill")
                                    .foregroundStyle(run.status == .succeeded ? .green : run.status == .cancelled ? .secondary : .red)
                                Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                                Spacer()
                                Text("\(run.rowCount) rows · \(run.durationMilliseconds) ms").foregroundStyle(.secondary)
                            }
                            Text(run.sql).font(.caption.monospaced()).lineLimit(3).multilineTextAlignment(.leading)
                            if let error = run.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}
