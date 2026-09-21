import Foundation

indirect enum FilterExpression: Identifiable, Hashable, Sendable, Codable {
    enum Junction: String, Codable, CaseIterable, Sendable { case and, or }
    enum Operator: String, Codable, CaseIterable, Identifiable, Sendable {
        case equal = "="
        case notEqual = "!="
        case lessThan = "<"
        case lessThanOrEqual = "<="
        case greaterThan = ">"
        case greaterThanOrEqual = ">="
        case contains
        case startsWith
        case isNull
        case isNotNull
        case `in`

        var id: String { rawValue }
        var needsValue: Bool { self != .isNull && self != .isNotNull }
    }

    case predicate(id: UUID, column: String, typeName: String, operation: Operator, values: [String])
    case group(id: UUID, junction: Junction, children: [FilterExpression])

    var id: UUID {
        switch self {
        case .predicate(let id, _, _, _, _), .group(let id, _, _): id
        }
    }

    struct Compilation: Sendable {
        let sql: String
        let values: [String]
    }

    func compile(allowedColumns: Set<String>, startingAt: Int = 1) throws -> Compilation {
        switch self {
        case .predicate(_, let column, let typeName, let operation, let values):
            guard allowedColumns.contains(column) else { throw FilterError.unknownColumn(column) }
            let identifier = SQLIdentifier.quote(column)
            switch operation {
            case .isNull: return .init(sql: "\(identifier) IS NULL", values: [])
            case .isNotNull: return .init(sql: "\(identifier) IS NOT NULL", values: [])
            case .in:
                guard !values.isEmpty else { throw FilterError.missingValue }
                let placeholders = values.indices.map { "$\(startingAt + $0)::\(typeName)" }.joined(separator: ", ")
                return .init(sql: "\(identifier) IN (\(placeholders))", values: values)
            case .contains, .startsWith:
                guard let value = values.first else { throw FilterError.missingValue }
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                let pattern = operation == .contains ? "%\(escaped)%" : "\(escaped)%"
                return .init(sql: "\(identifier)::text ILIKE $\(startingAt) ESCAPE '\\\\'", values: [pattern])
            default:
                guard let value = values.first else { throw FilterError.missingValue }
                return .init(sql: "\(identifier) \(operation.rawValue) $\(startingAt)::\(typeName)", values: [value])
            }
        case .group(_, let junction, let children):
            var values: [String] = []
            var fragments: [String] = []
            for child in children {
                let compiled = try child.compile(allowedColumns: allowedColumns, startingAt: startingAt + values.count)
                values.append(contentsOf: compiled.values)
                fragments.append("(\(compiled.sql))")
            }
            guard !fragments.isEmpty else { return .init(sql: "TRUE", values: []) }
            return .init(sql: fragments.joined(separator: junction == .and ? " AND " : " OR "), values: values)
        }
    }
}

enum FilterError: LocalizedError {
    case unknownColumn(String)
    case missingValue

    var errorDescription: String? {
        switch self {
        case .unknownColumn(let column): "Unknown filter column: \(column)"
        case .missingValue: "The selected filter operator requires a value."
        }
    }
}
