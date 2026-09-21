import Darwin
import Foundation

final class SSHTunnel: @unchecked Sendable {
    struct Endpoint: Sendable {
        let host: String
        let port: Int
    }

    private(set) var process: Process?
    private(set) var localPort: Int?
    private let profile: ConnectionProfile
    private let knownHostsURL: URL

    init(profile: ConnectionProfile) throws {
        self.profile = profile
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Posty/SSH", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        knownHostsURL = support.appendingPathComponent("known_hosts")
        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            _ = FileManager.default.createFile(atPath: knownHostsURL.path, contents: Data())
        }
    }

    func inspectHostKey() async throws -> SSHHostKeyStatus {
        let ssh = profile.ssh
        let scan = try await Self.run(
            executable: "/usr/bin/ssh-keyscan",
            arguments: ["-T", "5", "-p", String(ssh.port), ssh.host],
            input: nil
        )
        guard scan.status == 0,
              let keyLine = scan.output.split(separator: "\n").first(where: { !$0.hasPrefix("#") }).map(String.init) else {
            throw SSHTunnelError.hostScanFailed(scan.error)
        }
        let fingerprint = try await Self.fingerprint(for: keyLine)
        let existing = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
        let hostToken = ssh.port == 22 ? ssh.host : "[\(ssh.host)]:\(ssh.port)"
        let lines = existing.split(separator: "\n").map(String.init)
        let matchingLines = lines.filter { line in
            let firstField = line.split(separator: " ").first
            return firstField == Substring(hostToken)
        }
        if matchingLines.isEmpty {
            return .unknown(host: hostToken, fingerprint: fingerprint, keyLine: Self.normalized(keyLine, hostToken: hostToken))
        }
        let normalized = Self.normalized(keyLine, hostToken: hostToken)
        if matchingLines.contains(normalized) { return .trusted(fingerprint: fingerprint) }
        return .changed(host: hostToken, fingerprint: fingerprint)
    }

    func trust(_ keyLine: String) throws {
        var contents = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
        if !contents.isEmpty, !contents.hasSuffix("\n") { contents.append("\n") }
        contents.append(keyLine)
        contents.append("\n")
        try contents.write(to: knownHostsURL, atomically: true, encoding: .utf8)
    }

    func start() async throws -> Endpoint {
        guard profile.ssh.enabled else { return Endpoint(host: profile.host, port: profile.port) }
        switch try await inspectHostKey() {
        case .trusted: break
        case .unknown(let host, let fingerprint, let keyLine):
            throw SSHTunnelError.hostKeyApprovalRequired(host: host, fingerprint: fingerprint, keyLine: keyLine)
        case .changed(let host, let fingerprint):
            throw SSHTunnelError.hostKeyChanged(host: host, fingerprint: fingerprint)
        }

        let port = try Self.availableLoopbackPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-L", "127.0.0.1:\(port):\(profile.host):\(profile.port)"
        ]
        let ssh = profile.ssh
        if !ssh.proxyJump.isEmpty { arguments += ["-J", ssh.proxyJump] }
        switch ssh.authentication {
        case .agent:
            arguments += ["-o", "BatchMode=yes"]
        case .privateKey:
            if !ssh.privateKeyPath.isEmpty { arguments += ["-i", ssh.privateKeyPath] }
            arguments += ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"]
        case .password:
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        case .openSSHConfig:
            arguments += ["-o", "BatchMode=no"]
        }

        if ssh.authentication == .openSSHConfig, !ssh.configHostAlias.isEmpty {
            arguments.append(ssh.configHostAlias)
        } else {
            arguments += ["-p", String(ssh.port)]
            arguments.append(ssh.username.isEmpty ? ssh.host : "\(ssh.username)@\(ssh.host)")
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["POSTY_CONNECTION_ID"] = profile.id.uuidString
        if let helper = Bundle.main.path(forAuxiliaryExecutable: "PostySSHAskPass")
            ?? Bundle.main.path(forResource: "PostySSHAskPass", ofType: nil) {
            environment["SSH_ASKPASS"] = helper
        }
        process.environment = environment
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        self.process = process
        localPort = port

        for _ in 0..<60 {
            if !process.isRunning {
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw SSHTunnelError.processExited(code: process.terminationStatus, message: error)
            }
            if Self.canConnect(port: port) { return Endpoint(host: "localhost", port: port) }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        throw SSHTunnelError.timeout
    }

    func stop() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
        localPort = nil
    }

    private static func normalized(_ keyLine: String, hostToken: String) -> String {
        let fields = keyLine.split(separator: " ")
        guard fields.count >= 3 else { return keyLine }
        return "\(hostToken) \(fields[1]) \(fields[2])"
    }

    private static func fingerprint(for keyLine: String) async throws -> String {
        let result = try await run(executable: "/usr/bin/ssh-keygen", arguments: ["-lf", "-"], input: keyLine + "\n")
        guard result.status == 0 else { throw SSHTunnelError.hostScanFailed(result.error) }
        let fields = result.output.split(separator: " ")
        return fields.count > 1 ? String(fields[1]) : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(executable: String, arguments: [String], input: String?) async throws -> (status: Int32, output: String, error: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            if let input {
                let inputPipe = Pipe()
                inputPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inputPipe.fileHandleForWriting.close()
                process.standardInput = inputPipe
            }
            process.terminationHandler = { process in
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, output, error))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SSHTunnelError.portAllocationFailed }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw SSHTunnelError.portAllocationFailed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else { throw SSHTunnelError.portAllocationFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func canConnect(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}

enum SSHHostKeyStatus: Sendable {
    case trusted(fingerprint: String)
    case unknown(host: String, fingerprint: String, keyLine: String)
    case changed(host: String, fingerprint: String)
}

enum SSHTunnelError: LocalizedError, Sendable {
    case hostScanFailed(String)
    case hostKeyApprovalRequired(host: String, fingerprint: String, keyLine: String)
    case hostKeyChanged(host: String, fingerprint: String)
    case portAllocationFailed
    case processExited(code: Int32, message: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .hostScanFailed(let message): "Could not read the SSH host key. \(message)"
        case .hostKeyApprovalRequired(let host, let fingerprint, _): "Trust SSH host \(host) with fingerprint \(fingerprint)?"
        case .hostKeyChanged(let host, let fingerprint): "The SSH host key for \(host) changed (\(fingerprint)). Connection was blocked."
        case .portAllocationFailed: "Could not allocate a local tunnel port."
        case .processExited(let code, let message): "SSH exited with code \(code). \(message)"
        case .timeout: "The SSH tunnel did not become ready in time."
        }
    }
}
