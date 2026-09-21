import SwiftUI

@MainActor
@Observable
final class ConnectionManagerViewModel {
    enum HostRetryAction { case test, connect, databases }

    var draft = ConnectionProfile()
    var isEditorPresented = false
    var isTesting = false
    var statusMessage: String?
    var errorMessage: String?
    var pendingHostTrust: (host: String, fingerprint: String, keyLine: String)?
    var pendingHostRetry: HostRetryAction?
    var databaseChoices: [String] = []
    var showsDatabaseChoices = false
    var profileSearch = ""
    var connectionURL = ""

    let appModel: AppModel
    private let onConnect: (ConnectionProfile) -> Void

    var visibleProfiles: [ConnectionProfile] {
        appModel.profiles
            .filter {
                profileSearch.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(profileSearch) ||
                $0.host.localizedCaseInsensitiveContains(profileSearch) ||
                $0.database.localizedCaseInsensitiveContains(profileSearch)
            }
            .sorted {
                switch ($0.lastConnectedAt, $1.lastConnectedAt) {
                case let (left?, right?) where left != right: left > right
                case (_?, nil): true
                case (nil, _?): false
                default: $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
    }

    var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...65_535).contains(draft.port) &&
        (!draft.ssh.enabled || (!draft.ssh.host.isEmpty && (1...65_535).contains(draft.ssh.port)))
    }

    init(appModel: AppModel, createNew: Bool, onConnect: @escaping (ConnectionProfile) -> Void) {
        self.appModel = appModel
        self.onConnect = onConnect
        isEditorPresented = createNew
    }

    func beginCreate() {
        draft = ConnectionProfile()
        connectionURL = ""
        statusMessage = nil
        isEditorPresented = true
    }

    func beginEdit(_ profile: ConnectionProfile) {
        draft = profile
        connectionURL = ""
        statusMessage = nil
        isEditorPresented = true
    }

