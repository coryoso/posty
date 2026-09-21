import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var profiles: [ConnectionProfile] = []
    var errorMessage: String?
    var codexAvailable = false
    var codexStatus = "Not checked"

    let keychain = KeychainConnectionStore.shared
    let localStore: LocalStore?
    let codex = CodexBridge()

    init() {
        localStore = ProcessInfo.processInfo.environment["POSTY_TESTING"] == "1" ? nil : try? LocalStore()
        reloadProfiles()
    }

    func reloadProfiles() {
        do { profiles = try keychain.loadAll() }
        catch { errorMessage = error.localizedDescription }
    }

    func save(_ profile: ConnectionProfile) throws {
        try keychain.save(profile)
        reloadProfiles()
    }

    func delete(_ profile: ConnectionProfile) throws {
        try keychain.delete(id: profile.id)
        reloadProfiles()
    }

    func checkCodex() async {
        codexStatus = "Checking…"
        do {
            try await codex.start()
            codexAvailable = true
            codexStatus = "Azure · Luna · Terra"
        } catch {
            codexAvailable = false
            codexStatus = error.localizedDescription
        }
    }
}

