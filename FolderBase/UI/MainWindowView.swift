import SwiftUI
import os

struct MainWindowView: View {
    private let initialFolderURL: URL?
    private let inheritedConfigurationRootURL: URL?
    private static let performanceLog = OSLog(subsystem: "com.paolosturbini.folderbase", category: .pointsOfInterest)
    @ObservedObject private var loc = LocalizationManager.shared
    // Riferimento stabile ma non osservato dalla finestra intera: sono tabella e sidebar a
    // sottoscrivere solo gli eventi necessari. Evita di rigenerare tutto l'HSplitView.
    @State private var metadataStore = MetadataStore()
    @StateObject private var recentFoldersStore = RecentFoldersStore()
    @StateObject private var templateStore = TemplateStore()
    @StateObject private var backupService = BackupService()
    @StateObject private var indexingService = IndexingService()
    @StateObject private var directoryCache = DirectorySnapshotCache()
    // @State (non @StateObject): MainWindowView possiede chatService in modo stabile ma NON si
    // ri-renderizza ai suoi cambi (streaming chat). Solo ChatView lo osserva. Evita che ogni token
    // della risposta rigeneri l'intera finestra/tabella (causa del blocco a 99% CPU).
    @State private var chatService = ChatService()
    @State private var selectedFolderURL: URL?
    /// Item attualmente selezionato (singolo) nella tabella: pilota il pannello note della sidebar.
    @State private var selectedNoteItem: FileItem?
    /// Radice STABILE dell'albero nella sidebar. Resta la cartella "base" scelta:
    /// navigando nelle sottocartelle non cambia, così l'albero non viene ricostruito/riletto.
    @State private var treeRootURL: URL?
    @State private var items: [FileItem] = []
    @State private var errorMessage: String?
    @State private var backStack: [URL] = []
    @State private var forwardStack: [URL] = []
    @AppStorage("sidebarFontSize") private var sidebarFontSize = 14.0
    @AppStorage("contentFontSize") private var contentFontSize = 13.0
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage("autoPurgeOrphans") private var autoPurgeOrphans = false
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false
    @AppStorage("showFileExtensions") private var showFileExtensions = false
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = false
    @AppStorage(AppAccentColor.storageKey) private var appAccentRaw = AppAccentColor.blue.rawValue
    @AppStorage(AppAccentColor.customHexKey) private var appAccentCustomHex = ""
    @State private var managedWatcher: FSEventsWatcher?
    @State private var isLoading = false
    /// Lettura della cartella corrente: cancellata quando l'utente naviga altrove, così una
    /// directory lenta non continua a consumare I/O dopo essere diventata irrilevante.
    @State private var folderLoadTask: Task<Void, Never>?
    @State private var templateVerificationTask: Task<Void, Never>?
    @State private var verifiedTemplateFolders: Set<String> = []
    /// Popolato all'avvio (se il controllo automatico è attivo) quando GitHub segnala una
    /// versione più recente: pilota l'alert che propone di scaricarla.
    @State private var availableUpdate: AvailableUpdate?

    init(initialFolderURL: URL? = nil, inheritedConfigurationRootURL: URL? = nil) {
        let root = initialFolderURL?.standardizedFileURL
        self.initialFolderURL = root
        self.inheritedConfigurationRootURL = inheritedConfigurationRootURL?.standardizedFileURL
        _selectedFolderURL = State(initialValue: root)
        _treeRootURL = State(initialValue: root)
    }

    private var displayedRootURLs: [URL] {
        initialFolderURL.map { [$0] } ?? recentFoldersStore.folderURLs
    }

    /// Nelle finestre secondarie la radice visuale è la directory scelta, ma la risoluzione
    /// delle colonne continua dalla radice della finestra di origine.
    private var metadataConfigurationRootURL: URL? {
        inheritedConfigurationRootURL ?? treeRootURL
    }

