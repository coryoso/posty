import Foundation
import Testing
@testable import Posty

struct DatabaseIntegrationTests {
    @Test func catalogTypesPagingAndMutationAgainstPostgres() async throws {
        guard let rawPort = ProcessInfo.processInfo.environment["POSTY_TEST_POSTGRES_PORT"],
              let port = Int(rawPort) else { return }

        let profile = ConnectionProfile(
            name: "Integration",
            host: "localhost",
            port: port,
            database: "postgres",
            username: "postgres",
            tlsMode: .disable
        )
        let session = DatabaseSession(profile: profile)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let table = "posty_test_\(suffix)"
        let enumName = "posty_status_\(suffix)"
        let domainName = "posty_code_\(suffix)"
        let qualified = SQLIdentifier.qualified("public", table)
        let qualifiedEnum = SQLIdentifier.qualified("public", enumName)
        let qualifiedDomain = SQLIdentifier.qualified("public", domainName)
        do {
            let catalog = try await session.connect()
            #expect((140000..<190000).contains(catalog.serverVersionNumber))
            _ = try await session.execute("CREATE TYPE \(qualifiedEnum) AS ENUM ('ready', 'done')")
            _ = try await session.execute("CREATE DOMAIN \(qualifiedDomain) AS text CHECK (VALUE <> '')")
            _ = try await session.execute("CREATE TABLE \(qualified) (id bigint PRIMARY KEY, active boolean NOT NULL, payload jsonb, status \(qualifiedEnum), tags text[], code \(qualifiedDomain), created_at timestamptz DEFAULT now())")
            _ = try await session.execute("INSERT INTO \(qualified) (id, active, payload, status, tags, code) VALUES (1, true, '{\"name\":\"Posty\"}', 'ready', ARRAY['swift', 'postgres'], 'PST')")
            let refreshed = try await session.refreshCatalog()
            let object = try #require(refreshed.objects.first { $0.schema == "public" && $0.name == table })
            let details = try await session.relationDetails(for: object)
            #expect(details.stableKeyColumns.map(\.name) == ["id"])
            #expect(details.canInsert && details.canUpdate && details.canDelete)
            let page = try await session.fetchTable(details, filter: nil, orderBy: nil, page: 0)
            #expect(page.rows.count == 1)
            #expect(page.rows[0].values.contains(.boolean(true)))
            #expect(page.rows[0].values.contains(.json("{\"name\": \"Posty\"}")) || page.rows[0].values.contains(.json("{\"name\":\"Posty\"}")))
            #expect(page.rows[0].values.contains(.enumeration("ready")))
            #expect(page.rows[0].values.contains(.array([.string("swift"), .string("postgres")])))
            #expect(page.rows[0].values.contains(.string("PST")))

            let original = page.rows[0]
            try await session.saveMutations([
                PendingRowMutation(
                    kind: .update,
                    originalRowID: original.id,
                    keyValues: ["id": .integer(1)],
                    changedValues: ["active": .boolean(false)],
                    xmin: original.xmin
                )
            ], for: details)
            let updatedPage = try await session.fetchTable(details, filter: nil, orderBy: nil, page: 0)
            #expect(updatedPage.rows[0].values.contains(.boolean(false)))

            let stale = try #require(updatedPage.rows.first)
            _ = try await session.execute("UPDATE \(qualified) SET payload = '{\"name\":\"changed elsewhere\"}' WHERE id = 1")
            do {
                try await session.saveMutations([
                    PendingRowMutation(
                        kind: .update,
                        originalRowID: stale.id,
                        keyValues: ["id": .integer(1)],
                        changedValues: ["active": .boolean(true)],
                        xmin: stale.xmin
                    )
                ], for: details)
                Issue.record("Expected optimistic concurrency detection")
            } catch DatabaseSessionError.concurrentMutation {
                // Expected: the entire transaction is rolled back.
            }

            let current = try await session.fetchTable(details, filter: nil, orderBy: nil, page: 0)
            let row = try #require(current.rows.first)
            try await session.saveMutations([
                PendingRowMutation(
                    kind: .delete,
                    originalRowID: row.id,
                    keyValues: ["id": .integer(1)],
                    changedValues: [:],
                    xmin: row.xmin
                )
            ], for: details)
            #expect(try await session.fetchTable(details, filter: nil, orderBy: nil, page: 0).rows.isEmpty)

            _ = try await session.execute("DROP TABLE \(qualified)")
            _ = try await session.execute("DROP TYPE \(qualifiedEnum)")
            _ = try await session.execute("DROP DOMAIN \(qualifiedDomain)")
            await session.disconnect()
        } catch {
            _ = try? await session.execute("DROP TABLE IF EXISTS \(qualified)")
            _ = try? await session.execute("DROP TYPE IF EXISTS \(qualifiedEnum)")
            _ = try? await session.execute("DROP DOMAIN IF EXISTS \(qualifiedDomain)")
            await session.disconnect()
            throw error
        }
    }
}
