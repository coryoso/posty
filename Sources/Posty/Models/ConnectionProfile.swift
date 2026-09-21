import Foundation

struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    enum TLSMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case disable
        case prefer
        case require
        case verifyCA = "verify-ca"
        case verifyFull = "verify-full"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .disable: "Disable"
            case .prefer: "Prefer"
            case .require: "Require"
            case .verifyCA: "Verify CA"
            case .verifyFull: "Verify Full"
            }
        }
    }

    enum SSHAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
        case agent
        case privateKey
        case password
        case openSSHConfig

        var id: String { rawValue }
        var title: String {
            switch self {
            case .agent: "SSH Agent"
            case .privateKey: "Private Key"
            case .password: "Password"
            case .openSSHConfig: "OpenSSH Config"
            }
        }
    }

    struct SSHConfiguration: Codable, Hashable, Sendable {
        var enabled = false
        var host = ""
        var port = 22
        var username = ""
        var authentication: SSHAuthentication = .agent
        var privateKeyPath = ""
        var password = ""
        var privateKeyPassphrase = ""
        var proxyJump = ""
        var configHostAlias = ""
    }

    var id: UUID
    var name: String
    var colorName: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var password: String
    var tlsMode: TLSMode
    var serverCAPath: String
    var clientCertificatePath: String
    var clientKeyPath: String
    var ssh: SSHConfiguration
    var connectTimeoutSeconds: Int
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String = "New Connection",
        colorName: String = "blue",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "postgres",
        username: String = NSUserName(),
        password: String = "",
        tlsMode: TLSMode = .prefer,
        serverCAPath: String = "",
        clientCertificatePath: String = "",
        clientKeyPath: String = "",
        ssh: SSHConfiguration = .init(),
        connectTimeoutSeconds: Int = 10,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.tlsMode = tlsMode
        self.serverCAPath = serverCAPath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
        self.ssh = ssh
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.lastConnectedAt = lastConnectedAt
    }

    var endpointDescription: String {
        "\(host):\(port)/\(database)"
    }

    static func fromPostgresURL(_ url: URL) throws -> ConnectionProfile {
        guard let scheme = url.scheme?.lowercased(), scheme == "postgres" || scheme == "postgresql" else {
            throw ConnectionProfileError.invalidURL
        }
        guard let host = url.host, !host.isEmpty else { throw ConnectionProfileError.invalidURL }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let database = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sslMode = components?.queryItems?.first(where: { $0.name == "sslmode" })?.value
        return ConnectionProfile(
            name: database.isEmpty ? host : "\(host) — \(database)",
            host: host,
            port: url.port ?? 5432,
            database: database.isEmpty ? "postgres" : database,
            username: url.user?.removingPercentEncoding ?? NSUserName(),
            password: url.password?.removingPercentEncoding ?? "",
            tlsMode: TLSMode(rawValue: sslMode ?? "prefer") ?? .prefer
        )
    }
}

enum ConnectionProfileError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        "Enter a valid postgres:// or postgresql:// URL containing a host."
    }
}
