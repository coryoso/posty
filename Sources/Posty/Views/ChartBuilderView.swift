import SwiftUI

struct ChartBuilderView: View {
    let result: QueryResultSet
    let add: (ChartSpec) -> Void
    let cancel: () -> Void
    @State private var title = "Result Chart"
    @State private var mark: ChartSpec.Mark = .bar
    @State private var xColumn = ""
    @State private var yColumn = ""
    @State private var seriesColumn = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Chart").font(.title2.bold())
            Form {
                TextField("Title", text: $title)
                Picker("Style", selection: $mark) {
                    ForEach(ChartSpec.Mark.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("X axis", selection: $xColumn) {
                    Text("Choose a column").tag("")
                    ForEach(result.columns) { Text($0.name).tag($0.name) }
                }
                Picker("Y axis", selection: $yColumn) {
                    Text("Choose a numeric column").tag("")
                    ForEach(result.columns) { Text($0.name).tag($0.name) }
                }
                Picker("Series", selection: $seriesColumn) {
                    Text("None").tag("")
                    ForEach(result.columns) { Text($0.name).tag($0.name) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Create") {
                    add(ChartSpec(title: title, mark: mark, xColumn: xColumn, yColumn: yColumn, seriesColumn: seriesColumn.isEmpty ? nil : seriesColumn))
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.isEmpty || xColumn.isEmpty || yColumn.isEmpty)
            }
        }
        .padding()
        .frame(width: 460, height: 350)
    }
}
