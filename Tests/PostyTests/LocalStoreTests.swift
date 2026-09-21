import Foundation
import Testing
@testable import Posty

struct LocalStoreTests {
    @Test func migratesAndPersistsQueryMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("test.sqlite3"))
        let connectionID = UUID()
        let query = QueryDocument(connectionID: connectionID, database: "postgres", name: "People", sql: "SELECT * FROM people")
        try await store.saveQuery(query)
        let storedQueries = try await store.loadQueries(connectionID: connectionID, databaseName: "postgres")
        #expect(storedQueries.count == 1)
        #expect(storedQueries.first?.id == query.id)
        #expect(storedQueries.first?.sql == query.sql)

        let folder = QueryFolder(connectionID: connectionID, database: "postgres", name: "Reporting")
        try await store.saveFolder(folder)
        #expect(try await store.loadFolders(connectionID: connectionID, databaseName: "postgres") == [folder])

        let restoration = WorkspaceRestoration(
            tabs: [.init(kind: .query, contentID: query.id.uuidString)],
            selectedContentID: query.id.uuidString
        )
        try await store.saveWorkspace(restoration, connectionID: connectionID, databaseName: "postgres")
        #expect(try await store.loadWorkspace(connectionID: connectionID, databaseName: "postgres") == restoration)

        let history = QueryRunSummary(
            id: UUID(), connectionID: connectionID, database: "postgres", sql: query.sql,
            startedAt: .now, durationMilliseconds: 12, rowCount: 4, status: .succeeded, error: nil
        )
        try await store.addHistory(history)
        let loaded = try await store.loadHistory(connectionID: connectionID, databaseName: "postgres")
        #expect(loaded.first?.sql == query.sql)
        #expect(loaded.first?.rowCount == 4)
    }
}