    var body: some View {
        // HSplitView nativo invece di NavigationSplitView: niente animazioni di colonna
        // (e quindi niente sovrapposizione sidebar/dettaglio durante avanti/indietro).
        HSplitView {
            SidebarView(
                selectedFolderURL: selectedFolderURL,
                recentFolderURLs: displayedRootURLs,
                managedFolderURLs: recentFoldersStore.folderURLs,
                treeRootURL: metadataConfigurationRootURL,
                sidebarFontSize: $sidebarFontSize,
                contentFontSize: $contentFontSize,
                appearanceMode: $appearanceMode,
                showHiddenFiles: $showHiddenFiles,
                showFileExtensions: $showFileExtensions,
                selectFolder: selectFolder,
                removeFolder: removeRecentFolder,
                reorderFolder: { url, offset in recentFoldersStore.move(url, offset: offset) },
                chooseFolder: chooseFolder,
                navigateTo: navigate,
                moveItems: moveItemsByPath,
                directoryAction: performDirectoryAction,
                templateStore: templateStore,
                metadataStore: metadataStore,
                backupService: backupService,
                indexingService: indexingService,
                directoryCache: directoryCache,
                chatService: chatService,
                selectedNoteItem: selectedNoteItem
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 380, maxHeight: .infinity)

            FileTableView(
                items: $items,
                metadataStore: metadataStore,
                selectedFolderURL: selectedFolderURL,
                configurationRootURL: metadataConfigurationRootURL,
                activeTemplate: templateStore.activeTemplate,
                errorMessage: errorMessage,
                canGoBack: !backStack.isEmpty,
                canGoForward: !forwardStack.isEmpty,
                openItem: openItem,
                goBack: goBack,
                goForward: goForward,
                goUp: goUp,
                renameItem: renameItem,
                moveItem: moveItem,
                moveItems: moveItemsByPath,
                trashItems: trashItems,
                createItem: createItemInCurrentFolder,
                isLoading: isLoading,
                contentFontSize: contentFontSize,
                showFileExtensions: showFileExtensions,
                onSelectItem: { selectedNoteItem = $0 },
                chatService: chatService
            )
            .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 650)
        .tint(AppAccentColor.color(forRaw: appAccentRaw, customHex: appAccentCustomHex))
        .preferredColorScheme(AppearanceMode(rawValue: appearanceMode)?.colorScheme)
        .onAppear {
            loadInitialFolderIfNeeded()
            scheduleManagedTemplateVerification()
            performInitialSync()
            checkForUpdatesIfEnabled()
            backupService.configure(
                store: metadataStore,
                templateStore: templateStore,
                recentFoldersStore: recentFoldersStore
            )
        }
        .onChange(of: showHiddenFiles) { _, _ in
            reloadCurrentFolder()
        }
        .onReceive(metadataStore.metadataStructureChanges) {
            verifiedTemplateFolders.removeAll(keepingCapacity: true)
        }
        // Richieste dal menu della barra dei menu: carica la cartella scelta. Il publisher
        // emette il valore corrente anche alla sottoscrizione, così funziona pure quando la
        // finestra era chiusa ed è appena stata ricreata.
        .onReceive(MenuBarBridge.shared.$requestedFolder) { url in
            guard let url else { return }
            MenuBarBridge.shared.requestedFolder = nil
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            selectFolder(url)
        }
        // Deep link folderbase://open?id=…: risolve l'identità nel percorso attuale (via bookmark,
        // quindi valido anche se il file è stato spostato/rinominato) e apre il file nell'app
        // predefinita del sistema. La finestra di FolderBase non viene portata in primo piano.
        .onReceive(MenuBarBridge.shared.$requestedFileID) { id in
            guard let id, !id.isEmpty else { return }
            MenuBarBridge.shared.requestedFileID = nil
            guard let url = metadataStore.resolveURL(forIdentity: id) else { return }
            NSWorkspace.shared.open(url)
        }
        .alert(
            L("update.available.title"),
            isPresented: Binding(
                get: { availableUpdate != nil },
                set: { if !$0 { availableUpdate = nil } }
            ),
            presenting: availableUpdate
        ) { update in
            Button(L("update.download")) {
                NSWorkspace.shared.open(update.url)
                availableUpdate = nil
            }
            Button(L("update.later"), role: .cancel) {
                availableUpdate = nil
            }
        } message: { update in
            Text("\(L("update.available.messagePrefix")) \(update.tag) \(L("update.available.messageSuffix"))")
        }
    }

