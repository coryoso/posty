import Foundation
import Observation

@MainActor
@Observable
final class RelationTabModel {
    let details: RelationDetails
    let session: DatabaseSession
    let codex: CodexBridge

    var result = QueryResultSet()
    var page = 0
    var filter: FilterExpression?
    var manualFilters: [FilterExpression] = []
    var orderBy: (column: String, ascending: Bool)?
    var selectedRows: Set<UUID> = []
    var mutations: [PendingRowMutation] = []
    var isLoading = false
    var errorMessage: String?
    var naturalLanguage = ""
    var includeSelectedValues = false
    var selectedSection = "Content"
    var valueSuggestions: [String] = []
    var showsValueSuggestions = false

    init(details: RelationDetails, session: DatabaseSession, codex: CodexBridge) {
        self.details = details
        self.session = session
        self.codex = codex
    }

    var isEditable: Bool {
        !details.stableKeyColumns.isEmpty && details.canUpdate && [.table, .partitionedTable].contains(details.object.kind)
    }

    var canInsert: Bool { !details.stableKeyColumns.isEmpty && details.canInsert }
    var canDelete: Bool { !details.stableKeyColumns.isEmpty && details.canDelete }

    var canDeleteSelection: Bool {
        guard !selectedRows.isEmpty else { return false }
        return canDelete || selectedRows.allSatisfy { rowID in
            mutations.contains { $0.originalRowID == rowID && $0.kind == .insert }
        }
    }

    func canEditCell(rowID: UUID, columnIndex: Int) -> Bool {
        guard details.columns.indices.contains(columnIndex) else { return false }
        let column = details.columns[columnIndex]
        guard column.generated == nil, column.identity == nil else { return false }
        if mutations.contains(where: { $0.originalRowID == rowID && $0.kind == .insert }) { return canInsert }
        return isEditable
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            filter = manualFilters.isEmpty ? filter : .group(id: UUID(), junction: .and, children: manualFilters)
            result = try await session.fetchTable(details, filter: filter, orderBy: orderBy, page: page)
            selectedRows.removeAll()
        } catch { errorMessage = error.localizedDescription }
    }

    func addFilter(column: CatalogColumn, operation: FilterExpression.Operator, value: String) async {
        let values = operation.needsValue ? (operation == .in ? value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : [value]) : []
        manualFilters.append(.predicate(id: UUID(), column: column.name, typeName: column.formattedType, operation: operation, values: values))
        filter = .group(id: UUID(), junction: .and, children: manualFilters)
        page = 0
        await load()
    }

    func removeFilter(id: UUID) async {
        manualFilters.removeAll { $0.id == id }
        filter = manualFilters.isEmpty ? nil : .group(id: UUID(), junction: .and, children: manualFilters)
        page = 0
        await load()
    }

    func applyNaturalLanguageFilter() async {
        let prompt = naturalLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let values = includeSelectedValues ? selectedValuesPayload : nil
            filter = try await codex.naturalLanguageFilter(instruction: prompt, columns: details.columns, selectedValues: values)
            manualFilters = flatten(filter)
            page = 0
            naturalLanguage = ""
            includeSelectedValues = false
            result = try await session.fetchTable(details, filter: filter, orderBy: orderBy, page: page)
        } catch { errorMessage = error.localizedDescription }
    }

    func loadValueSuggestions(columnName: String, prefix: String) async {
        guard let column = details.columns.first(where: { $0.name == columnName }) else { return }
        do {
            valueSuggestions = try await session.suggestedValues(column: column, relation: details.object, prefix: prefix)
            showsValueSuggestions = true
        } catch { errorMessage = error.localizedDescription }
    }

    func stageEdit(rowID: UUID, columnIndex: Int, value: DatabaseValue) {
        guard let row = result.rows.first(where: { $0.id == rowID }),
              result.columns.indices.contains(columnIndex),
              canEditCell(rowID: rowID, columnIndex: columnIndex) else { return }
        guard row.values[columnIndex] != value else { return }
        let columnName = result.columns[columnIndex].name
        if let index = mutations.firstIndex(where: { $0.originalRowID == rowID && $0.kind == .insert }) {
            guard canInsert else { return }
            mutations[index].changedValues[columnName] = value
        } else {
            guard isEditable else { return }
            if let index = mutations.firstIndex(where: { $0.originalRowID == rowID && $0.kind == .update }) {
                mutations[index].changedValues[columnName] = value
            } else {
                mutations.append(PendingRowMutation(
                    kind: .update,
                    originalRowID: rowID,
                    keyValues: keyValues(for: row),
                    changedValues: [columnName: value],
                    xmin: row.xmin
                ))
            }
        }
        if let rowIndex = result.rows.firstIndex(where: { $0.id == rowID }) {
            result.rows[rowIndex].values[columnIndex] = value
        }
    }

    func stageDeleteSelected() {
        let rows = result.rows.filter { selectedRows.contains($0.id) }
        for row in rows {
            if mutations.contains(where: { $0.originalRowID == row.id && $0.kind == .insert }) {
                mutations.removeAll { $0.originalRowID == row.id }
                result.rows.removeAll { $0.id == row.id }
                continue
            }
            guard canDelete else { continue }
            mutations.removeAll { $0.originalRowID == row.id }
            mutations.append(PendingRowMutation(kind: .delete, originalRowID: row.id, keyValues: keyValues(for: row), changedValues: [:], xmin: row.xmin))
        }
        selectedRows.removeAll()
    }

    func addRow() {
        guard canInsert else { return }
        let values = details.columns.map { _ in DatabaseValue.null }
        let row = ResultRow(values: values)
        result.rows.insert(row, at: 0)
        mutations.append(PendingRowMutation(kind: .insert, originalRowID: row.id, keyValues: [:], changedValues: [:], xmin: nil))
        selectedRows = [row.id]
    }

    func save() async {
        do {
            for index in mutations.indices where mutations[index].kind == .insert {
                guard let rowID = mutations[index].originalRowID,
                      let row = result.rows.first(where: { $0.id == rowID }) else { continue }
                for (columnIndex, column) in details.columns.enumerated() where !row.values[columnIndex].isNull {
                    mutations[index].changedValues[column.name] = row.values[columnIndex]
                }
            }
            try await session.saveMutations(mutations, for: details)
            mutations.removeAll()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func discardChanges() async {
        mutations.removeAll()
        await load()
    }

    func nextPage() async { page += 1; await load() }
    func previousPage() async { page = max(0, page - 1); await load() }

    private func keyValues(for row: ResultRow) -> [String: DatabaseValue] {
        Dictionary(uniqueKeysWithValues: details.stableKeyColumns.compactMap { key in
            guard let index = details.columns.firstIndex(where: { $0.name == key.name }), row.values.indices.contains(index) else { return nil }
            return (key.name, row.values[index])
        })
    }

    var selectedValuesPayload: String? {
        let rows = result.rows.filter { selectedRows.contains($0.id) }.prefix(20)
        guard !rows.isEmpty else { return nil }
        return rows.map { row in
            zip(result.columns, row.values).map { "\($0.name)=\($1.displayString)" }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    private func flatten(_ filter: FilterExpression?) -> [FilterExpression] {
        guard let filter else { return [] }
        if case .group(_, .and, let children) = filter { return children }
        return [filter]
    }
}
