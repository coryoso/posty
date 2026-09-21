import Charts
import SwiftUI

struct QueryTabView: View {
    @Bindable var model: QueryTabModel
    let catalog: CatalogSnapshot
    let aiAvailable: Bool
    let aiStatus: String
    @State private var selectedSQL = ""
    @State private var resultMode = "Table"
    @State private var showProposal = false
    @State private var showChartBuilder = false
    @State private var resultSelection: Set<UUID> = []
    @State private var showHistory = false
    @State private var showChat = true

    var body: some View {
        VSplitView {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Query name", text: $model.document.name).textFieldStyle(.plain).font(.headline)
                        Spacer()
                        Button { showChat.toggle() } label: { Label("Assistant", systemImage: "sidebar.trailing") }
                        Button { showHistory = true } label: { Label("History", systemImage: "clock") }
                        Button { Task { await model.save() } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        if model.isRunning {
                            Button { model.cancelExecution() } label: { Label("Cancel", systemImage: "stop.fill") }
                        } else {
                            Button { model.startRun(selection: selectedSQL) } label: { Label("Run", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: [.command])
                        }
                    }
                    .padding(8)
                    Divider()
                    SQLTextEditor(
                        text: $model.document.sql,
                        selectedText: $selectedSQL,
                        cursorUTF16Location: $model.cursorUTF16Location,
                        completions: completionWords,
                        editable: true
                    )
                }
                if showChat {
                    SQLAssistantPane(model: model, aiAvailable: aiAvailable, aiStatus: aiStatus)
                        .frame(minWidth: 280, idealWidth: 350, maxWidth: 520)
                }
            }
            resultPane.frame(minHeight: 220)
        }
        .onChange(of: model.pendingProposal) { _, value in showProposal = value != nil }
        .onChange(of: model.document.sql) { _, _ in model.scheduleAutosave() }
        .sheet(isPresented: $showProposal) {
            if let proposal = model.pendingProposal {
                SQLProposalView(original: model.document.sql, proposal: proposal) {
                    model.applyProposal()
                    showProposal = false
                } reject: {
                    model.pendingProposal = nil
                    showProposal = false
                }
            }
        }
        .sheet(isPresented: $showChartBuilder) {
            if let result = model.selectedResult {
                ChartBuilderView(result: result) { chart in
                    Task { await model.addChart(chart) }
                    resultMode = chart.id.uuidString
                    showChartBuilder = false
                } cancel: {
                    showChartBuilder = false
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            QueryHistoryView(history: model.history) { run in
                model.document.sql = run.sql
                showHistory = false
            } dismiss: {
                showHistory = false
            }
        }
        .alert("Run Writing SQL?", isPresented: Binding(get: { model.pendingWriteSQL != nil }, set: { if !$0 { model.pendingWriteSQL = nil } })) {
            Button("Cancel", role: .cancel) { model.pendingWriteSQL = nil }
            Button("Run", role: .destructive) { model.confirmWrite() }
        } message: {
            Text("This statement may modify the database. Review it before running:\n\n\(model.pendingWriteSQL ?? "")")
        }
        .alert("Query Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var resultPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Display", selection: $resultMode) {
                    Text("Table").tag("Table")
                    ForEach(model.document.chartSpecs) { Text($0.title).tag($0.id.uuidString) }
                }
                .frame(maxWidth: 300)
                if model.resultSets.count > 1 {
                    Picker("Result", selection: $model.selectedResultID) {
                        ForEach(Array(model.resultSets.enumerated()), id: \.element.id) { index, result in
                            Text("Result \(index + 1)").tag(Optional(result.id))
                        }
                    }.frame(width: 140)
                }
                Picker("Limit", selection: $model.resultLimit) {
                    Text("1,000 rows").tag(1_000)
                    Text("10,000 rows").tag(10_000)
                    Text("50,000 rows").tag(50_000)
                }
                .frame(width: 125)
                Spacer()
                TextField("Chart request", text: $model.chartInstruction).frame(width: 220)
                Button { Task { await model.proposeChart() } } label: { Label("Chart", systemImage: "chart.xyaxis.line") }
                    .disabled(!aiAvailable || model.selectedResult == nil || model.isRunning)
                    .help(aiAvailable ? "Propose a chart with Terra" : aiStatus)
                Button { showChartBuilder = true } label: { Label("Build", systemImage: "plus") }
                    .disabled(model.selectedResult == nil)
                Menu("Export") {
                    Button("CSV…") { export(result: model.selectedResult, format: .csv) }
                    Button("JSON…") { export(result: model.selectedResult, format: .json) }
                }
                .disabled(model.selectedResult == nil)
                if let result = model.selectedResult {
                    Text("\(result.rows.count) rows · \(duration(result.duration))").foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .padding(7)
            .background(.bar)
            Divider()
            if let result = model.selectedResult {
                if resultMode == "Table" {
                    DatabaseGridView(
                        columns: result.columns,
                        rows: result.rows,
                        selection: $resultSelection,
                        editable: false,
                        canEditCell: { _, _ in false },
                        onEdit: { _, _, _ in },
                        onOpenEditor: { _, _, _ in }
                    )
                } else if let id = UUID(uuidString: resultMode), let spec = model.document.chartSpecs.first(where: { $0.id == id }) {
                    ResultChartView(spec: spec, result: result).padding()
                }
            } else {
                ContentUnavailableView("No Results", systemImage: "tablecells", description: Text("Run the current statement with ⌘↩."))
            }
        }
    }

    private var completionWords: [String] {
        let keywords = ["SELECT", "FROM", "WHERE", "JOIN", "LEFT JOIN", "GROUP BY", "ORDER BY", "LIMIT", "INSERT", "UPDATE", "DELETE", "RETURNING", "WITH", "CASE", "WHEN", "THEN", "END", "NULL", "TRUE", "FALSE"]
        let columns = catalog.columns.flatMap { column -> [String] in
            guard let relation = catalog.objects.first(where: { $0.oid == column.relationOID }) else { return [column.name] }
            return [column.name, "\(relation.name).\(column.name)", "\(relation.schema).\(relation.name).\(column.name)"]
        }
        let enumValues = catalog.columns.flatMap(\.enumValues)
        return Array(Set(keywords + catalog.objects.map(\.name) + catalog.objects.map { "\($0.schema).\($0.name)" } + columns + enumValues))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func duration(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return String(format: "%.0f ms", milliseconds)
    }

    private func export(result: QueryResultSet?, format: ResultExporter.Format) {
        guard let result else { return }
        do { try ResultExporter.export(result, selectedRows: resultSelection, format: format) }
        catch { model.errorMessage = error.localizedDescription }
    }
}

private struct SQLAssistantPane: View {
    @Bindable var model: QueryTabModel
    let aiAvailable: Bool
    let aiStatus: String
    @State private var chatInput = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("SQL Assistant", systemImage: "bubble.left.and.sparkles").font(.headline)
                Spacer()
                Picker("Model", selection: $model.assistantModel) {
                    ForEach(CodexBridge.AssistantModel.allCases) { model in Text(model.title).tag(model) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(!aiAvailable)
                .help(aiAvailable ? "Choose the assistant model" : aiStatus)
                .accessibilityIdentifier("assistantModel")
            }
            .padding(9)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.chatMessages) { message in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(message.role == .user ? "You" : "Assistant").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(message.role == .user ? Color.accentColor.opacity(0.11) : Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                            .id(message.id)
                        }
                    }
                    .padding(9)
                }
                .onChange(of: model.chatMessages.count) { _, _ in
                    if let id = model.chatMessages.last?.id { proxy.scrollTo(id) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                TextField("Ask the assistant to change this query", text: $chatInput, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("assistantPrompt")
                Toggle("Include selected values", isOn: $model.includeSelectedValues).toggleStyle(.checkbox).font(.caption)
                if model.includeSelectedValues {
                    TextField("Exact values to attach", text: $model.selectedValuePayload, axis: .vertical)
                        .lineLimit(2...4).font(.caption.monospaced())
                }
                HStack {
                    if model.isRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Send") {
                        let instruction = chatInput
                        chatInput = ""
                        Task { await model.sendChat(instruction: instruction) }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!aiAvailable || chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
                        .help(aiAvailable ? "Send to the selected model" : aiStatus)
                }
            }
            .padding(9)
        }
        .background(.thinMaterial)
    }
}

private struct ResultChartView: View {
    let spec: ChartSpec
    let result: QueryResultSet

