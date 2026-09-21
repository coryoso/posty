import Foundation

struct QueryDocument: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var connectionID: UUID
    var database: String
    var name: String
    var sql: String
    var updatedAt: Date
    var chartSpecs: [ChartSpec]
    var folderID: UUID?

    init(
        id: UUID = UUID(),
        connectionID: UUID,
        database: String,
        name: String = "Untitled Query",
        sql: String = "SELECT *\nFROM ",
        updatedAt: Date = .now,
        chartSpecs: [ChartSpec] = [],
        folderID: UUID? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.database = database
        self.name = name
        self.sql = sql
        self.updatedAt = updatedAt
        self.chartSpecs = chartSpecs
        self.folderID = folderID
    }
}

struct QueryFolder: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var connectionID: UUID
    var database: String
    var name: String
    var parentID: UUID?

    init(id: UUID = UUID(), connectionID: UUID, database: String, name: String, parentID: UUID? = nil) {
        self.id = id
        self.connectionID = connectionID
        self.database = database
        self.name = name
        self.parentID = parentID
    }
}

struct WorkspaceRestoration: Hashable, Sendable, Codable {
    struct Tab: Hashable, Sendable, Codable {
        enum Kind: String, Sendable, Codable { case query, relation }
        var kind: Kind
        var contentID: String
    }

    var tabs: [Tab]
    var selectedContentID: String?
}

struct QueryRunSummary: Identifiable, Hashable, Sendable, Codable {
    enum Status: String, Codable, Sendable { case succeeded, failed, cancelled }

    var id: UUID
    var connectionID: UUID
    var database: String
    var sql: String
    var startedAt: Date
    var durationMilliseconds: Int
    var rowCount: Int
    var status: Status
    var error: String?
}

struct ChatMessage: Identifiable, Hashable, Sendable, Codable {
    enum Role: String, Codable, Sendable { case user, assistant }

    var id: UUID
    var queryID: UUID
    var role: Role
    var text: String
    var createdAt: Date
}

struct SQLProposal: Hashable, Sendable, Codable {
    var message: String
    var sql: String
    var destructive: Bool
    var assumptions: [String]
}

struct ChartSpec: Identifiable, Hashable, Sendable, Codable {
    enum Mark: String, Codable, CaseIterable, Identifiable, Sendable {
        case bar, line, area, scatter
        var id: String { rawValue }
    }

    var id: UUID
    var title: String
    var mark: Mark
    var xColumn: String
    var yColumn: String
    var seriesColumn: String?

    init(id: UUID = UUID(), title: String, mark: Mark, xColumn: String, yColumn: String, seriesColumn: String? = nil) {
        self.id = id
        self.title = title
        self.mark = mark
        self.xColumn = xColumn
        self.yColumn = yColumn
        self.seriesColumn = seriesColumn
    }
}

enum RowMutationKind: String, Codable, Sendable { case insert, update, delete }

struct PendingRowMutation: Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: RowMutationKind
    var originalRowID: UUID?
    var keyValues: [String: DatabaseValue]
    var changedValues: [String: DatabaseValue]
    var xmin: String?
}
