import Foundation
import Security
import Testing
@testable import Posty

struct KeychainConnectionStoreTests {
    @Test func newCredentialsTrustTheAppAndSSHHelperAndSurviveUpdates() throws {
        let prefix = "com.corneliuscarl.Posty.tests.\(UUID().uuidString)"
        let store = KeychainConnectionStore(servicePrefix: prefix)
        var profile = ConnectionProfile(name: "Keychain regression test")
        defer { try? store.delete(id: profile.id) }
        #expect(Bundle.main.path(forAuxiliaryExecutable: "PostySSHAskPass") != nil)

        for password in ["first-test-password", "updated-test-password"] {
            profile.password = password
            profile.ssh.password = password
            try store.save(profile)
            #expect(try store.loadAll().first?.password == password)

            for (suffix, trustedCount) in [("connections", 1), ("ssh-password", 2), ("ssh-passphrase", 2)] {
                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: "\(prefix).\(suffix)",
                    kSecAttrAccount: profile.id.uuidString,
                    kSecReturnRef: true
                ]
                var result: CFTypeRef?
                #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
                let item = try #require(result) as! SecKeychainItem
                var access: SecAccess?
                #expect(SecKeychainItemCopyAccess(item, &access) == errSecSuccess)
                let decryptACLs = SecAccessCopyMatchingACLList(try #require(access), kSecACLAuthorizationDecrypt) as! [SecACL]
                #expect(!decryptACLs.isEmpty)
                for acl in decryptACLs {
                    var applications: CFArray?
                    var description: CFString?
                    var flags = SecKeychainPromptSelector()
                    #expect(SecACLCopyContents(acl, &applications, &description, &flags) == errSecSuccess)
                    #expect((applications as? [SecTrustedApplication])?.count == trustedCount)
                }
            }
        }
    }
}