    func importURL() {
        guard let url = URL(string: connectionURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = ConnectionProfileError.invalidURL.localizedDescription
            return
        }
        do {
            let existingID = draft.id
            var imported = try ConnectionProfile.fromPostgresURL(url)
            imported.id = existingID
            imported.colorName = draft.colorName
            imported.ssh = draft.ssh
            imported.lastConnectedAt = draft.lastConnectedAt
            draft = imported
            statusMessage = "Connection URL imported"
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func save() -> Bool {
        guard canSave else {
            errorMessage = "Enter a name, host, database, username, and valid port."
            return false
        }
        do {
            try appModel.save(draft)
            statusMessage = "Saved securely in Keychain"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ profile: ConnectionProfile) {
        do { try appModel.delete(profile) }
        catch { errorMessage = error.localizedDescription }
    }

    func connect(_ profile: ConnectionProfile) async {
        draft = profile
        await test(connectAfter: true)
    }

    func test(connectAfter: Bool = false) async {
        guard save() else { return }
        isTesting = true
        statusMessage = "Connecting…"
        defer { isTesting = false }
        let session = DatabaseSession(profile: draft)
        do {
            let catalog = try await session.connect()
            await session.disconnect()
            statusMessage = "PostgreSQL \(catalog.serverVersionNumber / 10_000) · \(catalog.objects.count) objects"
            if connectAfter {
                draft.lastConnectedAt = .now
                guard save() else { return }
                isEditorPresented = false
                onConnect(draft)
            }
        } catch let error as SSHTunnelError {
            if case .hostKeyApprovalRequired(let host, let fingerprint, let keyLine) = error {
                pendingHostTrust = (host, fingerprint, keyLine)
                pendingHostRetry = connectAfter ? .connect : .test
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showDatabases() async {
        guard save() else { return }
        isTesting = true
        statusMessage = "Loading databases…"
        defer { isTesting = false }
        let session = DatabaseSession(profile: draft)
        do {
            _ = try await session.connect()
            databaseChoices = try await session.listDatabases()
            await session.disconnect()
            showsDatabaseChoices = true
            statusMessage = "\(databaseChoices.count) databases"
        } catch let error as SSHTunnelError {
            if case .hostKeyApprovalRequired(let host, let fingerprint, let keyLine) = error {
                pendingHostTrust = (host, fingerprint, keyLine)
                pendingHostRetry = .databases
            } else { errorMessage = error.localizedDescription }
        } catch { errorMessage = error.localizedDescription }
    }

    func trustPendingHost() async {
        guard let pendingHostTrust else { return }
        let retry = pendingHostRetry
        do {
            try SSHTunnel(profile: draft).trust(pendingHostTrust.keyLine)
            self.pendingHostTrust = nil
            pendingHostRetry = nil
            switch retry {
            case .connect: await test(connectAfter: true)
            case .databases: await showDatabases()
            case .test, .none: await test()
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ConnectionManagerView: View {
    @State private var model: ConnectionManagerViewModel
    @State private var pendingDeletion: ConnectionProfile?

    init(appModel: AppModel, initiallyCreatesProfile: Bool, onConnect: @escaping (ConnectionProfile) -> Void) {
        _model = State(initialValue: ConnectionManagerViewModel(appModel: appModel, createNew: initiallyCreatesProfile, onConnect: onConnect))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Connections").font(.title2.bold())
                    Text("Connect to PostgreSQL directly or through SSH").foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.beginCreate() } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("newConnection")
            }
            .padding(16)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter connections", text: $model.profileSearch).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()
            if model.visibleProfiles.isEmpty {
                ContentUnavailableView {
                    Label("No Connections", systemImage: "cylinder")
                } description: {
                    Text(model.profileSearch.isEmpty ? "Create a PostgreSQL connection to get started." : "No connection matches your search.")
                } actions: {
                    if model.profileSearch.isEmpty {
                        Button("New Connection") { model.beginCreate() }
                    }
                }
            } else {
                List(model.visibleProfiles) { profile in
                    ConnectionRow(
                        profile: profile,
                        isConnecting: model.isTesting,
                        connect: { Task { await model.connect(profile) } },
                        edit: { model.beginEdit(profile) },
                        delete: { pendingDeletion = profile }
                    )
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Label(model.appModel.codexStatus, systemImage: model.appModel.codexAvailable ? "sparkles" : "sparkles.slash")
                    .foregroundStyle(.secondary)
                    .help("AI requires Codex configured with Azure, Luna, and Terra")
                if let status = model.statusMessage {
                    Divider().frame(height: 14)
                    Text(status).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(.bar)
        }
        .sheet(isPresented: $model.isEditorPresented) {
            ConnectionEditorSheet(model: model)
        }
        .alert("Connection Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Trust SSH Host?", isPresented: Binding(get: { model.pendingHostTrust != nil }, set: { if !$0 { model.pendingHostTrust = nil } })) {
            Button("Cancel", role: .cancel) { model.pendingHostTrust = nil }
            Button("Trust") { Task { await model.trustPendingHost() } }
        } message: {
            Text("\(model.pendingHostTrust?.host ?? "")\n\(model.pendingHostTrust?.fingerprint ?? "")\n\nCompare this fingerprint with your server before trusting it.")
        }
        .alert("Delete Connection?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let profile = pendingDeletion { model.delete(profile) }
                pendingDeletion = nil
            }
        } message: {
            Text("This removes \(pendingDeletion?.name ?? "this connection") and its credentials from Keychain.")
        }
    }
}

private struct ConnectionRow: View {
    let profile: ConnectionProfile
    let isConnecting: Bool
    let connect: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(profileColor(profile.colorName))
                .frame(width: 12, height: 12)
            Image(systemName: profile.ssh.enabled ? "lock.shield" : "cylinder")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.headline)
                Text(profile.endpointDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let lastConnectedAt = profile.lastConnectedAt {
                Text(lastConnectedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Never connected").font(.caption).foregroundStyle(.tertiary)
            }
            Button("Connect", action: connect)
                .buttonStyle(.bordered)
                .disabled(isConnecting)
            Menu {
                Button("Edit", action: edit)
                Divider()
                Button("Delete", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: connect)
        .contextMenu {
            Button("Edit", action: edit)
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

private struct ConnectionEditorSheet: View {
    @Bindable var model: ConnectionManagerViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.appModel.profiles.contains(where: { $0.id == model.draft.id }) ? "Edit Connection" : "New Connection")
                    .font(.title2.bold())
                Spacer()
                if model.isTesting { ProgressView().controlSize(.small) }
            }
            .padding(16)

            Divider()
            ConnectionEditorView(profile: $model.draft, connectionURL: $model.connectionURL, importURL: model.importURL)
            Divider()

            HStack {
                if let status = model.statusMessage { Text(status).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.statusMessage = nil
                    model.isEditorPresented = false
                }
                Button("Test") { Task { await model.test() } }
                    .disabled(!model.canSave || model.isTesting)
                Button("Show Databases") { Task { await model.showDatabases() } }
                    .disabled(!model.canSave || model.isTesting)
                Button("Connect") { Task { await model.test(connectAfter: true) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave || model.isTesting)
                    .accessibilityIdentifier("connectConnection")
            }
            .padding(14)
            .background(.bar)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 650, idealHeight: 720)
        .sheet(isPresented: $model.showsDatabaseChoices) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Available Databases").font(.title2.bold())
                List(model.databaseChoices, id: \.self) { database in
                    Button(database) {
                        model.draft.database = database
                        model.showsDatabaseChoices = false
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.showsDatabaseChoices = false }
                }
            }
            .padding()
            .frame(width: 420, height: 360)
        }
    }
}

private struct ConnectionEditorView: View {
    @Binding var profile: ConnectionProfile
    @Binding var connectionURL: String
    let importURL: () -> Void

    private let colors = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "gray"]

    var body: some View {
        Form {
            Section("PostgreSQL URL") {
                HStack {
                    TextField("postgresql://user:password@host:5432/database", text: $connectionURL)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("connectionURL")
                    Button("Import", action: importURL).disabled(connectionURL.isEmpty)
                }
                Text("Importing fills the fields below; you can review them before connecting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connection") {
                TextField("Name", text: $profile.name)
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        ForEach(colors, id: \.self) { color in
                            Button {
                                profile.colorName = color
                            } label: {
                                Circle()
                                    .fill(profileColor(color))
                                    .frame(width: 17, height: 17)
                                    .overlay {
                                        if profile.colorName == color {
                                            Circle().stroke(.primary, lineWidth: 2).padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.capitalized)
                        }
                    }
                }
                TextField("Host", text: $profile.host)
                TextField("Port", value: $profile.port, format: .number.grouping(.never))
                TextField("Database", text: $profile.database)
                TextField("Username", text: $profile.username)
                SecureField("Password", text: $profile.password)
            }
            Section("TLS") {
                Picker("Mode", selection: $profile.tlsMode) {
                    ForEach(ConnectionProfile.TLSMode.allCases) { Text($0.title).tag($0) }
                }
                TextField("Server CA path", text: $profile.serverCAPath)
                TextField("Client certificate path", text: $profile.clientCertificatePath)
                TextField("Client key path", text: $profile.clientKeyPath)
            }
            Section("SSH Tunnel") {
                Toggle("Connect through SSH", isOn: $profile.ssh.enabled)
                if profile.ssh.enabled {
                    TextField("SSH host", text: $profile.ssh.host)
                    TextField("SSH port", value: $profile.ssh.port, format: .number.grouping(.never))
                    TextField("SSH username", text: $profile.ssh.username)
                    Picker("Authentication", selection: $profile.ssh.authentication) {
                        ForEach(ConnectionProfile.SSHAuthentication.allCases) { Text($0.title).tag($0) }
                    }
                    if profile.ssh.authentication == .privateKey {
                        TextField("Private key path", text: $profile.ssh.privateKeyPath)
                        SecureField("Private key passphrase", text: $profile.ssh.privateKeyPassphrase)
                    }
                    if profile.ssh.authentication == .password {
                        SecureField("SSH password", text: $profile.ssh.password)
                    }
                    if profile.ssh.authentication == .openSSHConfig {
                        TextField("Host alias", text: $profile.ssh.configHostAlias)
                    }
                    TextField("ProxyJump (optional)", text: $profile.ssh.proxyJump)
                }
            }
        }
        .formStyle(.grouped)
    }
}

func profileColor(_ name: String) -> Color {
    switch name {
    case "purple": .purple
    case "pink": .pink
    case "red": .red
    case "orange": .orange
    case "yellow": .yellow
    case "green": .green
    case "teal": .teal
    case "gray": .gray
    default: .blue
    }
}
