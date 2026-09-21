import Foundation

enum CatalogObjectKind: String, Codable, CaseIterable, Sendable {
    case table
    case partitionedTable
    case view
    case materializedView
    case sequence
    case function
    case procedure
    case type
    case extensionObject = "extension"

    var title: String {
        switch self {
        case .table: "Tables"
        case .partitionedTable: "Partitioned Tables"
        case .view: "Views"
        case .materializedView: "Materialized Views"
        case .sequence: "Sequences"
        case .function: "Functions"
        case .procedure: "Procedures"
        case .type: "Types"
        case .extensionObject: "Extensions"
        }
    }

    var systemImage: String {
        switch self {
        case .table, .partitionedTable: "tablecells"
        case .view, .materializedView: "eye"
        case .sequence: "number"
        case .function, .procedure: "function"
        case .type: "curlybraces"
        case .extensionObject: "puzzlepiece.extension"
        }
    }
}

struct CatalogObject: Identifiable, Hashable, Sendable, Codable {
    var id: String { "\(databaseOID).\(oid).\(kind.rawValue)" }
    let databaseOID: UInt32
    let oid: UInt32
    let schema: String
    let name: String
    let kind: CatalogObjectKind
    let comment: String?
    let estimatedRows: Int64?
    let totalBytes: Int64?
    let parentOID: UInt32?

    var qualifiedName: String { SQLIdentifier.qualified(schema, name) }
}

struct CatalogColumn: Identifiable, Hashable, Sendable, Codable {
    var id: String { "\(relationOID).\(attributeNumber)" }
    let relationOID: UInt32
    let attributeNumber: Int
    let name: String
    let typeOID: UInt32
    let formattedType: String
    let nullable: Bool
    let defaultExpression: String?
    let identity: String?
    let generated: String?
    let comment: String?
    let enumValues: [String]

    var systemImage: String {
        let type = formattedType.lowercased()
        if type.contains("bool") { return "checkmark.square" }
        if type.contains("json") { return "curlybraces.square" }
        if type.contains("timestamp") || type == "date" || type.contains("time") { return "calendar" }
        if type.contains("int") || type.contains("numeric") || type.contains("decimal") || type.contains("float") || type.contains("double") { return "number" }
        if type.contains("uuid") { return "key.horizontal" }
        if type.contains("bytea") { return "doc.zipper" }
        if type.hasSuffix("[]") { return "square.stack.3d.up" }
        if !enumValues.isEmpty { return "list.bullet" }
        return "textformat"
    }
}

struct CatalogConstraint: Identifiable, Hashable, Sendable, Codable {
    var id: UInt32 { oid }
    let oid: UInt32
    let name: String
    let type: String
    let definition: String
    let columns: [String]
    let referencedRelation: String?
}

struct CatalogIndex: Identifiable, Hashable, Sendable, Codable {
    var id: UInt32 { oid }
    let oid: UInt32
    let name: String
    let definition: String
    let isUnique: Bool
    let isPrimary: Bool
    let isValid: Bool
}

struct CatalogTrigger: Identifiable, Hashable, Sendable, Codable {
    var id: UInt32 { oid }
    let oid: UInt32
    let name: String
    let definition: String
    let enabled: String
}

struct CatalogPolicy: Identifiable, Hashable, Sendable, Codable {
    var id: String { "\(name).\(command)" }
    let name: String
    let command: String
    let roles: [String]
    let usingExpression: String?
    let checkExpression: String?
}

struct CatalogGrant: Identifiable, Hashable, Sendable, Codable {
    var id: String { "\(grantee).\(privilege)" }
    let grantee: String
    let privilege: String
    let isGrantable: Bool
}

struct CatalogDependency: Identifiable, Hashable, Sendable, Codable {
    var id: String { "\(direction).\(object).\(kind)" }
    let direction: String
    let object: String
    let kind: String
}

struct RelationDetails: Hashable, Sendable, Codable {
    let object: CatalogObject
    let columns: [CatalogColumn]
    let constraints: [CatalogConstraint]
    let indexes: [CatalogIndex]
    let triggers: [CatalogTrigger]
    let policies: [CatalogPolicy]
    let grants: [CatalogGrant]
    let dependencies: [CatalogDependency]
    let canInsert: Bool
    let canUpdate: Bool
    let canDelete: Bool
    let definition: String

    var stableKeyColumns: [CatalogColumn] {
        let identity = constraints.first(where: { $0.type == "p" })
            ?? constraints.first(where: { constraint in
                constraint.type == "u" && constraint.columns.allSatisfy { name in
                    columns.first(where: { $0.name == name })?.nullable == false
                }
            })
        guard let identity else { return [] }
        return identity.columns.compactMap { key in columns.first(where: { $0.name == key }) }
    }
}

struct CatalogSnapshot: Sendable, Codable {
    let serverVersionNumber: Int
    let serverVersion: String
    let databaseOID: UInt32
    let databaseName: String
    let objects: [CatalogObject]
    let columns: [CatalogColumn]
    let types: [UInt32: DatabaseTypeDescriptor]
    let loadedAt: Date

    static let empty = CatalogSnapshot(
        serverVersionNumber: 0,
        serverVersion: "",
        databaseOID: 0,
        databaseName: "",
        objects: [],
        columns: [],
        types: [:],
        loadedAt: .distantPast
    )
}
