import SwiftUI

struct WorkspaceView: View {
    private enum SidebarSection: String, CaseIterable, Identifiable {
        case tables = "Tables"
        case queries = "Queries"
        case views = "Views"
        case routines = "Routines"
        case types = "Types"
        case extensions = "Extensions"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .tables: "tablecells"
            case .queries: "doc.text"
            case .views: "eye"
            case .routines: "function"
            case .types: "curlybraces"
            case .extensions: "puzzlepiece.extension"
            }
        }
    }

    @Bindable var model: WorkspaceModel
    @State private var showsNewFolder = false
    @State private var newFolderName = ""
    @State private var sidebarSection: SidebarSection = .tables

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
            mainContent
                .frame(minWidth: 620)
        }
        .frame(minWidth: 920, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Circle().fill(profileColor(model.profile.colorName)).frame(width: 9, height: 9)
                Text(model.profile.name).font(.headline)
                Button { Task { await model.refreshCatalog() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh database catalog")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "cylinder")
                    Picker("Database", selection: Binding(
                        get: { model.profile.database },
                        set: { database in Task { await model.switchDatabase(to: database) } }
                    )) {
                        ForEach(model.availableDatabases, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    connectionStatus
                }
            }
        }
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .tint(profileColor(model.profile.colorName))
        .sheet(isPresented: $showsNewFolder) {
            VStack(alignment: .leading, spacing: 14) {
                Text("New Query Folder").font(.title2.bold())
                TextField("Folder name", text: $newFolderName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { showsNewFolder = false }
                    Button("Create") {
                        let name = newFolderName
                        newFolderName = ""
                        showsNewFolder = false
                        Task { await model.createFolder(named: name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .frame(width: 380, height: 150)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(SidebarSection.allCases) { section in
                        Button {
                            sidebarSection = section
                        } label: {
                            Label(section.rawValue, systemImage: section.icon)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(sidebarSection == section ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            Divider()
            List {
                sidebarContents
            }
            .listStyle(.sidebar)

            Divider()
            VStack(spacing: 8) {
                TextField(sidebarSection == .queries ? "Search queries" : "Search database", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                if sidebarSection != .queries {
                    Toggle("Show system schemas", isOn: $model.showSystemSchemas)
                        .font(.caption)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var sidebarContents: some View {
        if sidebarSection == .queries {
            Section {
                ForEach(visibleQueries.filter { $0.folderID == nil }) { query in queryRow(query) }
                ForEach(model.queryFolders) { folder in
                    DisclosureGroup(folder.name) {
                        ForEach(visibleQueries.filter { $0.folderID == folder.id }) { query in queryRow(query) }
                    }
                }
                Button { model.newQuery() } label: { Label("New Query", systemImage: "plus") }
                    .buttonStyle(.plain)
            } header: {
                HStack {
                    Text("Saved Queries")
                    Spacer()
                    Button { showsNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.plain)
                }
            }
        } else if sidebarSection == .tables {
            Section("Public") {
                ForEach(objects(for: .tables).filter { $0.schema == "public" }) { object in objectRow(object) }
            }
            Section("Other Schemas") {
                ForEach(groupedBySchema(objects(for: .tables).filter { $0.schema != "public" }), id: \.0) { schema, objects in
                    DisclosureGroup(schema) { ForEach(objects) { object in objectRow(object) } }
                }
            }
        } else {
            ForEach(groupedBySchema(objects(for: sidebarSection)), id: \.0) { schema, objects in
                Section(schema) { ForEach(objects) { object in objectRow(object) } }
            }
        }
    }

    private var visibleQueries: [QueryDocument] {
        guard !model.searchText.isEmpty else { return model.savedQueries }
        return model.savedQueries.filter {
            $0.name.localizedCaseInsensitiveContains(model.searchText) ||
            $0.sql.localizedCaseInsensitiveContains(model.searchText)
        }
    }

    private func objects(for section: SidebarSection) -> [CatalogObject] {
        let kinds: Set<CatalogObjectKind>
        switch section {
        case .tables: kinds = [.table, .partitionedTable]
        case .views: kinds = [.view, .materializedView]
        case .routines: kinds = [.function, .procedure]
        case .types: kinds = [.type]
        case .extensions: kinds = [.extensionObject]
        case .queries: kinds = []
        }
        return model.visibleObjects.filter { kinds.contains($0.kind) }
    }

    private func groupedBySchema(_ objects: [CatalogObject]) -> [(String, [CatalogObject])] {
        Dictionary(grouping: objects, by: \.schema)
            .map { ($0.key, $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private func objectRow(_ object: CatalogObject) -> some View {
        Button { Task { await model.open(object) } } label: {
            Label(object.name, systemImage: object.kind.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowBackground(model.selectedCatalogObjectID == object.id ? profileColor(model.profile.colorName).opacity(0.2) : Color.clear)
        .help(object.comment ?? object.qualifiedName)
    }

    private func queryRow(_ query: QueryDocument) -> some View {
        Button { model.openQuery(query) } label: {
            Label(query.name, systemImage: "doc.text")
        }
        .buttonStyle(.plain)
        .listRowBackground(model.selectedQueryDocumentID == query.id ? profileColor(model.profile.colorName).opacity(0.2) : Color.clear)
        .contextMenu {
            Button("Unfiled") { model.moveQuery(query, to: nil) }
            if !model.queryFolders.isEmpty {
                Divider()
                ForEach(model.queryFolders) { folder in
                    Button("Move to \(folder.name)") { model.moveQuery(query, to: folder.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch model.state {
        case .connecting:
            ContentUnavailableView("Connecting", systemImage: "network", description: Text(model.profile.endpointDescription))
                .overlay { ProgressView().offset(y: 60) }
        case .failed(let message):
            ContentUnavailableView {
                Label("Connection Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.connect() } }
            }
        case .disconnected:
            ContentUnavailableView("Disconnected", systemImage: "network.slash")
        case .connected:
            if model.tabs.isEmpty {
                ContentUnavailableView {
                    Label("Choose a table or query", systemImage: "sidebar.left")
                } description: {
                    Text("Browse database objects in the sidebar or create a query.")
                } actions: {
                    Button("New Query") { model.newQuery() }
                }
            } else {
                VStack(spacing: 0) {
                    tabStrip
                    Divider()
                    if let tab = model.tabs.first(where: { $0.id == model.selectedTabID }) {
                        switch tab.content {
                        case .relation(let relation):
                            RelationTabView(model: relation, aiAvailable: model.appModel.codexAvailable, aiStatus: model.appModel.codexStatus)
                        case .query(let query):
                            QueryTabView(model: query, catalog: model.catalog, aiAvailable: model.appModel.codexAvailable, aiStatus: model.appModel.codexStatus)
                        }
                    }
                }
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    HStack(spacing: 6) {
                        Button(tab.title) { model.selectTab(tab.id) }
                            .buttonStyle(.plain)
                        Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(model.selectedTabID == tab.id ? profileColor(model.profile.colorName).opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private var connectionStatus: some View {
        HStack(spacing: 5) {
            Circle().fill(model.state == .connected ? .green : .orange).frame(width: 7, height: 7)
            Text(model.state == .connected ? "Connected" : "Working")
        }
        .font(.caption)
    }
}
