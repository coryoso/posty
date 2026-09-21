import AppKit
import Foundation

@MainActor
enum ResultExporter {
    enum Format: String { case csv, json }

    static func export(_ result: QueryResultSet, selectedRows: Set<UUID>, format: Format) throws {
        let rows = selectedRows.isEmpty ? result.rows : result.rows.filter { selectedRows.contains($0.id) }
        let data: Data
        switch format {
        case .csv:
            let header = result.columns.map { csvField($0.name) }.joined(separator: ",")
            let body = rows.map { row in row.values.map { csvField($0.displayString) }.joined(separator: ",") }
            data = Data(([header] + body).joined(separator: "\n").utf8)
        case .json:
            let objects: [[String: Any]] = rows.map { row in
                Dictionary(uniqueKeysWithValues: zip(result.columns, row.values).map { ($0.name, jsonValue($1)) })
            }
            data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "posty-result.\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func jsonValue(_ value: DatabaseValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .boolean(let value): return value
        case .integer(let value): return value
        case .floating(let value): return value
        case .numeric(let value): return NSDecimalNumber(string: value)
        case .binary(let value): return value.base64EncodedString()
        case .json(let source):
            guard let data = source.data(using: .utf8) else { return source }
            return (try? JSONSerialization.jsonObject(with: data)) ?? source
        case .array(let values): return values.map(jsonValue)
        case .uuid(let value): return value.uuidString.lowercased()
        case .string(let value), .date(let value), .time(let value), .timestamp(let value),
             .interval(let value), .enumeration(let value), .range(let value): return value
        case .fallback(_, let display, _): return display
        }
    }
}
