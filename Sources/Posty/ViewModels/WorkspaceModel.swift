import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceModel {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case failed(String)
        case disconnected
    }

    var profile: ConnectionProfile
    let appModel: AppModel
    var session: DatabaseSession
    let store: LocalStore?
    let codex: CodexBridge

    var state: ConnectionState = .connecting
    var catalog: CatalogSnapshot = .empty
    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var savedQueries: [QueryDocument] = []
    var queryFolders: [QueryFolder] = []
    var searchText = ""
    var showSystemSchemas = false
    var availableDatabases: [String] = []

    init(profile: ConnectionProfile, appModel: AppModel) {
        self.profile = profile
        self.appModel = appModel
        self.session = DatabaseSession(profile: profile)
        self.store = appModel.localStore
        self.codex = appModel.codex
    }

    func connect() async {
        state = .connecting
        do {
            catalog = try await session.connect()
            availableDatabases = (try? await session.listDatabases()) ?? [profile.database]
            if !availableDatabases.contains(profile.database) { availableDatabases.insert(profile.database, at: 0) }
            if let store {
                savedQueries = try await store.loadQueries(connectionID: profile.id, databaseName: profile.database)
                queryFolders = try await store.loadFolders(connectionID: profile.id, databaseName: profile.database)
                if let restoration = try await store.loadWorkspace(connectionID: profile.id, databaseName: profile.database) {
                    for item in restoration.tabs {
                        switch item.kind {
                        case .query:
                            if let id = UUID(uuidString: item.contentID), let query = savedQueries.first(where: { $0.id == id }) {
                                openQuery(query, persist: false)
                            }
                        case .relation:
                            if let object = catalog.objects.first(where: { $0.id == item.contentID }) { await open(object) }
                        }
                    }
                    if let selectedContentID = restoration.selectedContentID,
                       let selected = tabs.first(where: { $0.restorationTab.contentID == selectedContentID }) {
                        selectedTabID = selected.id
                    }
                }
            }
            state = .connected
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        await session.disconnect()
        state = .disconnected
    }

    func refreshCatalog() async {
        do { catalog = try await session.refreshCatalog() }
        catch { state = .failed(error.localizedDescription) }
    }

    func switchDatabase(to database: String) async {
        guard database != profile.database else { return }
        await session.disconnect()
        profile.database = database
        profile.lastConnectedAt = .now
        try? appModel.save(profile)
        session = DatabaseSession(profile: profile)
        catalog = .empty
        tabs.removeAll()
        selectedTabID = nil
        savedQueries.removeAll()
        queryFolders.removeAll()
        await connect()
    }

    func open(_ object: CatalogObject) async {
        if let existing = tabs.first(where: { $0.catalogObject?.id == object.id }) {
            selectedTabID = existing.id
            return
        }
        switch object.kind {
        case .table, .partitionedTable, .view, .materializedView:
            do {
                let details = try await session.relationDetails(for: object)
                let model = RelationTabModel(details: details, session: session, codex: codex)
                let tab = WorkspaceTab(title: object.name, content: .relation(model))
                tabs.append(tab)
                selectedTabID = tab.id
                await model.load()
                persistRestoration()
            } catch {
                state = .failed(error.localizedDescription)
            }
        default:
            do {
                let definition = try await session.definition(for: object)
                let query = QueryDocument(
                    connectionID: profile.id,
                    database: profile.database,
                    name: object.name,
                    sql: definition
                )
                openQuery(query, persist: false)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func newQuery() {
        openQuery(QueryDocument(connectionID: profile.id, database: profile.database), persist: false)
    }

    func openQuery(_ query: QueryDocument, persist: Bool = true) {
        if let existing = tabs.first(where: { $0.queryDocumentID == query.id }) {
            selectedTabID = existing.id
            return
        }
        let model = QueryTabModel(
            document: query,
            session: session,
            store: store,
            codex: codex,
            schemaContext: { [weak self] in self?.schemaContext ?? "" },
            onSave: { [weak self] saved in
                guard let self else { return }
                if let index = self.savedQueries.firstIndex(where: { $0.id == saved.id }) { self.savedQueries[index] = saved }
                else { self.savedQueries.insert(saved, at: 0) }
                self.tabs.first(where: { $0.queryDocumentID == saved.id })?.title = saved.name
            },
            onCatalogRefresh: { [weak self] in await self?.refreshCatalog() }
        )
        let tab = WorkspaceTab(title: query.name, content: .query(model))
        tabs.append(tab)
        selectedTabID = tab.id
        if persist { Task { await model.save() } }
        persistRestoration()
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id { selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id }
        persistRestoration()
    }

    func selectTab(_ id: UUID) {
        selectedTabID = id
        persistRestoration()
    }

    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store else { return }
        let folder = QueryFolder(connectionID: profile.id, database: profile.database, name: trimmed)
        do {
            try await store.saveFolder(folder)
            queryFolders.append(folder)
            queryFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch { state = .failed(error.localizedDescription) }
    }

    func moveQuery(_ query: QueryDocument, to folderID: UUID?) {
        guard let index = savedQueries.firstIndex(where: { $0.id == query.id }) else { return }
        savedQueries[index].folderID = folderID
        savedQueries[index].updatedAt = .now
        let updated = savedQueries[index]
        Task { try? await store?.saveQuery(updated) }
    }

    private func persistRestoration() {
        guard let store else { return }
        let restoredTabs = tabs.map(\.restorationTab)
        let selected = tabs.first(where: { $0.id == selectedTabID })?.restorationTab.contentID
        let restoration = WorkspaceRestoration(tabs: restoredTabs, selectedContentID: selected)
        Task { try? await store.saveWorkspace(restoration, connectionID: profile.id, databaseName: profile.database) }
    }

    var visibleObjects: [CatalogObject] {
        catalog.objects.filter { object in
            let system = object.schema == "pg_catalog" || object.schema == "information_schema" || object.schema.hasPrefix("pg_toast") || object.schema.hasPrefix("pg_temp")
            let searchMatches = searchText.isEmpty || object.name.localizedCaseInsensitiveContains(searchText) || object.schema.localizedCaseInsensitiveContains(searchText)
            return (showSystemSchemas || !system) && searchMatches
        }
    }

    var objectsBySchema: [(String, [CatalogObject])] {
        Dictionary(grouping: visibleObjects, by: \.schema)
            .map { ($0.key, $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var schemaContext: String {
        let relations = catalog.objects.filter { [.table, .partitionedTable, .view, .materializedView].contains($0.kind) }
        return relations.prefix(400).map { relation in
            let columns = catalog.columns.filter { $0.relationOID == relation.oid }
                .map { "\($0.name) \($0.formattedType)" }
                .joined(separator: ", ")
            return "\(relation.schema).\(relation.name) [\(relation.kind.rawValue)] (\(columns))"
        }.joined(separator: "\n")
    }

    var selectedCatalogObjectID: String? {
        tabs.first(where: { $0.id == selectedTabID })?.catalogObject?.id
    }

    var selectedQueryDocumentID: UUID? {
        tabs.first(where: { $0.id == selectedTabID })?.queryDocumentID
    }
}

@MainActor
@Observable
final class WorkspaceTab: Identifiable {
    enum Content {
        case relation(RelationTabModel)
        case query(QueryTabModel)
    }

    let id = UUID()
    var title: String
    let content: Content

    init(title: String, content: Content) {
        self.title = title
        self.content = content
    }

    var catalogObject: CatalogObject? {
        if case .relation(let model) = content { model.details.object } else { nil }
    }

    var queryDocumentID: UUID? {
        if case .query(let model) = content { model.document.id } else { nil }
    }

    var restorationTab: WorkspaceRestoration.Tab {
        switch content {
        case .query(let model): .init(kind: .query, contentID: model.document.id.uuidString)
        case .relation(let model): .init(kind: .relation, contentID: model.details.object.id)
        }
    }
}