    /// All'avvio, se l'utente ha attivato il controllo automatico, chiede a GitHub se c'è
    /// una versione più recente e in caso affermativo mostra l'alert con il download.
    private func checkForUpdatesIfEnabled() {
        guard autoCheckUpdates else { return }
        UpdateService.checkForUpdate { result in
            if case let .updateAvailable(latest, _, releaseURL, downloadURL) = result {
                availableUpdate = AvailableUpdate(tag: latest, url: downloadURL ?? releaseURL)
            }
        }
    }

    /// All'avvio riallinea il DB al filesystem (file spostati/rinominati/cancellati mentre
    /// l'app era chiusa) e avvia l'osservazione FSEvents delle cartelle gestite.
    private func performInitialSync() {
        metadataStore.reconcileManagedFiles { _, missingIdentities in
            if autoPurgeOrphans, !missingIdentities.isEmpty {
                _ = metadataStore.purge(identities: missingIdentities)
            }
            refreshManagedWatcher()
        }
    }

    /// Riconfigura l'osservatore FSEvents sull'insieme delle cartelle gestite più quella aperta.
    private func refreshManagedWatcher() {
        if managedWatcher == nil {
            managedWatcher = FSEventsWatcher { changedPaths in
                directoryCache.invalidate(paths: changedPaths)
                // La vista non deve aspettare bookmark e transazioni SQLite: aggiorna subito
                // la cartella visibile, mentre la riconciliazione prosegue indipendentemente.
                if shouldRefreshVisibleFolder(for: changedPaths) {
                    reloadCurrentFolder(preservingCurrentSnapshot: true)
                }
                metadataStore.reconcileManagedFiles(changedPaths: changedPaths) { _, missingIdentities in
                    if autoPurgeOrphans, !missingIdentities.isEmpty {
                        _ = metadataStore.purge(identities: missingIdentities)
                    }
                }
            }
        }

        // FSEvents osserva ricorsivamente: bastano le radici scelte dall'utente. Aggiungere ogni
        // sottocartella costringeva a ricreare lo stream durante la navigazione.
        managedWatcher?.watch(paths: displayedRootURLs.map(\.path))
    }

    private func loadInitialFolderIfNeeded() {
        if let selectedFolderURL, items.isEmpty {
            loadFolder(selectedFolderURL)
            return
        }
        guard let recent = recentFoldersStore.folderURLs.first else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: recent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        selectedFolderURL = recent
        treeRootURL = recent
        backStack = []
        forwardStack = []
        loadFolder(recent)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("panel.choose")

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        selectedFolderURL = url
        treeRootURL = url
        recentFoldersStore.add(url)
        applyActiveTemplate(to: url)
        refreshManagedWatcher()
        backStack = []
        forwardStack = []
        loadFolder(url)
    }

    private func selectFolder(_ url: URL) {
        selectedFolderURL = url
        treeRootURL = url
        recentFoldersStore.add(url)
        refreshManagedWatcher()
        backStack = []
        forwardStack = []
        loadFolder(url)
    }

    private func removeRecentFolder(_ url: URL) {
        recentFoldersStore.remove(url)

        if selectedFolderURL?.path == url.path {
            selectedFolderURL = nil
            treeRootURL = nil
            items = []
            errorMessage = nil
        }

        refreshManagedWatcher()
    }

