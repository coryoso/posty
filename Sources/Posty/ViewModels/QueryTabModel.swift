import Foundation
import Observation

@MainActor
@Observable
final class QueryTabModel {
    var document: QueryDocument
    var resultSets: [QueryResultSet] = []
    var selectedResultID: UUID?
    var isRunning = false
    var errorMessage: String?
    var pendingWriteSQL: String?
    var cursorUTF16Location = 0
    var chatMessages: [ChatMessage] = []
    var includeSelectedValues = false
    var pendingProposal: SQLProposal?
    var selectedValuePayload = ""
    var chartInstruction = ""
    var history: [QueryRunSummary] = []
    var resultLimit = 10_000
    var assistantModel: CodexBridge.AssistantModel = .terra
    private var executionTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?

    let session: DatabaseSession
    let store: LocalStore?
    let codex: CodexBridge
    private let schemaContext: () -> String
    private let onSave: (QueryDocument) -> Void
    private let onCatalogRefresh: () async -> Void

    init(
        document: QueryDocument,
        session: DatabaseSession,
        store: LocalStore?,
        codex: CodexBridge,
        schemaContext: @escaping () -> String,
        onSave: @escaping (QueryDocument) -> Void,
        onCatalogRefresh: @escaping () async -> Void
    ) {
        self.document = document
        self.session = session
        self.store = store
        self.codex = codex
        self.schemaContext = schemaContext
        self.onSave = onSave
        self.onCatalogRefresh = onCatalogRefresh
        if let store {
            Task { [weak self] in
                guard let self else { return }
                self.chatMessages = (try? await store.loadMessages(queryID: document.id)) ?? []
                self.history = (try? await store.loadHistory(connectionID: document.connectionID, databaseName: document.database)) ?? []
            }
        }
    }

    var selectedResult: QueryResultSet? {
        resultSets.first(where: { $0.id == selectedResultID }) ?? resultSets.last
    }

    func startRun(selection: String? = nil) {
        executionTask?.cancel()
        executionTask = Task { [weak self] in await self?.requestRun(selection: selection) }
    }

    func cancelExecution() {
        executionTask?.cancel()
        executionTask = nil
    }

    func requestRun(selection: String? = nil) async {
        let source = selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: String
        if let source, !source.isEmpty { target = source }
        else { target = SQLLexer.statement(at: cursorUTF16Location, in: document.sql)?.sql ?? document.sql }
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if SQLLexer.safety(of: target) == .potentiallyWriting {
            pendingWriteSQL = target
        } else {
            await execute(target)
        }
    }

    func confirmWrite() {
        guard let sql = pendingWriteSQL else { return }
        pendingWriteSQL = nil
        executionTask?.cancel()
        executionTask = Task { [weak self] in await self?.execute(sql) }
    }

    func execute(_ sql: String) async {
        isRunning = true
        errorMessage = nil
        let startedAt = Date()
        let start = ContinuousClock.now
        do {
            var produced: [QueryResultSet] = []
            let statements = SQLLexer.statements(in: sql)
            for statement in statements {
                produced.append(try await session.execute(statement.sql, limit: resultLimit))
            }
            resultSets = produced
            selectedResultID = produced.last?.id
            let count = produced.reduce(0) { $0 + $1.rows.count }
            try? await store?.addHistory(QueryRunSummary(
                id: UUID(), connectionID: document.connectionID, database: document.database, sql: sql,
                startedAt: startedAt, durationMilliseconds: Self.milliseconds(start.duration(to: .now)),
                rowCount: count, status: .succeeded, error: nil
            ))
            if statements.contains(where: { SQLLexer.modifiesSchema($0.sql) }) {
                await onCatalogRefresh()
            }
            await reloadHistory()
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            try? await store?.addHistory(QueryRunSummary(
                id: UUID(), connectionID: document.connectionID, database: document.database, sql: sql,
                startedAt: startedAt, durationMilliseconds: Self.milliseconds(start.duration(to: .now)), rowCount: 0,
                status: error is CancellationError ? .cancelled : .failed,
                error: error is CancellationError ? nil : error.localizedDescription
            ))
            await reloadHistory()
        }
        isRunning = false
        executionTask = nil
    }

    func save() async {
        document.updatedAt = .now
        do {
            try await store?.saveQuery(document)
            onSave(document)
        } catch { errorMessage = error.localizedDescription }
    }

    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    func sendChat(instruction rawInstruction: String) async {
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        let user = ChatMessage(id: UUID(), queryID: document.id, role: .user, text: instruction, createdAt: .now)
        chatMessages.append(user)
        isRunning = true
        do {
            try await store?.addMessage(user)
            let proposal = try await codex.proposeSQL(
                instruction: instruction,
                sql: document.sql,
                schemaContext: schemaContext(),
                selectedValues: includeSelectedValues && !selectedValuePayload.isEmpty ? selectedValuePayload : nil,
                model: assistantModel
            )
            pendingProposal = proposal
            let assistant = ChatMessage(id: UUID(), queryID: document.id, role: .assistant, text: proposal.message, createdAt: .now)
            chatMessages.append(assistant)
            try await store?.addMessage(assistant)
            includeSelectedValues = false
        } catch { errorMessage = error.localizedDescription }
        isRunning = false
    }

    func applyProposal() {
        guard let proposal = pendingProposal else { return }
        document.sql = proposal.sql
        pendingProposal = nil
        Task { await save() }
    }

    func proposeChart() async {
        guard let result = selectedResult else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let chart = try await codex.proposeChart(instruction: chartInstruction.isEmpty ? "Choose a useful visualization" : chartInstruction, result: result)
            document.chartSpecs.append(chart)
            chartInstruction = ""
            await save()
        } catch { errorMessage = error.localizedDescription }
    }

    func addChart(_ chart: ChartSpec) async {
        guard let result = selectedResult,
              result.columns.contains(where: { $0.name == chart.xColumn }),
              result.columns.contains(where: { $0.name == chart.yColumn }),
              chart.seriesColumn == nil || result.columns.contains(where: { $0.name == chart.seriesColumn }) else {
            errorMessage = "The chart references columns that are not present in this result."
            return
        }
        document.chartSpecs.append(chart)
        await save()
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let value = duration.components
        return Int(value.seconds * 1_000) + Int(value.attoseconds / 1_000_000_000_000_000)
    }

    private func reloadHistory() async {
        guard let store else { return }
        history = (try? await store.loadHistory(connectionID: document.connectionID, databaseName: document.database)) ?? history
    }
}
