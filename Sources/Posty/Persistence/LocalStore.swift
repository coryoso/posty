import Foundation
@preconcurrency import SQLite3

actor LocalStore {
    private nonisolated(unsafe) var database: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(url: URL? = nil) throws {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let databaseURL: URL
        if let url {
            databaseURL = url
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Posty", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            databaseURL = support.appendingPathComponent("Posty.sqlite3")
        }

        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw LocalStoreError.openFailed
        }
        guard let database else { throw LocalStoreError.openFailed }
        try Self.execute("PRAGMA journal_mode=WAL", in: database)
        try Self.execute("PRAGMA foreign_keys=ON", in: database)
        try Self.migrate(database)
    }

    deinit {
        sqlite3_close(database)
    }

    func loadQueries(connectionID: UUID, databaseName: String) throws -> [QueryDocument] {
        let sql = "SELECT payload FROM saved_queries WHERE connection_id = ? AND database_name = ? ORDER BY updated_at DESC"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(connectionID.uuidString, at: 1, to: statement)
        bind(databaseName, at: 2, to: statement)
        var documents: [QueryDocument] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            documents.append(try decoder.decode(QueryDocument.self, from: data))
        }
        return documents
    }

    func saveQuery(_ query: QueryDocument) throws {
        let payload = try encoder.encode(query)
        let statement = try prepare("""
            INSERT INTO saved_queries(id, connection_id, database_name, payload, updated_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                connection_id = excluded.connection_id,
                database_name = excluded.database_name,
                payload = excluded.payload,
                updated_at = excluded.updated_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(query.id.uuidString, at: 1, to: statement)
        bind(query.connectionID.uuidString, at: 2, to: statement)
        bind(query.database, at: 3, to: statement)
        bind(payload, at: 4, to: statement)
        bind(query.updatedAt.timeIntervalSince1970, at: 5, to: statement)
        try stepDone(statement)
    }

    func deleteQuery(id: UUID) throws {
        let statement = try prepare("DELETE FROM saved_queries WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        try stepDone(statement)
    }

    func addHistory(_ summary: QueryRunSummary) throws {
        let payload = try encoder.encode(summary)
        let statement = try prepare("INSERT INTO query_history(id, connection_id, database_name, payload, started_at) VALUES(?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(summary.id.uuidString, at: 1, to: statement)
        bind(summary.connectionID.uuidString, at: 2, to: statement)
        bind(summary.database, at: 3, to: statement)
        bind(payload, at: 4, to: statement)
        bind(summary.startedAt.timeIntervalSince1970, at: 5, to: statement)
        try stepDone(statement)
    }

    func loadHistory(connectionID: UUID, databaseName: String, limit: Int = 200) throws -> [QueryRunSummary] {
        let statement = try prepare("SELECT payload FROM query_history WHERE connection_id = ? AND database_name = ? ORDER BY started_at DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        bind(connectionID.uuidString, at: 1, to: statement)
        bind(databaseName, at: 2, to: statement)
        sqlite3_bind_int64(statement, 3, Int64(limit))
        var values: [QueryRunSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            values.append(try decoder.decode(QueryRunSummary.self, from: data))
        }
        return values
    }

    func loadMessages(queryID: UUID) throws -> [ChatMessage] {
        let statement = try prepare("SELECT payload FROM chat_messages WHERE query_id = ? ORDER BY created_at")
        defer { sqlite3_finalize(statement) }
        bind(queryID.uuidString, at: 1, to: statement)
        var messages: [ChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            messages.append(try decoder.decode(ChatMessage.self, from: data))
        }
        return messages
    }

    func addMessage(_ message: ChatMessage) throws {
        let payload = try encoder.encode(message)
        let statement = try prepare("INSERT OR REPLACE INTO chat_messages(id, query_id, payload, created_at) VALUES(?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(message.id.uuidString, at: 1, to: statement)
        bind(message.queryID.uuidString, at: 2, to: statement)
        bind(payload, at: 3, to: statement)
        bind(message.createdAt.timeIntervalSince1970, at: 4, to: statement)
        try stepDone(statement)
    }

    func loadFolders(connectionID: UUID, databaseName: String) throws -> [QueryFolder] {
        let statement = try prepare("SELECT payload FROM query_folders WHERE connection_id = ? AND database_name = ? ORDER BY name")
        defer { sqlite3_finalize(statement) }
        bind(connectionID.uuidString, at: 1, to: statement)
        bind(databaseName, at: 2, to: statement)
        var folders: [QueryFolder] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            folders.append(try decoder.decode(QueryFolder.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
        return folders
    }

    func saveFolder(_ folder: QueryFolder) throws {
        let payload = try encoder.encode(folder)
        let statement = try prepare("INSERT OR REPLACE INTO query_folders(id, connection_id, database_name, name, payload) VALUES(?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(folder.id.uuidString, at: 1, to: statement)
        bind(folder.connectionID.uuidString, at: 2, to: statement)
        bind(folder.database, at: 3, to: statement)
        bind(folder.name, at: 4, to: statement)
        bind(payload, at: 5, to: statement)
        try stepDone(statement)
    }

    func saveWorkspace(_ state: WorkspaceRestoration, connectionID: UUID, databaseName: String) throws {
        let payload = try encoder.encode(state)
        let statement = try prepare("INSERT OR REPLACE INTO workspace_state(scope, payload) VALUES(?, ?)")
        defer { sqlite3_finalize(statement) }
        bind("\(connectionID.uuidString):\(databaseName)", at: 1, to: statement)
        bind(payload, at: 2, to: statement)
        try stepDone(statement)
    }

    func loadWorkspace(connectionID: UUID, databaseName: String) throws -> WorkspaceRestoration? {
        let statement = try prepare("SELECT payload FROM workspace_state WHERE scope = ?")
        defer { sqlite3_finalize(statement) }
        bind("\(connectionID.uuidString):\(databaseName)", at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return try decoder.decode(WorkspaceRestoration.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    private nonisolated static func migrate(_ database: OpaquePointer) throws {
        let version = try scalarInt("PRAGMA user_version", in: database)
        if version < 1 {
            try execute("""
                CREATE TABLE IF NOT EXISTS saved_queries(
                    id TEXT PRIMARY KEY,
                    connection_id TEXT NOT NULL,
                    database_name TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
                """, in: database)
            try execute("CREATE INDEX IF NOT EXISTS saved_queries_scope ON saved_queries(connection_id, database_name, updated_at)", in: database)
            try execute("""
                CREATE TABLE IF NOT EXISTS query_history(
                    id TEXT PRIMARY KEY,
                    connection_id TEXT NOT NULL,
                    database_name TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    started_at REAL NOT NULL
                )
                """, in: database)
            try execute("CREATE INDEX IF NOT EXISTS query_history_scope ON query_history(connection_id, database_name, started_at)", in: database)
            try execute("""
                CREATE TABLE IF NOT EXISTS chat_messages(
                    id TEXT PRIMARY KEY,
                    query_id TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    created_at REAL NOT NULL
                )
                """, in: database)
            try execute("CREATE INDEX IF NOT EXISTS chat_messages_query ON chat_messages(query_id, created_at)", in: database)
            try execute("PRAGMA user_version=1", in: database)
        }
        if version < 2 {
            try execute("""
                CREATE TABLE IF NOT EXISTS query_folders(
                    id TEXT PRIMARY KEY,
                    connection_id TEXT NOT NULL,
                    database_name TEXT NOT NULL,
                    name TEXT NOT NULL,
                    payload BLOB NOT NULL
                )
                """, in: database)
            try execute("CREATE INDEX IF NOT EXISTS query_folders_scope ON query_folders(connection_id, database_name, name)", in: database)
            try execute("""
                CREATE TABLE IF NOT EXISTS workspace_state(
                    scope TEXT PRIMARY KEY,
                    payload BLOB NOT NULL
                )
                """, in: database)
            try execute("PRAGMA user_version=2", in: database)
        }
    }

    private nonisolated static func execute(_ sql: String, in database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error)
            throw LocalStoreError.sqlite(message)
        }
    }

    private nonisolated static func scalarInt(_ sql: String, in database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LocalStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalStoreError.sqlite(lastError)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalStoreError.sqlite(lastError) }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_double(statement, index, value)
    }

    private var lastError: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite database is unavailable"
    }
}

enum LocalStoreError: LocalizedError {
    case openFailed
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: "Unable to open Posty's local database."
        case .sqlite(let message): message
        }
    }
}