    /// Mantiene stabile la radice dell'albero finché si naviga DENTRO il suo sottoalbero;
    /// la ri-ancora solo se si esce (es. risalendo sopra la radice). Evita ricostruzioni.
    private func updateTreeRoot(for url: URL) {
        // Se la destinazione appartiene a una delle cartelle gestite, la radice di
        // configurazione deve essere SEMPRE quella cartella. Prima, passando direttamente da
        // un altro ramo a una sottocartella (es. “3. risorse”), `treeRootURL` diventava la
        // sottocartella stessa e le colonne ereditate sparivano finché non si cliccava la radice.
        if let managed = managedRoot(containing: url) {
            treeRootURL = managed
            return
        }
        if let root = treeRootURL {
            let rootPath = root.standardizedFileURL.path
            let targetPath = url.standardizedFileURL.path
            if targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") {
                return
            }
        }
        treeRootURL = url
    }

    private func applyActiveTemplate(to rootURL: URL) {
        guard let template = templateStore.activeTemplate else { return }
        metadataStore.applyTemplate(template, to: rootURL)
    }

    private func applyActiveTemplateToManagedRoots() {
        guard let template = templateStore.activeTemplate else { return }
        for root in recentFoldersStore.folderURLs { metadataStore.applyTemplate(template, to: root) }
    }

    private func openItem(_ item: FileItem) {
        if item.isFolder {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func navigate(to url: URL) {
        if let selectedFolderURL {
            backStack.append(selectedFolderURL)
        }

        forwardStack = []
        selectedFolderURL = url
        updateTreeRoot(for: url)
        loadFolder(url)
    }

    private func goBack() {
        guard let previousURL = backStack.popLast() else { return }

        if let selectedFolderURL {
            forwardStack.append(selectedFolderURL)
        }

        selectedFolderURL = previousURL
        updateTreeRoot(for: previousURL)
        loadFolder(previousURL)
    }

    private func goForward() {
        guard let nextURL = forwardStack.popLast() else { return }

        if let selectedFolderURL {
            backStack.append(selectedFolderURL)
        }

        selectedFolderURL = nextURL
        updateTreeRoot(for: nextURL)
        loadFolder(nextURL)
    }

    private func goUp() {
        guard let selectedFolderURL else { return }
        let parentURL = selectedFolderURL.deletingLastPathComponent()
        guard parentURL.path != selectedFolderURL.path else { return }

        navigate(to: parentURL)
    }

    private func loadFolder(_ url: URL) {
        fetchItems(at: url, useCachedSnapshot: true)
        scheduleTemplateVerification(for: url)
    }

    private func scheduleManagedTemplateVerification() {
        templateVerificationTask?.cancel()
        templateVerificationTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            for root in recentFoldersStore.folderURLs {
                guard !Task.isCancelled else { return }
                ensureActiveTemplate(for: root)
                await Task.yield()
            }
        }
    }

    private func scheduleTemplateVerification(for url: URL) {
        templateVerificationTask?.cancel()
        guard let template = templateStore.activeTemplate else { return }
        let verificationKey = templateVerificationKey(template: template, folderURL: url)
        guard !verifiedTemplateFolders.contains(verificationKey) else { return }
        templateVerificationTask = Task(priority: .utility) {
            // Lascia completare prima il frame di navigazione e il primo snapshot.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, selectedFolderURL == url else { return }
            ensureActiveTemplate(for: url)
            verifiedTemplateFolders.insert(verificationKey)
        }
    }

    private func templateVerificationKey(template: MetadataTemplate, folderURL: URL) -> String {
        let structure = template.fields.map { field in
            field.name + ":" + field.kind.rawValue + ":" + field.options.map(\.label).joined(separator: ",")
        }.joined(separator: "|")
        return template.id + "\u{1F}" + structure + "\u{1F}" + folderURL.standardizedFileURL.path
    }

    /// Ogni apertura è un punto di consistenza: la cartella deve mostrare subito tutte le
    /// colonne del template globale, anche se l'utente l'ha selezionata prima nell'albero o se
    /// appartiene a una radice appena aggiunta.
    private func ensureActiveTemplate(for folderURL: URL) {
        guard let template = templateStore.activeTemplate else { return }
        let managed = managedRoot(containing: folderURL)
        let inherited = metadataConfigurationRootURL.flatMap { root -> URL? in
            let path = folderURL.standardizedFileURL.path
            return path == root.path || path.hasPrefix(root.path + "/") ? root : nil
        }
        let configurationRoot = managed ?? inherited ?? folderURL
        guard !metadataStore.isTemplateApplied(
            template,
            to: folderURL,
            configurationRootURL: configurationRoot
        ) else { return }

        metadataStore.applyTemplate(template, to: configurationRoot)
        // Se una struttura locale interrompe l'ereditarietà, completa anche la cartella aperta.
        if !metadataStore.isTemplateApplied(template, to: folderURL, configurationRootURL: configurationRoot) {
            metadataStore.applyTemplate(template, to: folderURL)
        }
    }

    private func reloadCurrentFolder(preservingCurrentSnapshot: Bool = false) {
        guard let selectedFolderURL else { return }
        // FSEvents ha già invalidato in modo preciso il percorso coinvolto. Una seconda
        // invalidazione della cartella selezionata renderebbe stale anche tutto il sottoalbero.
        if !preservingCurrentSnapshot {
            directoryCache.invalidate(paths: [selectedFolderURL.path])
        }
        fetchItems(at: selectedFolderURL, useCachedSnapshot: preservingCurrentSnapshot, allowStaleSnapshot: preservingCurrentSnapshot)
    }

    private func shouldRefreshVisibleFolder(for changedPaths: [String]) -> Bool {
        guard let selectedFolderURL else { return false }
        guard !changedPaths.isEmpty else { return true }
        let selected = selectedFolderURL.standardizedFileURL.path
        return changedPaths.contains { rawPath in
            let changedURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            return changedURL.path == selected
                || changedURL.deletingLastPathComponent().path == selected
        }
    }

    /// Legge il contenuto della cartella su un thread di background (la lettura del
    /// filesystem può essere lenta) e aggiorna la UI sul main thread. Un guard scarta
    /// i risultati arrivati in ritardo se nel frattempo si è navigato altrove.
    private func fetchItems(at url: URL, useCachedSnapshot: Bool, allowStaleSnapshot: Bool = false) {
        folderLoadTask?.cancel()
        if useCachedSnapshot, let cached = directoryCache.snapshot(for: url, allowStale: true) {
            items = cached.items
            metadataStore.loadMetadata(for: cached.items)
            errorMessage = nil
            isLoading = false
        } else {
            // Non mostrare le righe della cartella precedente con le colonne della nuova:
            // quella combinazione costringe SwiftUI a costruire e poi scartare un'intera Table.
            if !items.isEmpty { items = [] }
            metadataStore.loadMetadata(for: [])
            isLoading = true
        }
        let includeHidden = showHiddenFiles

        folderLoadTask = Task {
            let signpostID = OSSignpostID(log: Self.performanceLog)
            os_signpost(.begin, log: Self.performanceLog, name: "DirectoryRefresh", signpostID: signpostID, "%{public}s", url.path)
            defer { os_signpost(.end, log: Self.performanceLog, name: "DirectoryRefresh", signpostID: signpostID) }
            let outcome: (preview: FileBrowserService.Preview?, error: String?)
            do { outcome = (try await DirectoryLoadCoordinator.shared.preview(at: url, showHiddenFiles: includeHidden), nil) }
            catch { outcome = (nil, error.localizedDescription) }
            guard !Task.isCancelled, selectedFolderURL == url else { return }

            // Aggiornamento senza animazioni: evita artefatti di transizione durante la navigazione.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let loaded = outcome.preview?.items {
                    directoryCache.store(loaded, for: url)
                    if loaded != items { items = loaded }
                    metadataStore.loadMetadata(for: loaded)
                    errorMessage = nil
                } else if let error = outcome.error {
                    items = []
                    errorMessage = error
                }

                isLoading = false
            }

            // Nelle directory grandi l'anteprima è già interattiva. Completa attributi e
            // content type senza trattenere il main actor né modificare le identità delle righe.
            if outcome.preview?.needsEnrichment == true {
                let detailed = try? await DirectoryLoadCoordinator.shared.details(at: url, showHiddenFiles: includeHidden)
                guard !Task.isCancelled, selectedFolderURL == url, let detailed else { return }
                directoryCache.store(detailed, for: url)
                if detailed != items { items = detailed }
            }
        }
    }

    private func createItemInCurrentFolder(name: String, fileExtension: String, isDirectory: Bool) -> String? {
        guard let selectedFolderURL else { return nil }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard let itemURL = makeItemURL(
            folderURL: selectedFolderURL,
            name: trimmedName,
            fileExtension: trimmedExtension,
            isDirectory: isDirectory
        ) else {
            errorMessage = L("error.invalidName")
            return nil
        }

        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: itemURL, withIntermediateDirectories: false)
            } else {
                let didCreate = FileManager.default.createFile(atPath: itemURL.path, contents: Data())
                if !didCreate {
                    errorMessage = L("error.cannotCreateFile")
                    return nil
                }
            }

            reloadCurrentFolder()
            return itemURL.lastPathComponent
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func makeItemURL(folderURL: URL, name: String, fileExtension: String, isDirectory: Bool) -> URL? {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains(":") else { return nil }

        var finalName = name
        if !isDirectory, !fileExtension.isEmpty, URL(fileURLWithPath: finalName).pathExtension.isEmpty {
            finalName += ".\(fileExtension)"
        }

        let itemURL = folderURL.appendingPathComponent(finalName, isDirectory: isDirectory)
        guard !FileManager.default.fileExists(atPath: itemURL.path) else { return nil }
        return itemURL
    }

    private func renameItem(_ item: FileItem, newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destinationURL = destinationURLForRename(item: item, newName: trimmedName) else { return }
        moveItemOnDisk(item, to: destinationURL)
    }

    private func performDirectoryAction(_ url: URL, _ action: DirectoryTreeAction) {
        guard let item = itemForDirectory(at: url) else { return }
        switch action {
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        case .rename:
            let alert = NSAlert()
            alert.messageText = L("ctx.rename")
            let input = NSTextField(string: url.lastPathComponent)
            input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = input
            alert.addButton(withTitle: L("common.save"))
            alert.addButton(withTitle: L("common.cancel"))
            if alert.runModal() == .alertFirstButtonReturn { renameItem(item, newName: input.stringValue) }
        case .move:
            moveItem(item)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .markdown:
            let escaped = url.lastPathComponent.replacingOccurrences(of: "]", with: "\\]")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("[\(escaped)](\(url.absoluteString))", forType: .string)
        case .trash:
            trashItems([item])
            if recentFoldersStore.folderURLs.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                removeRecentFolder(url)
            }
        }
    }

    private func itemForDirectory(at url: URL) -> FileItem? {
        try? FileBrowserService().contentsOfDirectory(at: url.deletingLastPathComponent(), showHiddenFiles: true)
            .first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    private func moveItem(_ item: FileItem) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("panel.move")

        guard panel.runModal() == .OK,
              let destinationFolderURL = panel.url else { return }

        let destinationURL = destinationFolderURL.appendingPathComponent(item.name, isDirectory: item.isFolder)
        guard destinationURL.standardizedFileURL.path != item.url.standardizedFileURL.path,
              let resolution = resolveCollision(sourceURL: item.url, proposedDestination: destinationURL, isDirectory: item.isFolder) else { return }

        moveItemOnDisk(item, resolution: resolution)
    }

    private func destinationURLForRename(item: FileItem, newName: String) -> URL? {
        guard !newName.isEmpty,
              !newName.contains("/"),
              !newName.contains(":"),
              newName != item.name else { return nil }

        let destinationURL = item.url.deletingLastPathComponent()
            .appendingPathComponent(newName, isDirectory: item.isFolder)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else { return nil }
        return destinationURL
    }

    private func trashItems(_ targets: [FileItem]) {
        var didTrash = false
        for item in targets {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                didTrash = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if didTrash { reloadCurrentFolder() }
    }

    /// Sposta sul disco i file trascinati (per path) dentro `destinationFolder`,
    /// riconciliando i metadata e saltando spostamenti non validi.
    private func moveItemsByPath(_ paths: [String], to destinationFolder: URL) {
        let shouldCopy = NSEvent.modifierFlags.contains(.option)
        var didTransfer = false

        for path in paths {
            let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
            let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let destinationURL = destinationFolder.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: isDirectory)

            let alreadyThere = sourceURL.deletingLastPathComponent().standardizedFileURL.path == destinationFolder.standardizedFileURL.path
            let intoItself = destinationFolder.standardizedFileURL.path == sourceURL.path
                || destinationFolder.standardizedFileURL.path.hasPrefix(sourceURL.path + "/")
            guard !intoItself, !alreadyThere || shouldCopy else { continue }
            let resolution: CollisionResolution?
            if alreadyThere && shouldCopy {
                resolution = CollisionResolution(destination: uniqueCopyURL(for: sourceURL, in: destinationFolder, isDirectory: isDirectory), replacedIdentity: nil)
            } else {
                resolution = resolveCollision(sourceURL: sourceURL, proposedDestination: destinationURL, isDirectory: isDirectory)
            }
            guard let resolution else { continue }

            let previousIdentity = metadataStore.identity(for: sourceURL)
            let metadataContext = prepareMetadataMove(from: sourceURL, to: destinationFolder)
            do {
                try performTransfer(from: sourceURL, resolution: resolution, copy: shouldCopy)
                if !shouldCopy, let previousIdentity {
                    do {
                        try metadataStore.remapMetadataForMove(
                            subtreeAt: sourceURL,
                            from: metadataContext.sourceFields,
                            to: metadataContext.destinationFields
                        )
                        try metadataStore.reconcileMovedItem(previousIdentity: previousIdentity, newURL: resolution.destination)
                        if isDirectory {
                            // La cartella porta con sé l'intero sottoalbero: aggiorna subito anche
                            // path e bookmark dei discendenti già registrati. Le loro identità e i
                            // relativi metadata restano invariati sullo stesso volume; se cambiano,
                            // la riconciliazione li riaggancia atomicamente.
                            metadataStore.reconcileManagedFiles { _, _ in }
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                if let replacedIdentity = resolution.replacedIdentity { _ = metadataStore.purge(identities: [replacedIdentity]) }
                didTransfer = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        if didTransfer { reloadCurrentFolder() }
    }

    private func managedRoot(containing url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return recentFoldersStore.folderURLs
            .map(\.standardizedFileURL)
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    private struct MetadataMoveContext {
        let sourceFields: [MetadataField]
        let destinationFields: [MetadataField]
    }

    /// Eseguita da ogni percorso di spostamento (drag nell'albero, drag nella tabella e pannello
    /// “Sposta”). Verifica prima lo schema della destinazione e cattura le due serie di ID da
    /// rimappare solo dopo che l'operazione filesystem è riuscita.
    private func prepareMetadataMove(from sourceURL: URL, to destinationFolder: URL) -> MetadataMoveContext {
        let sourceRoot = managedRoot(containing: sourceURL)
        let destinationRoot = managedRoot(containing: destinationFolder)
        let sourceFields = metadataStore.fields(
            for: sourceURL.deletingLastPathComponent(),
            configurationRootURL: sourceRoot
        )
        if let template = templateStore.activeTemplate {
            metadataStore.applyTemplate(template, to: destinationRoot ?? destinationFolder)
        }
        let destinationFields = metadataStore.fields(
            for: destinationFolder,
            configurationRootURL: destinationRoot ?? destinationFolder
        )
        return MetadataMoveContext(sourceFields: sourceFields, destinationFields: destinationFields)
    }

    /// Risolve una collisione come Finder. "Sostituisci" conserva l'identità dell'elemento
    /// precedente; "Mantieni entrambi" genera un nome libero (`nome copia`, `nome copia 2`, …).
    private struct CollisionResolution {
        let destination: URL
        let replacedIdentity: String?
    }

    private func resolveCollision(sourceURL: URL, proposedDestination: URL, isDirectory: Bool) -> CollisionResolution? {
        guard FileManager.default.fileExists(atPath: proposedDestination.path) else {
            return CollisionResolution(destination: proposedDestination, replacedIdentity: nil)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("collision.title")
        alert.informativeText = "\(proposedDestination.lastPathComponent)\n\n\(L("collision.message"))"
        alert.addButton(withTitle: L("collision.replace"))
        alert.addButton(withTitle: L("collision.keepBoth"))
        alert.addButton(withTitle: L("common.cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return CollisionResolution(destination: proposedDestination, replacedIdentity: metadataStore.identity(for: proposedDestination))
        case .alertSecondButtonReturn:
            return CollisionResolution(destination: uniqueCopyURL(for: sourceURL, in: proposedDestination.deletingLastPathComponent(), isDirectory: isDirectory), replacedIdentity: nil)
        default:
            return nil
        }
    }

    /// Conserva la destinazione esistente finché il trasferimento non è terminato. In caso di
    /// errore la ripristina, evitando che "Sostituisci" distrugga il file precedente.
    private func performTransfer(from sourceURL: URL, resolution: CollisionResolution, copy: Bool) throws {
        let fm = FileManager.default
        let destination = resolution.destination
        var backupURL: URL?
        if fm.fileExists(atPath: destination.path) {
            let backup = destination.deletingLastPathComponent()
                .appendingPathComponent(".folderbase-replaced-\(UUID().uuidString)", isDirectory: false)
            try fm.moveItem(at: destination, to: backup)
            backupURL = backup
        }

        do {
            if copy { try fm.copyItem(at: sourceURL, to: destination) }
            else { try fm.moveItem(at: sourceURL, to: destination) }
        } catch {
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            if let backupURL { try? fm.moveItem(at: backupURL, to: destination) }
            throw error
        }
        if let backupURL { try? fm.removeItem(at: backupURL) }
    }

    private func uniqueCopyURL(for sourceURL: URL, in folderURL: URL, isDirectory: Bool) -> URL {
        let fm = FileManager.default
        let suffix = L("collision.copySuffix")
        let ext = isDirectory ? "" : sourceURL.pathExtension
        let base = (!isDirectory && !ext.isEmpty) ? sourceURL.deletingPathExtension().lastPathComponent : sourceURL.lastPathComponent
        var number = 1
        while true {
            let numberedSuffix = number == 1 ? suffix : "\(suffix) \(number)"
            var name = "\(base) \(numberedSuffix)"
            if !ext.isEmpty { name += ".\(ext)" }
            let candidate = folderURL.appendingPathComponent(name, isDirectory: isDirectory)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    private func moveItemOnDisk(_ item: FileItem, to destinationURL: URL) {
        moveItemOnDisk(item, resolution: CollisionResolution(destination: destinationURL, replacedIdentity: nil))
    }

    private func moveItemOnDisk(_ item: FileItem, resolution: CollisionResolution) {
        let metadataContext = prepareMetadataMove(
            from: item.url,
            to: resolution.destination.deletingLastPathComponent()
        )
        do {
            try performTransfer(from: item.url, resolution: resolution, copy: false)
            do {
                try metadataStore.remapMetadataForMove(
                    subtreeAt: item.url,
                    from: metadataContext.sourceFields,
                    to: metadataContext.destinationFields
                )
                try metadataStore.reconcileMovedItem(previousIdentity: item.identity, newURL: resolution.destination)
                if item.isFolder { metadataStore.reconcileManagedFiles { _, _ in } }
            } catch {
                errorMessage = error.localizedDescription
            }
            if let replacedIdentity = resolution.replacedIdentity { _ = metadataStore.purge(identities: [replacedIdentity]) }

            if selectedFolderURL?.standardizedFileURL.path == item.url.standardizedFileURL.path {
                selectedFolderURL = resolution.destination
            }

            reloadCurrentFolder()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Versione più recente rilevata su GitHub, con l'URL da aprire per scaricarla.
private struct AvailableUpdate: Identifiable {
    let id = UUID()
    let tag: String
    let url: URL
}
