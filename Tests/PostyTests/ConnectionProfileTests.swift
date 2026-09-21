import Foundation
import Testing
@testable import Posty

struct ConnectionProfileTests {
    @Test func importsPostgresURL() throws {
        let profile = try ConnectionProfile.fromPostgresURL(#require(URL(string: "postgresql://alice:p%40ss@db.example.com:5444/app?sslmode=verify-full")))
        #expect(profile.host == "db.example.com")
        #expect(profile.port == 5444)
        #expect(profile.database == "app")
        #expect(profile.username == "alice")
        #expect(profile.password == "p@ss")
        #expect(profile.tlsMode == .verifyFull)
    }

    @Test func persistsRecentConnectionMetadata() throws {
        let connectedAt = Date(timeIntervalSince1970: 1_787_830_000)
        let profile = ConnectionProfile(name: "Production", colorName: "purple", lastConnectedAt: connectedAt)
        let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        #expect(restored.name == "Production")
        #expect(restored.colorName == "purple")
        #expect(restored.lastConnectedAt == connectedAt)
    }
}
