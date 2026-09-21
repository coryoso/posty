import Foundation
import Security

let environment = ProcessInfo.processInfo.environment
guard let connectionID = environment["POSTY_CONNECTION_ID"] else {
    exit(1)
}

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
let service = prompt.contains("passphrase")
    ? "com.corneliuscarl.Posty.ssh-passphrase"
    : "com.corneliuscarl.Posty.ssh-password"

let query: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: service,
    kSecAttrAccount: connectionID,
    kSecReturnData: true,
    kSecMatchLimit: kSecMatchLimitOne
]
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let secret = String(data: data, encoding: .utf8),
      !secret.isEmpty else {
    exit(1)
}

FileHandle.standardOutput.write(Data((secret + "\n").utf8))
