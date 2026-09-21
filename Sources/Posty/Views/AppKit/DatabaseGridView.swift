import AppKit
import SwiftUI

struct DatabaseGridView: NSViewRepresentable {
    let columns: [ResultColumn]
    let rows: [ResultRow]
    @Binding var selection: Set<UUID>
    let editable: Bool
    let canEditCell: (UUID, Int) -> Bool
    let onEdit: (UUID, Int, DatabaseValue) -> Void
    let onOpenEditor: (UUID, Int, DatabaseValue) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 1, height: 1)
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.doubleAction = #selector(Coordinator.openValueEditor(_:))
        table.target = context.coordinator
        table.menu = context.coordinator.makeContextMenu()

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        context.coordinator.tableView = table
        context.coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scrollView.documentView as? NSTableView else { return }
        let current = table.tableColumns.map { $0.identifier.rawValue }
        let wanted = columns.indices.map(String.init)
        if current != wanted { context.coordinator.rebuildColumns() }
        table.reloadData()
        let indexes = IndexSet(rows.indices.filter { selection.contains(rows[$0].id) })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: DatabaseGridView
        weak var tableView: NSTableView?

        init(_ parent: DatabaseGridView) { self.parent = parent }

        func rebuildColumns() {
            guard let tableView else { return }
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            for (index, column) in parent.columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                tableColumn.title = column.name
                tableColumn.headerToolTip = column.typeName
                tableColumn.headerCell.image = NSImage(systemSymbolName: symbolName(for: column), accessibilityDescription: column.typeName)
                tableColumn.minWidth = 72
                tableColumn.width = initialWidth(for: column.name, at: index)
                tableColumn.maxWidth = 900
                tableView.addTableColumn(tableColumn)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let columnIndex = Int(tableColumn.identifier.rawValue),
                  parent.rows.indices.contains(row),
                  parent.rows[row].values.indices.contains(columnIndex) else { return nil }
            let cell = NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("DatabaseCell")
            let value = parent.rows[row].values[columnIndex]
            let cellIsEditable = parent.editable && parent.canEditCell(parent.rows[row].id, columnIndex)
            switch value {
            case .boolean(let checked):
                let checkbox = GridCheckbox(checkboxWithTitle: "", target: self, action: #selector(toggleBoolean(_:)))
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                checkbox.state = checked ? .on : .off
                checkbox.isEnabled = cellIsEditable
                checkbox.rowID = parent.rows[row].id
                checkbox.columnIndex = columnIndex
                cell.addSubview(checkbox)
                NSLayoutConstraint.activate([
                    checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                    checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            case .enumeration(let selected) where cellIsEditable && !parent.columns[columnIndex].enumValues.isEmpty:
                let popup = GridPopup()
                popup.translatesAutoresizingMaskIntoConstraints = false
                popup.addItems(withTitles: parent.columns[columnIndex].enumValues)
                popup.selectItem(withTitle: selected)
                popup.target = self
                popup.action = #selector(selectEnumeration(_:))
                popup.rowID = parent.rows[row].id
                popup.columnIndex = columnIndex
                cell.addSubview(popup)
                NSLayoutConstraint.activate([
                    popup.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                    popup.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                    popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            default:
                let field = NSTextField()
                field.translatesAutoresizingMaskIntoConstraints = false
                field.isBordered = false
                field.drawsBackground = false
                field.lineBreakMode = .byTruncatingTail
                field.usesSingleLineMode = true
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
                field.delegate = self
                field.identifier = NSUserInterfaceItemIdentifier(String(columnIndex))
                field.stringValue = value.gridDisplayString
                field.isEditable = cellIsEditable
                field.isSelectable = true
                field.textColor = value.isNull ? .tertiaryLabelColor : .labelColor
                field.toolTip = value.displayString
                cell.textField = field
                cell.addSubview(field)
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            return cell
        }

        @objc private func toggleBoolean(_ sender: GridCheckbox) {
            parent.onEdit(sender.rowID, sender.columnIndex, .boolean(sender.state == .on))
        }

        @objc private func selectEnumeration(_ sender: GridPopup) {
            guard let value = sender.selectedItem?.title else { return }
            parent.onEdit(sender.rowID, sender.columnIndex, .enumeration(value))
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            parent.selection = Set(tableView.selectedRowIndexes.compactMap { index in
                parent.rows.indices.contains(index) ? parent.rows[index].id : nil
            })
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard parent.editable,
                  let field = notification.object as? NSTextField,
                  let tableView,
                  tableView.row(for: field) >= 0,
                  tableView.column(for: field) >= 0 else { return }
            let rowIndex = tableView.row(for: field)
            let visualColumn = tableView.column(for: field)
            guard tableView.tableColumns.indices.contains(visualColumn),
                  let columnIndex = Int(tableView.tableColumns[visualColumn].identifier.rawValue) else { return }
            guard parent.rows.indices.contains(rowIndex),
                  parent.rows[rowIndex].values.indices.contains(columnIndex) else { return }
            let row = parent.rows[rowIndex]
            guard parent.canEditCell(row.id, columnIndex) else { return }
            let oldValue = row.values[columnIndex]
            if field.stringValue == oldValue.gridDisplayString { return }
            do {
                let value = try oldValue.replacingDisplayValue(with: field.stringValue)
                parent.onEdit(row.id, columnIndex, value)
            } catch {
                NSSound.beep()
                field.stringValue = oldValue.displayString
                showError(error.localizedDescription)
            }
        }

        @objc func openValueEditor(_ sender: Any?) {
            guard parent.editable, let tableView else { return }
            let rowIndex = tableView.clickedRow
            let visualColumn = tableView.clickedColumn
            guard tableView.tableColumns.indices.contains(visualColumn),
                  let columnIndex = Int(tableView.tableColumns[visualColumn].identifier.rawValue),
                  parent.rows.indices.contains(rowIndex),
                  parent.rows[rowIndex].values.indices.contains(columnIndex) else { return }
            let row = parent.rows[rowIndex]
            guard parent.canEditCell(row.id, columnIndex) else { return }
            let original = row.values[columnIndex]
            guard original.prefersExpandedEditor else {
                tableView.editColumn(visualColumn, row: rowIndex, with: nil, select: true)
                return
            }
            parent.onOpenEditor(row.id, columnIndex, original)
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy Selected Rows", action: #selector(copyRows(_:)), keyEquivalent: "c").target = self
            menu.addItem(withTitle: "Copy as JSON", action: #selector(copyJSON(_:)), keyEquivalent: "") .target = self
            return menu
        }

        @objc private func copyRows(_ sender: Any?) {
            guard let tableView else { return }
            let indexes = tableView.selectedRowIndexes.isEmpty && tableView.clickedRow >= 0
                ? IndexSet(integer: tableView.clickedRow) : tableView.selectedRowIndexes
            let text = indexes.compactMap { index -> String? in
                guard parent.rows.indices.contains(index) else { return nil }
                return parent.rows[index].values.map(\.displayString).joined(separator: "\t")
            }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func copyJSON(_ sender: Any?) {
            guard let tableView else { return }
            let indexes = tableView.selectedRowIndexes.isEmpty && tableView.clickedRow >= 0
                ? IndexSet(integer: tableView.clickedRow) : tableView.selectedRowIndexes
            let objects: [[String: Any]] = indexes.compactMap { index in
                guard parent.rows.indices.contains(index) else { return nil }
                return Dictionary(uniqueKeysWithValues: zip(parent.columns, parent.rows[index].values).map {
                    ($0.name, $1.jsonObject)
                })
            }
            guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        private func initialWidth(for name: String, at columnIndex: Int) -> CGFloat {
            let samples = parent.rows.prefix(50).compactMap { row in
                row.values.indices.contains(columnIndex) ? row.values[columnIndex].displayString.count : nil
            }
            let characters = max(name.count, samples.max() ?? 0)
            return min(360, max(90, CGFloat(characters) * 7.2 + 20))
        }

        private func showError(_ message: String) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Invalid Value"
            alert.informativeText = message
            alert.runModal()
        }

        private func symbolName(for column: ResultColumn) -> String {
            if !column.enumValues.isEmpty { return "list.bullet" }
            let type = column.typeName.lowercased()
            if type.contains("bool") { return "checkmark.square" }
            if type.contains("json") { return "curlybraces.square" }
            if type.contains("timestamp") || type == "date" || type.contains("time") { return "calendar" }
            if type.contains("int") || type.contains("numeric") || type.contains("decimal") || type.contains("float") || type.contains("double") { return "number" }
            if type.contains("uuid") { return "key.horizontal" }
            if type.contains("bytea") { return "doc.zipper" }
            if type.hasSuffix("[]") { return "square.stack.3d.up" }
            return "textformat"
        }
    }
}

private final class GridCheckbox: NSButton {
    var rowID = UUID()
    var columnIndex = 0
}

private final class GridPopup: NSPopUpButton {
    var rowID = UUID()
    var columnIndex = 0
}

extension DatabaseValue {
    var prefersExpandedEditor: Bool {
        switch self {
        case .json, .array, .binary: true
        case .string(let value): value.contains("\n") || value.count > 180
        default: false
        }
    }

    var prettyEditingString: String {
        let object: Any
        switch self {
        case .json(let source):
            guard let data = source.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) else { return displayString }
            object = decoded
        case .array(let values):
            object = values.map(\.jsonObject)
        default:
            return displayString
        }
        guard let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: formatted, encoding: .utf8) else { return displayString }
        return result
    }

    func replacingDisplayValue(with input: String) throws -> DatabaseValue {
        if input == "NULL" { return .null }
        switch self {
        case .null, .string: return .string(input)
        case .boolean:
            guard let value = Bool(strictString: input) else { throw CellEditingError.invalidBoolean }
            return .boolean(value)
        case .integer:
            guard let value = Int64(input) else { throw CellEditingError.invalidInteger }
            return .integer(value)
        case .numeric:
            guard Decimal(string: input, locale: Locale(identifier: "en_US_POSIX")) != nil else { throw CellEditingError.invalidNumber }
            return .numeric(input)
        case .floating:
            guard let value = Double(input) else { throw CellEditingError.invalidNumber }
            return .floating(value)
        case .uuid:
            guard let value = UUID(uuidString: input) else { throw CellEditingError.invalidUUID }
            return .uuid(value)
        case .binary:
            if input.hasPrefix("base64:") {
                guard let data = Data(base64Encoded: String(input.dropFirst("base64:".count))) else { throw CellEditingError.invalidBinary }
                return .binary(data)
            }
            let source = input.hasPrefix("\\x") ? String(input.dropFirst(2)) : input
            guard source.count.isMultiple(of: 2), source.allSatisfy({ $0.isHexDigit }) else { throw CellEditingError.invalidBinary }
            var data = Data()
            var cursor = source.startIndex
            while cursor < source.endIndex {
                let end = source.index(cursor, offsetBy: 2)
                data.append(UInt8(source[cursor..<end], radix: 16)!)
                cursor = end
            }
            return .binary(data)
        case .json:
            guard let data = input.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else { throw CellEditingError.invalidJSON }
            return .json(input)
        case .date: return .date(input)
        case .time: return .time(input)
        case .timestamp: return .timestamp(input)
        case .interval: return .interval(input)
        case .enumeration: return .enumeration(input)
        case .array(let current):
            guard let data = input.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [Any] else { throw CellEditingError.invalidArray }
            let template = current.first(where: { !$0.isNull })
            return .array(try values.map { try Self.fromJSONValue($0, template: template) })
        case .range: return .range(input)
        case .fallback(let type, _, _): return .fallback(typeName: type, display: input, raw: Data(input.utf8))
        }
    }

    private static func fromJSONValue(_ object: Any, template: DatabaseValue?) throws -> DatabaseValue {
        if object is NSNull { return .null }
        if let value = object as? Bool { return .boolean(value) }
        if let value = object as? NSNumber {
            let number = value.doubleValue
            return number.rounded() == number ? .integer(value.int64Value) : .floating(number)
        }
        if let values = object as? [Any] {
            let nestedTemplate: DatabaseValue?
            if case .array(let existing) = template { nestedTemplate = existing.first(where: { !$0.isNull }) }
            else { nestedTemplate = nil }
            return .array(try values.map { try fromJSONValue($0, template: nestedTemplate) })
        }
        guard let value = object as? String else { throw CellEditingError.invalidArray }
        switch template {
        case .enumeration: return .enumeration(value)
        case .uuid: return UUID(uuidString: value).map(DatabaseValue.uuid) ?? .string(value)
        case .date: return .date(value)
        case .time: return .time(value)
        case .timestamp: return .timestamp(value)
        case .interval: return .interval(value)
        case .range: return .range(value)
        default: return .string(value)
        }
    }

    var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .boolean(let value): return value
        case .integer(let value): return value
        case .numeric(let value):
            if let decimal = Decimal(string: value) { return NSDecimalNumber(decimal: decimal) }
            return value
        case .floating(let value): return value
        case .uuid(let value): return value.uuidString.lowercased()
        case .binary(let value): return value.base64EncodedString()
        case .json(let source):
            guard let data = source.data(using: .utf8) else { return source }
            return (try? JSONSerialization.jsonObject(with: data)) ?? source
        case .array(let values): return values.map(\.jsonObject)
        case .string(let value), .date(let value), .time(let value), .timestamp(let value),
             .interval(let value), .enumeration(let value), .range(let value): return value
        case .fallback(_, let display, _): return display
        }
    }
}

private enum CellEditingError: LocalizedError {
    case invalidBoolean, invalidInteger, invalidNumber, invalidUUID, invalidBinary, invalidJSON, invalidArray

    var errorDescription: String? {
        switch self {
        case .invalidBoolean: "Enter true or false."
        case .invalidInteger: "Enter a valid whole number."
        case .invalidNumber: "Enter a valid number."
        case .invalidUUID: "Enter a valid UUID."
        case .invalidBinary: "Enter even-length hexadecimal data, optionally prefixed with \\x."
        case .invalidJSON: "The JSON document is not valid."
        case .invalidArray: "Enter a valid JSON array."
        }
    }
}

private extension Bool {
    init?(strictString: String) {
        switch strictString.lowercased() {
        case "true", "t", "1", "yes": self = true
        case "false", "f", "0", "no": self = false
        default: return nil
        }
    }
}
