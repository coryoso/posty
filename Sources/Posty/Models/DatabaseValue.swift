import Foundation

enum DatabaseValue: Hashable, Sendable, Codable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case numeric(String)
    case floating(Double)
    case string(String)
    case uuid(UUID)
    case binary(Data)
    case json(String)
    case date(String)
    case time(String)
    case timestamp(String)
    case interval(String)
    case enumeration(String)
    case array([DatabaseValue])
    case range(String)
    case fallback(typeName: String, display: String, raw: Data)

    var displayString: String {
        switch self {
        case .null: "NULL"
        case .boolean(let value): value ? "true" : "false"
        case .integer(let value): String(value)
        case .numeric(let value), .string(let value), .json(let value), .date(let value),
             .time(let value), .timestamp(let value), .interval(let value),
             .enumeration(let value), .range(let value): value
        case .floating(let value): value.formatted(.number.precision(.significantDigits(1...15)))
        case .uuid(let value): value.uuidString.lowercased()
        case .binary(let value): "\\x" + value.map { String(format: "%02x", $0) }.joined()
        case .array(let values): "[" + values.map(\.displayString).joined(separator: ", ") + "]"
        case .fallback(_, let display, _): display
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var postgresText: String {
        switch self {
        case .array(let values):
            return "{" + values.map { value in
                guard !value.isNull else { return "NULL" }
                let escaped = value.postgresText
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }.joined(separator: ",") + "}"
        default:
            return displayString
        }
    }

    var gridDisplayString: String {
        switch self {
        case .date(let value):
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.calendar = Calendar(identifier: .iso8601)
            parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = "yyyy-MM-dd"
            guard let date = parser.date(from: value) else { return value }
            return date.formatted(date: .abbreviated, time: .omitted)
        case .timestamp(let value):
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            return date?.formatted(date: .abbreviated, time: .standard) ?? value
        case .json(let source):
            guard let data = source.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: compact, encoding: .utf8) else { return source }
            return text
        default:
            return displayString
        }
    }
}

struct DatabaseTypeDescriptor: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Codable, Sendable {
        case boolean, integer, numeric, floating, text, uuid, binary, json
        case date, time, timestamp, interval, enumeration, array, range, composite, unknown
    }

    var id: UInt32 { oid }
    let oid: UInt32
    let schema: String
    let name: String
    let kind: Kind
    let category: String
    let elementOID: UInt32?
    let baseTypeOID: UInt32?
    let enumValues: [String]

    var qualifiedName: String { SQLIdentifier.qualified(schema, name) }
}

struct ResultColumn: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let typeOID: UInt32
    let typeName: String
    let tableOID: UInt32?
    let attributeNumber: Int16?
    let enumValues: [String]

    init(name: String, typeOID: UInt32, typeName: String, tableOID: UInt32? = nil, attributeNumber: Int16? = nil, enumValues: [String] = []) {
        self.id = UUID()
        self.name = name
        self.typeOID = typeOID
        self.typeName = typeName
        self.tableOID = tableOID
        self.attributeNumber = attributeNumber
        self.enumValues = enumValues
    }
}

struct ResultRow: Identifiable, Hashable, Sendable {
    let id: UUID
    var values: [DatabaseValue]
    var xmin: String?

    init(id: UUID = UUID(), values: [DatabaseValue], xmin: String? = nil) {
        self.id = id
        self.values = values
        self.xmin = xmin
    }
}

struct QueryResultSet: Identifiable, Sendable {
    let id: UUID
    var columns: [ResultColumn]
    var rows: [ResultRow]
    var commandTag: String
    var duration: Duration
    var wasTruncated: Bool

    init(
        id: UUID = UUID(),
        columns: [ResultColumn] = [],
        rows: [ResultRow] = [],
        commandTag: String = "",
        duration: Duration = .zero,
        wasTruncated: Bool = false
    ) {
        self.id = id
        self.columns = columns
        self.rows = rows
        self.commandTag = commandTag
        self.duration = duration
        self.wasTruncated = wasTruncated
    }
}
