import Foundation
import Security

final class KeychainConnectionStore: @unchecked Sendable {
    static let shared = KeychainConnectionStore(servicePrefix:
        ProcessInfo.processInfo.environment["POSTY_TESTING"] == "1"
            ? "com.corneliuscarl.Posty.tests.\(UUID().uuidString)"
            : "com.corneliuscarl.Posty"
    )

    private let profileService: String
    private let sshPasswordService: String
    private let sshPassphraseService: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(servicePrefix: String = "com.corneliuscarl.Posty") {
        profileService = "\(servicePrefix).connections"
        sshPasswordService = "\(servicePrefix).ssh-password"
        sshPassphraseService = "\(servicePrefix).ssh-passphrase"
    }

    func loadAll() throws -> [ConnectionProfile] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: profileService,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        let attributes: [[String: Any]]
        if let match = result as? [String: Any] {
            attributes = [match]
        } else {
            attributes = result as? [[String: Any]] ?? []
        }
        // On macOS, asking Security for all matching generic-password data can
        // fail with errSecParam. Enumerate account attributes, then fetch each
        // payload individually with kSecMatchLimitOne.
        var profilesByID: [UUID: ConnectionProfile] = [:]
        for attributes in attributes {
            guard let account = attributes[kSecAttrAccount as String] as? String else { continue }
            guard let value = try? data(service: profileService, account: account),
                  let profile = try? decoder.decode(ConnectionProfile.self, from: value) else { continue }
            profilesByID[profile.id] = profile
        }
        return Array(profilesByID.values)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ profile: ConnectionProfile) throws {
        try saveShared(profile)
    }

    private func saveShared(_ profile: ConnectionProfile) throws {
        let data = try encoder.encode(profile)
        try upsert(service: profileService, account: profile.id.uuidString, data: data)
        try upsert(service: sshPasswordService, account: profile.id.uuidString, data: Data(profile.ssh.password.utf8))
        try upsert(service: sshPassphraseService, account: profile.id.uuidString, data: Data(profile.ssh.privateKeyPassphrase.utf8))
    }

    func delete(id: UUID) throws {
        for service in [profileService, sshPasswordService, sshPassphraseService] {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: id.uuidString
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.status(status)
            }
        }
    }

    private func upsert(service: String, account: String, data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        // Preserve the existing ACL, including the user's “Always Allow” decisions.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }

        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccess] = try trustedAccess(includeHelper: service != profileService)
        insert[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw KeychainError.status(insertStatus) }
    }

    private func data(service: String, account: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.status(status)
        }
        return data
    }

    private func trustedAccess(includeHelper: Bool) throws -> SecAccess? {
        var applications: [SecTrustedApplication] = []

        var mainApplication: SecTrustedApplication?
        let mainStatus = SecTrustedApplicationCreateFromPath(nil, &mainApplication)
        guard mainStatus == errSecSuccess else { throw KeychainError.status(mainStatus) }
        if let mainApplication { applications.append(mainApplication) }

        if includeHelper, let helperPath = Bundle.main.path(forAuxiliaryExecutable: "PostySSHAskPass")
            ?? Bundle.main.path(forResource: "PostySSHAskPass", ofType: nil) {
            var helperApplication: SecTrustedApplication?
            let helperStatus = SecTrustedApplicationCreateFromPath(helperPath, &helperApplication)
            guard helperStatus == errSecSuccess else { throw KeychainError.status(helperStatus) }
            if let helperApplication { applications.append(helperApplication) }
        }

        var access: SecAccess?
        let status = SecAccessCreate("Posty database credentials" as CFString, applications as CFArray, &access)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return access
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}
