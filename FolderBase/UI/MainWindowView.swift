import SwiftUI

struct MainWindowView: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @StateObject private var metadataStore = MetadataStore()
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
    /// Popolato all'avvio (se il controllo automatico è attivo) quando GitHub segnala una
    /// versione più recente: pilota l'alert che propone di scaricarla.
    @State private var availableUpdate: AvailableUpdate?

    var body: some View {
        // HSplitView nativo invece di NavigationSplitView: niente animazioni di colonna
        // (e quindi niente sovrapposizione sidebar/dettaglio durante avanti/indietro).
        HSplitView {
            SidebarView(
                selectedFolderURL: selectedFolderURL,
                recentFolderURLs: recentFoldersStore.folderURLs,
                treeRootURL: treeRootURL,
                sidebarFontSize: $sidebarFontSize,
                contentFontSize: $contentFontSize,
                appearanceMode: $appearanceMode,
                showHiddenFiles: $showHiddenFiles,
                showFileExtensions: $showFileExtensions,
                selectFolder: selectFolder,
                removeFolder: removeRecentFolder,
                chooseFolder: chooseFolder,
                navigateTo: navigate,
                moveItems: moveItemsByPath,
                templateStore: templateStore,
                metadataStore: metadataStore,
                backupService: backupService,
                indexingService: indexingService,
                directoryCache: directoryCache,
                selectedNoteItem: selectedNoteItem
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 380, maxHeight: .infinity)

            FileTableView(
                items: $items,
                metadataStore: metadataStore,
                selectedFolderURL: selectedFolderURL,
                configurationRootURL: treeRootURL,
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
                templates: templateStore.templates,
                applyTemplate: applyTemplate,
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
            performInitialSync()
            checkForUpdatesIfEnabled()
            backupService.configure(store: metadataStore)
        }
        .onChange(of: showHiddenFiles) { _, _ in
            reloadCurrentFolder()
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
                metadataStore.reconcileManagedFiles { _, missingIdentities in
                    if autoPurgeOrphans, !missingIdentities.isEmpty {
                        _ = metadataStore.purge(identities: missingIdentities)
                    }
                    guard let selectedFolderURL else { return }
                    let selectedPath = selectedFolderURL.standardizedFileURL.path
                    if changedPaths.isEmpty || changedPaths.contains(where: {
                        let changed = URL(fileURLWithPath: $0).standardizedFileURL.path
                        return changed == selectedPath || changed.hasPrefix(selectedPath + "/") || selectedPath.hasPrefix(changed + "/")
                    }) {
                        reloadCurrentFolder()
                    }
                }
            }
        }

        // FSEvents osserva ricorsivamente: bastano le radici scelte dall'utente. Aggiungere ogni
        // sottocartella costringeva a ricreare lo stream durante la navigazione.
        managedWatcher?.watch(paths: recentFoldersStore.folderURLs.map(\.path))
    }

    private func loadInitialFolderIfNeeded() {
        guard selectedFolderURL == nil,
              let recent = recentFoldersStore.folderURLs.first else { return }

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
        if let root = treeRootURL {
            let rootPath = root.standardizedFileURL.path
            let targetPath = url.standardizedFileURL.path
            if targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") {
                return
            }
        }
        treeRootURL = url
    }

    private func applyTemplate(_ template: MetadataTemplate) {
        guard let selectedFolderURL else { return }
        metadataStore.applyTemplate(template, to: selectedFolderURL)
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
    }

    private func reloadCurrentFolder() {
        guard let selectedFolderURL else { return }
        directoryCache.invalidate(paths: [selectedFolderURL.path])
        fetchItems(at: selectedFolderURL, useCachedSnapshot: false)
    }

    /// Legge il contenuto della cartella su un thread di background (la lettura del
    /// filesystem può essere lenta) e aggiorna la UI sul main thread. Un guard scarta
    /// i risultati arrivati in ritardo se nel frattempo si è navigato altrove.
    private func fetchItems(at url: URL, useCachedSnapshot: Bool) {
        folderLoadTask?.cancel()
        if useCachedSnapshot, let cached = directoryCache.snapshot(for: url) {
            items = cached.items
            metadataStore.loadMetadata(for: cached.items)
            errorMessage = nil
            isLoading = false
        } else {
            isLoading = true
        }
        let includeHidden = showHiddenFiles

        folderLoadTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () -> (items: [FileItem]?, error: String?) in
                guard !Task.isCancelled else { return (nil, nil) }
                do {
                    return (try FileBrowserService().contentsOfDirectory(at: url, showHiddenFiles: includeHidden), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, selectedFolderURL == url else { return }

            // Aggiornamento senza animazioni: evita artefatti di transizione durante la navigazione.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let loaded = outcome.items {
                    directoryCache.store(loaded, for: url)
                    items = loaded
                    metadataStore.loadMetadata(for: loaded)
                    errorMessage = nil
                } else if let error = outcome.error {
                    items = []
                    errorMessage = error
                }

                isLoading = false
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
            do {
                try performTransfer(from: sourceURL, resolution: resolution, copy: shouldCopy)
                if !shouldCopy, let previousIdentity {
                    do {
                        try metadataStore.reconcileMovedItem(previousIdentity: previousIdentity, newURL: resolution.destination)
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
        do {
            try performTransfer(from: item.url, resolution: resolution, copy: false)
            do {
                try metadataStore.reconcileMovedItem(previousIdentity: item.identity, newURL: resolution.destination)
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