    private struct Point: Identifiable {
        let id = UUID()
        let x: String
        let y: Double
        let series: String
    }

    private var points: [Point] {
        guard let xIndex = result.columns.firstIndex(where: { $0.name == spec.xColumn }),
              let yIndex = result.columns.firstIndex(where: { $0.name == spec.yColumn }) else { return [] }
        let seriesIndex = spec.seriesColumn.flatMap { name in result.columns.firstIndex(where: { $0.name == name }) }
        return result.rows.compactMap { row in
            guard row.values.indices.contains(xIndex), row.values.indices.contains(yIndex), let y = row.values[yIndex].doubleValue else { return nil }
            return Point(x: row.values[xIndex].displayString, y: y, series: seriesIndex.map { row.values[$0].displayString } ?? spec.title)
        }
    }

    var body: some View {
        Chart(points) { point in
            switch spec.mark {
            case .bar: BarMark(x: .value(spec.xColumn, point.x), y: .value(spec.yColumn, point.y)).foregroundStyle(by: .value("Series", point.series))
            case .line: LineMark(x: .value(spec.xColumn, point.x), y: .value(spec.yColumn, point.y)).foregroundStyle(by: .value("Series", point.series))
            case .area: AreaMark(x: .value(spec.xColumn, point.x), y: .value(spec.yColumn, point.y)).foregroundStyle(by: .value("Series", point.series))
            case .scatter: PointMark(x: .value(spec.xColumn, point.x), y: .value(spec.yColumn, point.y)).foregroundStyle(by: .value("Series", point.series))
            }
        }
        .chartScrollableAxes(.horizontal)
    }
}

private extension DatabaseValue {
    var doubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .numeric(let value): Double(value)
        case .floating(let value): value
        default: nil
        }
    }
}
