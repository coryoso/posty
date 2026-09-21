import SwiftUI

struct RelationTabView: View {
    @Bindable var model: RelationTabModel
    let aiAvailable: Bool
    let aiStatus: String
    @State private var filterColumn = ""
    @State private var filterOperator: FilterExpression.Operator = .equal
    @State private var filterValue = ""
    @State private var cellEditor: CellEditorRequest?

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedSection == "Content" {
                filterBar
                Divider()
            }
            switch model.selectedSection {
            case "Structure": structureView
            case "DDL": ddlView
            default: contentView
            }
            Divider()
            tableBar
        }
        .alert("Database Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(item: $cellEditor) { request in
            DatabaseValueEditorSheet(request: request) { value in
                model.stageEdit(rowID: request.rowID, columnIndex: request.columnIndex, value: value)
                cellEditor = nil
            } cancel: {
                cellEditor = nil
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 7) {
            HStack {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(model.manualFilters) { filter in
                            FilterChip(filter: filter) { Task { await model.removeFilter(id: filter.id) } }
                        }
                    }
                }
                Picker("Column", selection: $filterColumn) {
                    Text("Column").tag("")
                    ForEach(model.details.columns) { Text($0.name).tag($0.name) }
                }
                .frame(width: 150)
                Picker("Operator", selection: $filterOperator) {
                    ForEach(FilterExpression.Operator.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 110)
                if filterOperator.needsValue {
                    TextField("Value", text: $filterValue).frame(width: 140)
                    Button {
                        Task { await model.loadValueSuggestions(columnName: filterColumn, prefix: filterValue) }
                    } label: {
                        Image(systemName: "list.bullet.circle")
                    }
                    .help("Look up matching values")
                    .disabled(filterColumn.isEmpty)
                    .popover(isPresented: $model.showsValueSuggestions) {
                        List(model.valueSuggestions, id: \.self) { value in
                            Button(value) {
                                filterValue = value
                                model.showsValueSuggestions = false
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: 300, height: 260)
                    }
                }
                Button("Add") {
                    guard let column = model.details.columns.first(where: { $0.name == filterColumn }) else { return }
                    Task { await model.addFilter(column: column, operation: filterOperator, value: filterValue) }
                    filterValue = ""
                }
                .disabled(filterColumn.isEmpty || (filterOperator.needsValue && filterValue.isEmpty))
            }
            HStack {
                TextField("Describe a filter in natural language", text: $model.naturalLanguage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.applyNaturalLanguageFilter() } }
                Toggle("Include selected values", isOn: $model.includeSelectedValues)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button { Task { await model.applyNaturalLanguageFilter() } } label: { Label("Build Filter", systemImage: "sparkles") }
                    .disabled(!aiAvailable || model.naturalLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(aiAvailable ? "Build a validated filter with AI" : aiStatus)
            }
            if model.includeSelectedValues {
                Text(model.selectedValuesPayload ?? "No selected rows will be sent")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(.bar)
    }

    private var contentView: some View {
        DatabaseGridView(
            columns: model.result.columns,
            rows: model.result.rows,
            selection: $model.selectedRows,
            editable: model.isEditable || model.canInsert,
            canEditCell: model.canEditCell,
            onEdit: model.stageEdit,
            onOpenEditor: { rowID, columnIndex, value in
                guard model.result.columns.indices.contains(columnIndex) else { return }
                cellEditor = CellEditorRequest(
                    rowID: rowID,
                    columnIndex: columnIndex,
                    columnName: model.result.columns[columnIndex].name,
                    value: value
                )
            }
        )
    }

    private var tableBar: some View {
        HStack {
            Picker("Section", selection: $model.selectedSection) {
                Text("Content").tag("Content")
                Text("Structure").tag("Structure")
                Text("DDL").tag("DDL")
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            if model.selectedSection == "Content" {
                Button { model.addRow() } label: { Label("Row", systemImage: "plus") }
                    .disabled(!model.canInsert)
                Button(role: .destructive) { model.stageDeleteSelected() } label: { Label("Delete", systemImage: "trash") }
                    .disabled(!model.canDeleteSelection)
                Menu("Export") {
                    Button("CSV…") { export(.csv) }
                    Button("JSON…") { export(.json) }
                }
                if !model.mutations.isEmpty {
                    Divider().frame(height: 18)
                    Text("\(model.mutations.count) staged").foregroundStyle(.secondary)
                    Button("Discard") { Task { await model.discardChanges() } }
                    Button("Save") { Task { await model.save() } }.buttonStyle(.borderedProminent)
                }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Text("\(model.result.rows.count) rows").foregroundStyle(.secondary)
                Button { Task { await model.previousPage() } } label: { Image(systemName: "chevron.left") }
                    .disabled(model.page == 0)
                Text("Page \(model.page + 1)")
                Button { Task { await model.nextPage() } } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.result.wasTruncated)
            }
        }
        .controlSize(.small)
        .padding(8)
        .background(.bar)
    }

    private var structureView: some View {
        List {
            Section("Columns") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                    GridRow { Text("Name").bold(); Text("Type").bold(); Text("Nullable").bold(); Text("Default").bold() }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(model.details.columns) { column in
                        GridRow {
                            Label(column.name, systemImage: column.systemImage).font(.body.monospaced())
                            Text(column.formattedType)
                            Image(systemName: column.nullable ? "checkmark" : "minus")
                            Text(column.defaultExpression ?? "—").lineLimit(1)
                        }
                    }
                }
            }
            Section("Constraints") {
                ForEach(model.details.constraints) { item in
                    VStack(alignment: .leading) { Text(item.name).font(.headline); Text(item.definition).font(.body.monospaced()) }
                }
            }
            Section("Indexes") {
                ForEach(model.details.indexes) { Text($0.definition).font(.body.monospaced()) }
            }
            Section("Triggers") {
                ForEach(model.details.triggers) { Text($0.definition).font(.body.monospaced()) }
            }
            Section("Row-level security") {
                ForEach(model.details.policies) { Text("\($0.name): \($0.command)") }
            }
            Section("Grants") {
                ForEach(model.details.grants) { grant in
                    Text("\(grant.grantee): \(grant.privilege)\(grant.isGrantable ? " (grantable)" : "")")
                }
            }
            Section("Dependencies") {
                ForEach(model.details.dependencies) { dependency in
                    Text("\(dependency.direction): \(dependency.object)").help(dependency.kind)
                }
            }
        }
    }

    private var ddlView: some View {
        ScrollView {
            Text(model.details.definition)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    private func export(_ format: ResultExporter.Format) {
        do { try ResultExporter.export(model.result, selectedRows: model.selectedRows, format: format) }
        catch { model.errorMessage = error.localizedDescription }
    }
}

private struct FilterChip: View {
    let filter: FilterExpression
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(label).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
    }

    private var label: String {
        switch filter {
        case .predicate(_, let column, _, let operation, let values):
            "\(column) \(operation.rawValue) \(values.joined(separator: ", "))"
        case .group(_, let junction, let children): "\(children.count) filters (\(junction.rawValue.uppercased()))"
        }
    }
}
