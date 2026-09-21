import Foundation
import NIOSSL
import PostgresNIO

actor DatabaseSession {
    private let profile: ConnectionProfile
    private var tunnel: SSHTunnel?
    private var client: PostgresClient?
    private var clientTask: Task<Void, Never>?
    private(set) var catalog: CatalogSnapshot = .empty

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    func connect() async throws -> CatalogSnapshot {
        if client != nil { return catalog }
        let endpoint: SSHTunnel.Endpoint
        if profile.ssh.enabled {
            let tunnel = try SSHTunnel(profile: profile)
            self.tunnel = tunnel
            endpoint = try await tunnel.start()
        } else {
            endpoint = .init(host: profile.host, port: profile.port)
        }

        var configuration = PostgresClient.Configuration(
            host: endpoint.host,
            port: endpoint.port,
            username: profile.username,
            password: profile.password.isEmpty ? nil : profile.password,
            database: profile.database,
            tls: try tlsConfiguration()
        )
        configuration.options.connectTimeout = .seconds(profile.connectTimeoutSeconds)
        configuration.options.maximumConnections = 6
        configuration.options.minimumConnections = 1
        configuration.options.tlsServerName = profile.tlsMode == .verifyFull ? profile.host : nil
        configuration.options.additionalStartupParameters = [("application_name", "Posty")]

        let client = PostgresClient(configuration: configuration)
        self.client = client
        clientTask = Task { await client.run() }
        do {
            catalog = try await CatalogLoader.load(using: client)
            return catalog
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        clientTask?.cancel()
        clientTask = nil
        client = nil
        tunnel?.stop()
        tunnel = nil
        catalog = .empty
    }

    func refreshCatalog() async throws -> CatalogSnapshot {
        guard let client else { throw DatabaseSessionError.notConnected }
        catalog = try await CatalogLoader.load(using: client)
        return catalog
    }

    func listDatabases() async throws -> [String] {
        guard let client else { throw DatabaseSessionError.notConnected }
        let rows = try await client.query("""
            SELECT datname
            FROM pg_database
            WHERE datallowconn AND NOT datistemplate AND has_database_privilege(datname, 'CONNECT')
            ORDER BY datname
            """).collect()
        return rows.compactMap { try? $0.makeRandomAccess()["datname"].decode(String.self) }
    }

    func relationDetails(for object: CatalogObject) async throws -> RelationDetails {
        guard let client else { throw DatabaseSessionError.notConnected }
        return try await CatalogLoader.relationDetails(for: object, using: client, types: catalog.types)
    }

    func definition(for object: CatalogObject) async throws -> String {
        guard let client else { throw DatabaseSessionError.notConnected }
        return try await CatalogLoader.definition(for: object, using: client)
    }

    func execute(_ sql: String, limit: Int = 10_000) async throws -> QueryResultSet {
        guard let client else { throw DatabaseSessionError.notConnected }
        let clock = ContinuousClock()
        let start = clock.now
        let sequence = try await client.query(PostgresQuery(unsafeSQL: sql))
        var columns: [ResultColumn] = []
        var rows: [ResultRow] = []
        var truncated = false
        for try await row in sequence {
            if columns.isEmpty {
                columns = row.map { cell in
                    let oid = UInt32(cell.dataType.rawValue)
                    return ResultColumn(
                        name: cell.columnName,
                        typeOID: oid,
                        typeName: catalog.types[oid]?.qualifiedName ?? "oid:\(oid)",
                        enumValues: catalog.types[oid]?.enumValues ?? []
                    )
                }
            }
            guard rows.count < limit else { truncated = true; break }
            rows.append(ResultRow(values: row.map { DatabaseValueDecoder.decode($0, types: catalog.types) }))
        }
        return QueryResultSet(columns: columns, rows: rows, commandTag: rows.isEmpty ? "OK" : "\(rows.count) rows", duration: start.duration(to: clock.now), wasTruncated: truncated)
    }

    func fetchTable(
        _ details: RelationDetails,
        filter: FilterExpression?,
        orderBy: (column: String, ascending: Bool)?,
        page: Int,
        pageSize: Int = 500
    ) async throws -> QueryResultSet {
        guard let client else { throw DatabaseSessionError.notConnected }
        let allowed = Set(details.columns.map(\.name))
        let compilation = try filter?.compile(allowedColumns: allowed)
        var binds = PostgresBindings(capacity: compilation?.values.count ?? 0)
        compilation?.values.forEach { binds.append($0) }
        let selectedColumns = details.columns.map { SQLIdentifier.quote($0.name) }.joined(separator: ", ")
        let editable = !details.stableKeyColumns.isEmpty && [.table, .partitionedTable].contains(details.object.kind)
        let hiddenXmin = editable ? ", xmin::text AS \"__posty_xmin\"" : ""
        var sql = "SELECT \(selectedColumns)\(hiddenXmin) FROM \(details.object.qualifiedName)"
        if let whereSQL = compilation?.sql { sql += " WHERE \(whereSQL)" }
        if let orderBy, allowed.contains(orderBy.column) {
            sql += " ORDER BY \(SQLIdentifier.quote(orderBy.column)) \(orderBy.ascending ? "ASC" : "DESC")"
        } else if let key = details.stableKeyColumns.first {
            sql += " ORDER BY \(SQLIdentifier.quote(key.name))"
        }
        sql += " LIMIT \(pageSize) OFFSET \(max(0, page) * pageSize)"

        let clock = ContinuousClock()
        let start = clock.now
        let sequence = try await client.query(PostgresQuery(unsafeSQL: sql, binds: binds))
        var rows: [ResultRow] = []
        for try await row in sequence {
            var values: [DatabaseValue] = []
            var xmin: String?
            for cell in row {
                if cell.columnName == "__posty_xmin" { xmin = try? cell.decode(String.self) }
                else { values.append(DatabaseValueDecoder.decode(cell, types: catalog.types)) }
            }
            rows.append(ResultRow(values: values, xmin: xmin))
        }
        let columns = details.columns.map {
            ResultColumn(name: $0.name, typeOID: $0.typeOID, typeName: $0.formattedType, enumValues: $0.enumValues)
        }
        return QueryResultSet(columns: columns, rows: rows, commandTag: "Page \(page + 1)", duration: start.duration(to: clock.now), wasTruncated: rows.count == pageSize)
    }

    func saveMutations(_ mutations: [PendingRowMutation], for details: RelationDetails) async throws {
        guard let client else { throw DatabaseSessionError.notConnected }
        guard !mutations.isEmpty else { return }
        let columnMap = Dictionary(uniqueKeysWithValues: details.columns.map { ($0.name, $0) })
        let keyColumns = details.stableKeyColumns
        guard !keyColumns.isEmpty else { throw DatabaseSessionError.relationHasNoStableKey }

        try await client.withTransaction(logger: Logger(label: "Posty.Mutations")) { connection in
            for mutation in mutations {
                let query = try mutationQuery(mutation, relation: details.object, columns: columnMap, keyColumns: keyColumns)
                let sequence: PostgresRowSequence = try await connection.query(query, logger: Logger(label: "Posty.Mutations"))
                var returnedRow = false
                for try await _ in sequence { returnedRow = true }
                if mutation.kind != .insert, !returnedRow { throw DatabaseSessionError.concurrentMutation }
            }
        }
    }

    func suggestedValues(column: CatalogColumn, relation: CatalogObject, prefix: String) async throws -> [String] {
        guard let client else { throw DatabaseSessionError.notConnected }
        return try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                var binds = PostgresBindings(capacity: 1)
                binds.append(prefix + "%")
                let sql = """
                    SELECT DISTINCT \(SQLIdentifier.quote(column.name))::text AS value
                    FROM \(relation.qualifiedName)
                    WHERE \(SQLIdentifier.quote(column.name)) IS NOT NULL
                      AND \(SQLIdentifier.quote(column.name))::text ILIKE $1
                    ORDER BY value LIMIT 50
                    """
                let rows = try await client.query(PostgresQuery(unsafeSQL: sql, binds: binds)).collect()
                return rows.compactMap { try? $0.makeRandomAccess()["value"].decode(String.self) }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw DatabaseSessionError.valueLookupTimedOut
            }
            guard let first = try await group.next() else { return [] }
            group.cancelAll()
            return first
        }
    }

    private func mutationQuery(
        _ mutation: PendingRowMutation,
        relation: CatalogObject,
        columns: [String: CatalogColumn],
        keyColumns: [CatalogColumn]
    ) throws -> PostgresQuery {
        var binds = PostgresBindings()
        func placeholder(_ value: DatabaseValue, column: CatalogColumn, binds: inout PostgresBindings) -> String {
            if value.isNull {
                binds.appendNull()
            } else {
                binds.append(value.postgresText)
            }
            return "$\(binds.count)::\(column.formattedType)"
        }

        switch mutation.kind {
        case .insert:
            let writable = mutation.changedValues.keys.sorted().compactMap { name -> (CatalogColumn, DatabaseValue)? in
                guard let column = columns[name], column.generated == nil, column.identity != "a", let value = mutation.changedValues[name] else { return nil }
                return (column, value)
            }
            guard !writable.isEmpty else { return PostgresQuery(unsafeSQL: "INSERT INTO \(relation.qualifiedName) DEFAULT VALUES RETURNING xmin::text") }
            let names = writable.map { SQLIdentifier.quote($0.0.name) }.joined(separator: ", ")
            let values = writable.map { placeholder($0.1, column: $0.0, binds: &binds) }.joined(separator: ", ")
            return PostgresQuery(unsafeSQL: "INSERT INTO \(relation.qualifiedName) (\(names)) VALUES (\(values)) RETURNING xmin::text", binds: binds)
        case .update:
            let changed = mutation.changedValues.keys.sorted().compactMap { name -> (CatalogColumn, DatabaseValue)? in
                guard let column = columns[name], let value = mutation.changedValues[name] else { return nil }
                return (column, value)
            }
            guard !changed.isEmpty else { throw DatabaseSessionError.emptyMutation }
            let assignments = changed.map { "\(SQLIdentifier.quote($0.0.name)) = \(placeholder($0.1, column: $0.0, binds: &binds))" }.joined(separator: ", ")
            let predicate = try keyPredicate(mutation, keyColumns: keyColumns, binds: &binds)
            let xmin = mutation.xmin.map { value -> String in binds.append(value); return " AND xmin = $\(binds.count)::xid" } ?? ""
            return PostgresQuery(unsafeSQL: "UPDATE \(relation.qualifiedName) SET \(assignments) WHERE \(predicate)\(xmin) RETURNING xmin::text", binds: binds)
        case .delete:
            let predicate = try keyPredicate(mutation, keyColumns: keyColumns, binds: &binds)
            let xmin = mutation.xmin.map { value -> String in binds.append(value); return " AND xmin = $\(binds.count)::xid" } ?? ""
            return PostgresQuery(unsafeSQL: "DELETE FROM \(relation.qualifiedName) WHERE \(predicate)\(xmin) RETURNING xmin::text", binds: binds)
        }
    }

    private func keyPredicate(_ mutation: PendingRowMutation, keyColumns: [CatalogColumn], binds: inout PostgresBindings) throws -> String {
        try keyColumns.map { column in
            guard let value = mutation.keyValues[column.name] else { throw DatabaseSessionError.missingKeyValue(column.name) }
            if value.isNull { return "\(SQLIdentifier.quote(column.name)) IS NULL" }
            binds.append(value.postgresText)
            return "\(SQLIdentifier.quote(column.name)) = $\(binds.count)::\(column.formattedType)"
        }.joined(separator: " AND ")
    }

    private func tlsConfiguration() throws -> PostgresClient.Configuration.TLS {
        guard profile.tlsMode != .disable else { return .disable }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = [.verifyCA, .verifyFull].contains(profile.tlsMode) ? .fullVerification : .none
        if !profile.serverCAPath.isEmpty { configuration.trustRoots = .file(profile.serverCAPath) }
        if !profile.clientCertificatePath.isEmpty {
            configuration.certificateChain = try NIOSSLCertificate.fromPEMFile(profile.clientCertificatePath).map { .certificate($0) }
        }
        if !profile.clientKeyPath.isEmpty {
            configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: profile.clientKeyPath, format: .pem))
        }
        return profile.tlsMode == .prefer ? .prefer(configuration) : .require(configuration)
    }
}

enum DatabaseSessionError: LocalizedError {
    case notConnected
    case catalogUnavailable
    case unsupportedServerVersion(Int)
    case relationHasNoStableKey
    case concurrentMutation
    case emptyMutation
    case missingKeyValue(String)
    case valueLookupTimedOut

    var errorDescription: String? {
        switch self {
        case .notConnected: "The database is not connected."
        case .catalogUnavailable: "PostgreSQL did not return database catalog information."
        case .unsupportedServerVersion(let version): "PostgreSQL server version \(version) is unsupported. Posty supports versions 14 through 18."
        case .relationHasNoStableKey: "This relation has no primary key and cannot be edited safely."
        case .concurrentMutation: "A row changed after it was loaded. No staged changes were saved."
        case .emptyMutation: "There are no changed values to save."
        case .missingKeyValue(let column): "The row is missing key value \(column)."
        case .valueLookupTimedOut: "Value suggestions took longer than two seconds."
        }
    }
}
