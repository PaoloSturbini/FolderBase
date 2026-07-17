import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileTableView: View {
    @Environment(\.openWindow) private var openWindow
    @Binding var items: [FileItem]
    let metadataStore: MetadataStore
    @ObservedObject private var loc = LocalizationManager.shared

    let selectedFolderURL: URL?
    let configurationRootURL: URL?
    let activeTemplate: MetadataTemplate?
    let errorMessage: String?
    let canGoBack: Bool
    let canGoForward: Bool
    let openItem: (FileItem) -> Void
    let goBack: () -> Void
    let goForward: () -> Void
    let goUp: () -> Void
    let renameItem: (FileItem, String) -> Void
    let moveItem: (FileItem) -> Void
    /// Sposta i file (per path) dentro una cartella di destinazione. Usato dal drop di file
    /// trascinati da fuori (Finder) nella tabella → vanno nella cartella corrente.
    let moveItems: ([String], URL) -> Void
    let trashItems: ([FileItem]) -> Void
    /// Crea un file/cartella nella cartella corrente. Ritorna il nome creato o nil in caso
    /// di errore. Parametri: nome, estensione (usata solo per i file), isDirectory.
    let createItem: (String, String, Bool) -> String?
    let isLoading: Bool
    let contentFontSize: Double
    let showFileExtensions: Bool
    /// Riporta al contenitore l'unico item selezionato (o nil se la selezione è vuota o
    /// multipla): serve al pannello note nella sidebar, che mostra la nota della riga scelta.
    var onSelectItem: (FileItem?) -> Void = { _ in }
    /// Riferimento NON osservato: la tabella non deve ri-renderizzarsi ad ogni token della chat
    /// in streaming (causava saturazione del main thread e blocco dell'app). Solo `ChatView`
    /// (che lo dichiara @ObservedObject) si aggiorna durante la conversazione.
    let chatService: ChatService

    @State private var isAddingField = false
    /// Impostato per aprire la chat: l'ambito effettivo (candidati + etichetta) è già configurato
    /// in `chatService` al momento dell'apertura (vedi `startChat`).
    @State private var chatRequest: ChatRequest?
    @State private var newItemRequest: NewItemRequest?
    @State private var fieldPendingEdit: MetadataField?
    @State private var itemPendingRename: FileItem?
    @State private var editingItemID: FileItem.ID?
    @State private var editingName: String = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var quickLookItem: FileItem?
    @State private var itemsPendingDeletion: [FileItem] = []
    @State private var showDeleteConfirmation = false
    @State private var tableSortOrder: [FileItemSortComparator] = []
    @State private var selection: Set<FileItem.ID> = []
    /// Cartella della tabella attualmente evidenziata come destinazione di un trascinamento.
    /// Il drop sulla riga ha precedenza sul drop generale della tabella e sposta/copia gli
    /// elementi dentro quella cartella, come nel Finder.
    @State private var targetedFolderID: FileItem.ID?
    /// Interruttore generale dell'AI (stessa chiave usata nella Configurazione). Quando è false
    /// spariscono le icone chat e la ricerca resta limitata al solo nome.
    @AppStorage(AIProviderSettings.Keys.enabled) private var aiEnabled = true
    @State private var searchText = ""
    @State private var searchScope: SearchScope = .name
    /// Ranking di rilevanza della ricerca "Contenuto" (ibrida FTS+semantica), identità→posizione,
    /// calcolato in modo asincrono in `onSearchChanged`.
    @State private var relevanceRank: [String: Int]?
    /// Token anti-race: scarta i risultati di una ricerca superata da una più recente.
    @State private var searchToken = UUID()
    @State private var searchTask: Task<Void, Never>?
    /// "Trova simili a questo": ranking di similarità (identità→posizione) rispetto a un file, e
    /// nome del file di riferimento (per il chip). Quando attivo prevale su ricerca testo/scope.
    @State private var similarRank: [String: Int]?
    @State private var similarToName: String?
    /// Ricerca estesa a tutto il sottoalbero (cartella corrente + sottocartelle) invece che alla
    /// sola cartella corrente. Quando attivo e c'è una query, la base di ricerca è `subtreeItems`.
    @State private var searchAllSubfolders = false
    /// File del sottoalbero (ricorsivo), enumerati on-demand per la ricerca estesa; cachati per
    /// il percorso corrente in `subtreeLoadedForPath`.
    @State private var subtreeItems: [FileItem] = []
    @State private var subtreeLoadedForPath: String?
    @State private var optionFilters: [String: Set<String>] = [:]
    @State private var viewMode: ViewMode = .table
    @State private var boardFieldID: String?
    @State private var hiddenByFolder: [String: Set<String>] = [:]
    @AppStorage("hiddenColumnsByFolder") private var hiddenColumnsData = Data()
    @State private var globallyHiddenTemplateFieldIDs: Set<String> = []
    @AppStorage("globallyHiddenTemplateFieldIDs") private var globallyHiddenTemplateFieldsData = Data()

    /// Cache di indice metadata ed elenco visibile (filtrato+ordinato): ricalcolati SOLO
    /// quando cambiano dati, ricerca, filtri o ordinamento (vedi `refreshDisplayCache`),
    /// non a ogni render della view come accadeva con le computed property.
    @State private var cachedIndex: [String: [String: String]] = [:]
    @State private var cachedSearchText: [String: String] = [:]
    @State private var cachedVisibleItems: [FileItem] = []
    @State private var indexRebuildTask: Task<Void, Never>?
    /// Indici della base corrente usati dagli aggiornamenti metadata incrementali. Vengono
    /// ricostruiti insieme a `cachedIndex`, evitando una scansione di `searchSource` per ogni
    /// notifica (e una seconda scansione per ogni identita modificata).
    @State private var cachedItemsByID: [String: FileItem] = [:]
    @State private var cachedSourceIDs: Set<String> = []
    @State private var noteLinkCache: [String: URL] = [:]
    @State private var missingNoteLinks: Set<String> = []

    private enum ViewMode: String, CaseIterable, Identifiable {
        case table
        case board
        var id: String { rawValue }
    }

    /// Token per presentare la finestra di chat (l'ambito è già in `chatService`).
    private struct ChatRequest: Identifiable {
        let id = UUID()
        /// File selezionato nel momento esatto in cui la chat viene aperta. Resta congelato
        /// per tutta la vita della finestra, anche se la selezione della tabella cambia.
        let focusedFile: FileItem?
    }

    /// Ambito della ricerca: per nome (storico) o per contenuto. La ricerca "Contenuto" è IBRIDA:
    /// fonde il full-text (parole esatte, FTS5/bm25) con la ricerca semantica (significato,
    /// embedding) via Reciprocal Rank Fusion, così non fa mai peggio dell'FTS e in più cattura i
    /// sinonimi/parafrasi. Vedi docs/AI-Indexing-Study.md §Fase 4.
    private enum SearchScope: String, CaseIterable, Identifiable {
        case name
        case content
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            if selectedFolderURL == nil {
                emptyState
            } else {
                navigationBar
                if !optionFilters.isEmpty || !searchText.isEmpty || similarRank != nil {
                    activeFiltersBar
                }
                content
                    .navigationTitle(selectedFolderURL?.lastPathComponent ?? "FolderBase")
            }
        }
        .sheet(isPresented: $isAddingField) {
            MetadataFieldEditorView(title: L("field.new")) { name, kind, options in
                if let selectedFolderURL {
                    metadataStore.addField(folderURL: selectedFolderURL, name: name, kind: kind, options: options)
                }
                isAddingField = false
            } cancel: {
                isAddingField = false
            }
        }
        .sheet(item: $fieldPendingEdit) { field in
            MetadataFieldEditorView(
                title: L("field.edit"),
                field: field,
                autosaveOptions: { name, kind, options in
                    if let selectedFolderURL {
                        let owner = metadataStore.ownerURL(of: field, folderURL: selectedFolderURL, configurationRootURL: configurationRootURL)
                        metadataStore.updateField(folderURL: owner, field: field, name: name, kind: kind, options: options)
                    }
                }
            ) { name, kind, options in
                if let selectedFolderURL {
                    let owner = metadataStore.ownerURL(of: field, folderURL: selectedFolderURL, configurationRootURL: configurationRootURL)
                    metadataStore.updateField(folderURL: owner, field: field, name: name, kind: kind, options: options)
                }
                fieldPendingEdit = nil
            } cancel: {
                fieldPendingEdit = nil
            }
        }
        .sheet(item: $itemPendingRename) { item in
            RenameItemView(item: item, showExtension: showFileExtensions) { newName in
                renameItem(item, newName)
                itemPendingRename = nil
            } cancel: {
                itemPendingRename = nil
            }
        }
        .sheet(item: $newItemRequest) { request in
            NewItemSheet(isDirectory: request.isDirectory, createItem: createItem) {
                newItemRequest = nil
            }
        }
        .sheet(item: $quickLookItem) { item in
            QuickLookSheet(url: item.url) { quickLookItem = nil }
        }
        .sheet(item: $chatRequest) { request in
            ChatView(chatService: chatService, store: metadataStore, focusedFile: request.focusedFile) {
                chatRequest = nil
            }
        }
        .onAppear {
            // Con AI disattivata la ricerca per contenuto non è disponibile: torna al solo nome.
            if !aiEnabled { searchScope = .name }
            rebuildMetadataIndex()
        }
        .onChange(of: aiEnabled) { _, enabled in
            if !enabled {
                searchScope = .name
                onSearchChanged()
            }
        }
        .onChange(of: items) { oldItems, newItems in
            // Cambiando cartella il riferimento di "Trova simili" non è più valido.
            similarRank = nil
            similarToName = nil
            // Qualunque operazione filesystem invalida anche la cache ricorsiva: una ricerca
            // "tutte le sottocartelle" deve riflettere subito cancellazioni e spostamenti.
            subtreeItems = []
            subtreeLoadedForPath = nil
            // Un evento filesystem normalmente tocca poche righe: aggiorna gli indici per
            // differenza e riserva la ricostruzione completa ai cambi cartella/dataset estesi.
            indexRebuildTask?.cancel()
            indexRebuildTask = Task { @MainActor in
                // Accorpa items + metadata/colonne pubblicati nello stesso ciclo UI.
                await Task.yield()
                guard !Task.isCancelled else { return }
                updateItemsIndex(from: oldItems, to: newItems)
            }
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                relevanceRank = nil
            } else {
                onSearchChanged()
            }
            noteLinkCache.removeAll()
            missingNoteLinks.removeAll()
            reportSelectedItem()
        }
        // Ricerca/filtri/ordinamento riusano l'indice esistente (nessuna ricostruzione).
        .onChange(of: searchText) { onSearchChanged() }
        .onChange(of: searchScope) { onSearchChanged() }
        .onChange(of: searchAllSubfolders) {
            // Cambiando ambito, ricostruisci indice+lista sulla nuova base.
            rebuildMetadataIndex()
            onSearchChanged()
        }
        .onChange(of: optionFilters) { refreshDisplayCache() }
        .onChange(of: tableSortOrder) { refreshDisplayCache() }
        // Cambi di DATI → ricostruzione indice.
        .onChange(of: metadataFields) { rebuildMetadataIndex() }
        .onReceive(metadataStore.metadataChanges) { identities in
            updateMetadataIndex(changedIDs: identities)
        }
        .onReceive(metadataStore.metadataStructureChanges) {
            rebuildMetadataIndex()
        }
        // Selezione → riporta l'item singolo al pannello note (o nil).
        .onChange(of: selection) { reportSelectedItem() }
    }

    /// Riporta al contenitore l'item selezionato se e solo se la selezione è singola.
    private func reportSelectedItem() {
        if selection.count == 1,
           let id = selection.first,
           let item = visibleItems.first(where: { $0.id == id }) {
            onSelectItem(item)
        } else {
            onSelectItem(nil)
        }
    }

    /// Gestisce i cambi di ricerca. In modalità "Contenuto" (ibrida) il ranking di rilevanza si
    /// calcola in modo asincrono, perché l'embedding della query può essere una chiamata di rete
    /// (Ollama/OpenAI): l'FTS è sincrona (pochi ms), l'embedding gira in un Task, i due elenchi
    /// vengono fusi via RRF e infine si aggiorna la cache. Per "Nome" si aggiorna subito.
    /// Base della ricerca: cartella corrente (`items`) oppure, con ricerca estesa attiva e una
    /// query in corso, tutto il sottoalbero (`subtreeItems`).
    private var searchSource: [FileItem] {
        let needleEmpty = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (searchAllSubfolders && !needleEmpty) ? subtreeItems : items
    }

    /// Enumera (una volta, cachato per percorso) i file del sottoalbero per la ricerca estesa.
    private func loadSubtree() async {
        guard let root = selectedFolderURL else { subtreeItems = []; subtreeLoadedForPath = nil; return }
        let loaded = await Task.detached(priority: .userInitiated) {
            IndexingService.fileItems(under: root, limit: 20000)
        }.value
        subtreeItems = loaded
        metadataStore.loadMetadata(for: loaded)
        subtreeLoadedForPath = root.path
    }

    private func onSearchChanged() {
        searchTask?.cancel()
        let rawNeedle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Digitare una ricerca esce dalla modalità "Trova simili".
        if !rawNeedle.isEmpty, similarRank != nil {
            similarRank = nil
            similarToName = nil
        }

        let token = UUID()
        searchToken = token

        // Ricerca estesa: assicura il sottoalbero caricato per il percorso corrente, poi cerca.
        if searchAllSubfolders, !rawNeedle.isEmpty, subtreeLoadedForPath != (selectedFolderURL?.path ?? "") {
            searchTask = Task {
                await loadSubtree()
                guard !Task.isCancelled, searchToken == token else { return }
                rebuildMetadataIndex()          // ricostruisce l'indice sulla nuova base
                applySearch(rawNeedle: rawNeedle, token: token)
            }
            return
        }
        searchTask = Task {
            if !rawNeedle.isEmpty {
                // Sotto 2.000 righe il filtro locale è immediato; oltre la soglia coalizza i
                // tasti per evitare scansioni e ordinamenti completi a ogni carattere.
                let count = searchSource.count
                let delay = count < 2_000 ? 0 : (count < 10_000 ? 80 : 140)
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled, searchToken == token else { return }
            }
            applySearch(rawNeedle: rawNeedle, token: token)
        }
    }

    /// Applica la ricerca corrente sulla `searchSource`. Per "Contenuto" calcola l'ibrida RRF in
    /// modo asincrono; per "Nome" aggiorna subito (il filtro per nome è in `refreshDisplayCache`).
    private func applySearch(rawNeedle: String, token: UUID) {
        guard searchScope == .content, !rawNeedle.isEmpty else {
            relevanceRank = nil
            refreshDisplayCache()
            return
        }

        // Debounce: non inviare una richiesta embedding per ogni carattere digitato.
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, searchToken == token else { return }
            let candidates = Set(searchSource.map { $0.id })
            let ftsRanked = await metadataStore.searchFileContentRanked(rawNeedle).filter { candidates.contains($0) }
            let embedder = EmbeddingEngine.active()
            let embedding = await embedder.embed(rawNeedle)
            guard !Task.isCancelled, searchToken == token else { return }

            // Elenco semantico (se l'embedding è disponibile: Ollama/OpenAI raggiungibili o Apple).
            var semanticRanked: [String] = []
            if let embedding {
                semanticRanked = await metadataStore
                    .semanticSearchAsync(queryVector: embedding.vector, providerID: embedding.providerID, candidates: candidates, limit: 300)
                    .map { $0.identity }
            }

            // Fusione: se manca uno dei due elenchi (es. Ollama spento → niente semantica) la
            // ricerca ripiega automaticamente sull'altro, quindi non fa mai peggio dell'FTS.
            let lists = [ftsRanked, semanticRanked].filter { !$0.isEmpty }
            relevanceRank = lists.isEmpty ? [:] : Self.reciprocalRankFusion(lists)
            refreshDisplayCache()
        }
    }

    /// Reciprocal Rank Fusion: combina più elenchi ordinati per rilevanza in un unico ranking.
    /// Il punteggio di un documento è la somma di 1/(k + posizione) su tutti gli elenchi in cui
    /// compare (k=60, valore standard). Ritorna identità→posizione finale (0-based, migliori prima).
    private static func reciprocalRankFusion(_ lists: [[String]], k: Double = 60) -> [String: Int] {
        var scores: [String: Double] = [:]
        for list in lists {
            for (index, identity) in list.enumerated() {
                scores[identity, default: 0] += 1.0 / (k + Double(index + 1))
            }
        }
        let ordered = scores.sorted { $0.value > $1.value }.map { $0.key }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
    }

    /// Configura l'ambito della chat (candidati + etichetta) e la apre.
    private func startChat(candidates: Set<String>, scopeLabel: String, focusedFile: FileItem? = nil) {
        chatService.configure(candidates: candidates, scopeLabel: scopeLabel)
        chatRequest = ChatRequest(focusedFile: focusedFile)
    }

    /// Identità dei file indicizzabili sotto una cartella (ricorsivo), da usare come ambito chat.
    private func folderChatCandidates(_ folder: FileItem) -> Set<String> {
        Set(IndexingService.fileItems(under: folder.url, limit: 20000).map { $0.identity })
    }

    /// "Trova simili a questo": ordina la cartella corrente per similarità semantica al file dato
    /// (centroide dei suoi vettori). Esce da un'eventuale ricerca testuale e mostra un chip.
    private func findSimilar(to file: FileItem) {
        let prefix = IndexingService.activeProviderPrefix()
        let pool = Set(items.map { $0.id })
        Task {
            let ranked = await metadataStore.similarFilesAsync(to: file.identity, providerPrefix: prefix, candidates: pool, limit: 300)
            searchText = ""
            similarRank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.identity, $0.offset) })
            similarToName = file.name
            refreshDisplayCache()
        }
    }

    /// Azzera la modalità "Trova simili".
    private func clearSimilar() {
        similarRank = nil
        similarToName = nil
        refreshDisplayCache()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text(L("table.chooseFolder"))
                .font(.title2)
                .fontWeight(.semibold)

            Text(L("table.chooseFolderHint"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .table:
            table
        case .board:
            if let field = boardField {
                KanbanBoardView(
                    items: visibleItems,
                    field: field,
                    metadataStore: metadataStore,
                    fontSize: contentFontSize,
                    openItem: openItem
                )
            } else {
                ContentUnavailableView(
                    L("table.noKanban"),
                    systemImage: "rectangle.split.3x1",
                    description: Text(L("table.noKanbanHint"))
                )
            }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)

            Button(action: goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)

            Button(action: goUp) {
                Image(systemName: "arrow.up")
            }

            Divider()
                .frame(height: 20)

            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            Text(selectedFolderURL?.path ?? "")
                .font(.system(size: contentFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
            }

            Spacer(minLength: 12)

            searchField

            toolbarButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .border(Color(nsColor: .separatorColor), width: 0.5)
    }

    /// Box di ricerca unico, stile barra di ricerca macOS: a sinistra la lente e il selettore
    /// del tipo di ricerca (Nome / Contenuto ibrido), poi il campo di testo. Tutto in una capsula.
    private var searchField: some View {
        HStack(spacing: 6) {
            Menu {
                // La scelta Nome/Contenuto ha senso solo con l'AI attiva: la ricerca "Contenuto"
                // è ibrida FTS+semantica. Con AI disattiva resta il solo nome.
                if aiEnabled {
                    Picker(L("search.scope.help"), selection: $searchScope) {
                        Text(L("search.scope.name")).tag(SearchScope.name)
                        Text(L("search.scope.content")).tag(SearchScope.content)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Divider()
                }

                Toggle(isOn: $searchAllSubfolders) {
                    Text(L("search.subfolders"))
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "magnifyingglass")
                    Text(searchScopeLabel)
                        .font(.caption)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Divider().frame(height: 14)

            TextField(searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 170)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }

    private var searchScopeLabel: String {
        switch searchScope {
        case .name: return L("search.scope.name")
        case .content: return L("search.scope.content")
        }
    }

    private var searchPlaceholder: String {
        switch searchScope {
        case .name: return "\(L("table.search")) · \(L("search.scope.name"))"
        case .content: return "\(L("table.search")) · \(L("search.scope.content"))"
        }
    }

    @ViewBuilder
    private var toolbarButtons: some View {
        HStack(spacing: 8) {
            if aiEnabled {
                Button {
                    let focusedFile = selectedItems.count == 1 && selectedItems[0].isFolder == false
                        ? selectedItems[0]
                        : nil
                    startChat(candidates: [], scopeLabel: L("chat.scope.all"), focusedFile: focusedFile)
                } label: {
                    Label(L("toolbar.chat"), systemImage: "bubble.left.and.bubble.right")
                }
                .labelStyle(.iconOnly)
            }

            if hasKanbanField {
                Picker(L("toolbar.view"), selection: $viewMode) {
                    Image(systemName: "tablecells").tag(ViewMode.table)
                    Image(systemName: "rectangle.split.3x1").tag(ViewMode.board)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 90)
            }

            Button {
                newItemRequest = NewItemRequest(isDirectory: false)
            } label: {
                Label(L("toolbar.newFile"), systemImage: "doc.badge.plus")
            }
            .labelStyle(.iconOnly)
            .disabled(selectedFolderURL == nil)

            Button {
                newItemRequest = NewItemRequest(isDirectory: true)
            } label: {
                Label(L("toolbar.newFolder"), systemImage: "folder.badge.plus")
            }
            .labelStyle(.iconOnly)
            .disabled(selectedFolderURL == nil)

            // Icona descrittiva per aggiungere una colonna metadata, a destra di
            // "Nuovo file" e "Nuova cartella" (sostituisce il vecchio pulsante "+ Colonna").
            Button {
                isAddingField = true
            } label: {
                Label(L("toolbar.addColumn"), systemImage: "rectangle.badge.plus")
            }
            .labelStyle(.iconOnly)
            .disabled(selectedFolderURL == nil)

            Divider()
                .frame(height: 20)

            columnsMenu

            Button {
                tableSortOrder = []
            } label: {
                Label(L("toolbar.defaultOrder"), systemImage: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .disabled(tableSortOrder.isEmpty)

            Button(action: exportCSV) {
                Label(L("toolbar.exportCSV"), systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .disabled(items.isEmpty)
        }
    }

    /// Menù unico di gestione colonne: per ogni colonna un sotto-menù con mostra/nascondi e,
    /// per le colonne aggiunte (metadata), anche Rinomina ed Elimina. Slegato dalle righe,
    /// quindi nessuna ambiguità con le azioni sui file.
    private var columnsMenu: some View {
        Menu {
            ForEach(allColumns) { column in
                columnSubmenu(column)
            }

            if !hiddenColumnIDs.isEmpty {
                Divider()
                Button(L("toolbar.showAllColumns")) {
                    showAllColumns()
                }
            }
        } label: {
            Label(L("toolbar.columns"), systemImage: "tablecells")
        }
        .labelStyle(.iconOnly)
    }

    @ViewBuilder
    private func columnSubmenu(_ column: ColumnDescriptor) -> some View {
        if column.id == "name" {
            Button {
            } label: {
                Label(L("column.nameAlwaysVisible"), systemImage: "checkmark")
            }
            .disabled(true)
        } else {
            Menu(column.title) {
                let isHidden = hiddenColumnIDs.contains(column.id)
                Button {
                    toggleColumnVisibility(column.id)
                } label: {
                    Label(isHidden ? L("column.show") : L("column.hide"), systemImage: isHidden ? "eye" : "eye.slash")
                }

                if case .metadata(let field) = column.kind {
                    Divider()

                    Button {
                        fieldPendingEdit = field
                    } label: {
                        Label(L("column.edit"), systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        if let selectedFolderURL {
                            let owner = metadataStore.ownerURL(of: field, folderURL: selectedFolderURL, configurationRootURL: configurationRootURL)
                            metadataStore.removeField(folderURL: owner, field: field)
                            var set = hiddenByFolder[folderKey] ?? []
                            set.remove(field.id)
                            hiddenByFolder[folderKey] = set
                        }
                    } label: {
                        Label(L("column.delete"), systemImage: "trash")
                    }
                }
            }
        }
    }

    private var activeFiltersBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let similarToName {
                    filterChip(text: "\(L("similar.chip")): \(similarToName)", systemImage: "sparkles") {
                        clearSimilar()
                    }
                }

                if !searchText.isEmpty {
                    filterChip(text: "“\(searchText)”", systemImage: "magnifyingglass") {
                        searchText = ""
                    }
                }

                ForEach(optionFilters.keys.sorted(), id: \.self) { fieldID in
                    if let field = metadataFields.first(where: { $0.id == fieldID }) {
                        ForEach(Array(optionFilters[fieldID] ?? []).sorted(), id: \.self) { label in
                            filterChip(text: "\(field.name): \(label)", systemImage: "tag") {
                                toggleFilter(fieldID: fieldID, label: label)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func filterChip(text: String, systemImage: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(text)
                .font(.caption)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay {
            Capsule().stroke(.secondary.opacity(0.2), lineWidth: 1)
        }
    }

    // MARK: - Data shaping

    private var metadataFields: [MetadataField] {
        metadataStore.fields(for: selectedFolderURL, configurationRootURL: configurationRootURL)
    }

    private var hasKanbanField: Bool {
        metadataFields.contains { $0.kind == .kanban }
    }

    private var boardField: MetadataField? {
        let kanbanFields = metadataFields.filter { $0.kind == .kanban }
        if let id = boardFieldID, let match = kanbanFields.first(where: { $0.id == id }) {
            return match
        }
        return kanbanFields.first
    }

    /// Elenco visibile (filtrato e ordinato), servito dalla cache.
    private var visibleItems: [FileItem] {
        cachedVisibleItems
    }

    /// Ricostruisce l'indice metadata [fieldID: [itemID: value]] e l'elenco visibile.
    /// Chiamata dai vari `onChange` in `body`: filtro e ordinamento (costosi, soprattutto
    /// `localizedStandardCompare`) vengono così eseguiti una sola volta per cambiamento
    /// reale invece che a ogni invalidazione di SwiftUI.
    /// Ricostruisce SOLO l'indice metadata [fieldID: [itemID: value]], poi aggiorna la vista.
    /// Costoso (O(campi × item)), quindi va chiamata solo quando cambiano i DATI (items, campi,
    /// valori metadata) — NON a ogni tasto di ricerca o cambio ordinamento, che riusano l'indice.
    private func rebuildMetadataIndex() {
        let source = searchSource
        var itemsByID: [String: FileItem] = [:]
        itemsByID.reserveCapacity(source.count)
        for item in source { itemsByID[item.id] = item }

        var index: [String: [String: String]] = [:]
        for field in metadataFields {
            var perItem: [String: String] = [:]
            for item in source {
                let value = metadataStore.value(for: item, field: field)
                if !value.isEmpty { perItem[item.id] = value }
            }
            index[field.id] = perItem
        }
        var searchIndex: [String: String] = [:]
        for item in source {
            var components = [item.name]
            for perItem in index.values {
                if let value = perItem[item.id], !value.isEmpty { components.append(value) }
            }
            searchIndex[item.id] = components.joined(separator: "\u{1F}").localizedLowercase
        }
        cachedIndex = index
        cachedSearchText = searchIndex
        cachedItemsByID = itemsByID
        cachedSourceIDs = Set(itemsByID.keys)
        refreshDisplayCache()
    }

    /// Aggiorna le cache della tabella quando il filesystem cambia poche righe. Riduce il
    /// lavoro da O(campi × tutti i file) a O(campi × righe cambiate).
    private func updateItemsIndex(from oldItems: [FileItem], to newItems: [FileItem]) {
        guard !searchAllSubfolders else {
            rebuildMetadataIndex()
            return
        }
        let oldByID = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        let removed = Set(oldByID.keys).subtracting(newByID.keys)
        let added = Set(newByID.keys).subtracting(oldByID.keys)
        let modified = Set(newByID.keys).intersection(oldByID.keys).filter { newByID[$0] != oldByID[$0] }
        let changed = added.union(modified)

        // L'arricchimento progressivo cambia solo attributi (data/dimensione/tipo), non il
        // dataset né i metadata. Aggiorna i riferimenti delle righe senza ricostruire gli indici
        // campo×file e la cache di ricerca.
        if removed.isEmpty, added.isEmpty, oldByID.keys.count == newByID.keys.count {
            cachedItemsByID = newByID
            cachedSourceIDs = Set(newByID.keys)
            refreshDisplayCache()
            return
        }

        // Un cambio molto ampio è tipicamente navigazione verso un'altra cartella: in quel
        // caso il percorso lineare è più semplice e veloce delle molte mutazioni copy-on-write.
        guard removed.count + changed.count <= max(32, newItems.count / 4) else {
            rebuildMetadataIndex()
            return
        }

        var itemsByID = cachedItemsByID
        var index = cachedIndex
        var searchIndex = cachedSearchText
        for identity in removed {
            itemsByID[identity] = nil
            searchIndex[identity] = nil
            for fieldID in index.keys { index[fieldID]?[identity] = nil }
        }
        for identity in changed {
            guard let item = newByID[identity] else { continue }
            itemsByID[identity] = item
            var components = [item.name]
            for field in metadataFields {
                let value = metadataStore.value(for: item, field: field)
                if value.isEmpty { index[field.id]?[identity] = nil }
                else {
                    index[field.id, default: [:]][identity] = value
                    components.append(value)
                }
            }
            searchIndex[identity] = components.joined(separator: "\u{1F}").localizedLowercase
        }
        cachedItemsByID = itemsByID
        cachedSourceIDs = Set(newByID.keys)
        cachedIndex = index
        cachedSearchText = searchIndex
        refreshDisplayCache()
    }

    /// Aggiorna solo le righe metadata realmente cambiate. Durante modifiche bulk o digitazione
    /// evita di rifare O(campi × file) quando è cambiato un solo file.
    private func updateMetadataIndex(changedIDs requestedIDs: Set<String>) {
        let changedIDs = requestedIDs.intersection(cachedSourceIDs)
        guard !changedIDs.isEmpty else { return }

        var index = cachedIndex
        for field in metadataFields {
            var perItem = index[field.id] ?? [:]
            for identity in changedIDs {
                let value = metadataStore.metadataByFileIdentity[identity]?.values[field.id] ?? ""
                if value.isEmpty { perItem[identity] = nil } else { perItem[identity] = value }
            }
            index[field.id] = perItem
        }
        cachedIndex = index
        var searchIndex = cachedSearchText
        for identity in changedIDs {
            var components: [String] = []
            if let item = cachedItemsByID[identity] { components.append(item.name) }
            for perItem in index.values {
                if let value = perItem[identity], !value.isEmpty { components.append(value) }
            }
            searchIndex[identity] = components.joined(separator: "\u{1F}").localizedLowercase
        }
        cachedSearchText = searchIndex

        // Una modifica di VALORE metadata cambia l'insieme di righe visibili o il loro ordine SOLO
        // se: c'è un filtro per opzione attivo, una ricerca "nome" attiva (che indicizza anche i
        // valori metadata) oppure l'ordinamento è su una colonna metadata. In tutti gli altri casi
        // la lista filtrata+ordinata è identica: evitiamo il re-filter+re-sort O(n log n) dell'intera
        // tabella. Le celle si aggiornano comunque perché `cachedIndex` è @State (già mutato sopra),
        // quindi la modifica alla cella resta visibile.
        let standardSortColumns: Set<String> = ["name", "size", "type", "created"]
        let sortIsMetadata: Bool = {
            guard let columnID = tableSortOrder.first?.columnID else { return false }
            return !standardSortColumns.contains(columnID)
        }()
        let nameSearchActive = searchScope == .name
            && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if optionFilters.isEmpty, !nameSearchActive, !sortIsMetadata {
            return
        }
        refreshDisplayCache()
    }

    /// Ricalcola SOLO la lista filtrata+ordinata riusando `cachedIndex` (non lo ricostruisce).
    private func refreshDisplayCache() {
        let index = cachedIndex
        let rawNeedle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = rawNeedle.lowercased()
        var result: [FileItem]

        // Ricerca "Contenuto" (ibrida FTS+semantica): il ranking di rilevanza è calcolato in modo
        // asincrono in `onSearchChanged` e conservato in `relevanceRank`; qui filtra i risultati
        // (appartenenza al ranking) e ne sostituisce l'ordinamento. Finché il calcolo è in corso
        // `relevanceRank` è nil → si usa una mappa vuota (nessun match) invece di ricadere sul nome.
        let activeRank: [String: Int]? = (searchScope == .content && !rawNeedle.isEmpty) ? (relevanceRank ?? [:]) : nil

        // Base: cartella corrente, o tutto il sottoalbero se la ricerca estesa è attiva.
        let source = searchSource

        if optionFilters.isEmpty, needle.isEmpty, similarRank == nil {
            result = source
        } else {
            result = source.filter { item in
                // Filtri per opzione (AND tra campi, OR tra valori dello stesso campo).
                for (fieldID, labels) in optionFilters where !labels.isEmpty {
                    let value = index[fieldID]?[item.id] ?? ""
                    if !labels.contains(value) { return false }
                }

                // "Trova simili" prevale su ricerca testo/scope.
                if let similarRank {
                    return similarRank[item.id] != nil
                }

                guard !needle.isEmpty else { return true }

                if let activeRank {
                    return activeRank[item.id] != nil
                }

                // Modalità "nome": nome file o valori metadata.
                return cachedSearchText[item.id]?.contains(needle) == true
            }
        }

        if let similarRank {
            // Ordina per similarità al file di riferimento (i più simili in alto).
            result.sort { (similarRank[$0.id] ?? .max) < (similarRank[$1.id] ?? .max) }
        } else if let activeRank {
            // Ordina per rilevanza ibrida (i più pertinenti in alto).
            result.sort { (activeRank[$0.id] ?? .max) < (activeRank[$1.id] ?? .max) }
        } else if let comparator = tableSortOrder.first {
            result.sort { comparator.compare($0, $1) == .orderedAscending }
        }
        cachedVisibleItems = result
    }

    private var selectedItems: [FileItem] {
        visibleItems.filter { selection.contains($0.id) }
    }

    /// Punto unico da cui passano tutte le cancellazioni: mostra il popup di conferma
    /// invece di cestinare subito. La cancellazione vera avviene solo su "Conferma".
    private func requestTrash(_ targets: [FileItem]) {
        guard !targets.isEmpty else { return }
        itemsPendingDeletion = targets
        showDeleteConfirmation = true
    }

    private var deleteConfirmationMessage: String {
        if itemsPendingDeletion.count == 1 {
            return L("delete.confirm.messageOne")
        }
        return "\(L("delete.confirm.messageManyPrefix")) \(itemsPendingDeletion.count) \(L("delete.confirm.messageManySuffix"))"
    }

    /// Tutte le colonne (standard + metadata), comprese quelle nascoste.
    private var allColumns: [ColumnDescriptor] {
        var result: [ColumnDescriptor] = [
            ColumnDescriptor(id: "name", title: L("col.name"), kind: .name, minWidth: 80, idealWidth: 320)
        ]

        for field in metadataFields {
            result.append(
                ColumnDescriptor(
                    id: field.id,
                    title: field.name,
                    kind: .metadata(field),
                    minWidth: minWidth(for: field),
                    idealWidth: idealWidth(for: field)
                )
            )
        }

        result.append(contentsOf: [
            ColumnDescriptor(id: "size", title: L("col.size"), kind: .size, minWidth: 50, idealWidth: 110),
            ColumnDescriptor(id: "type", title: L("col.type"), kind: .type, minWidth: 50, idealWidth: 170),
            ColumnDescriptor(id: "created", title: L("col.created"), kind: .created, minWidth: 60, idealWidth: 160)
        ])

        return result
    }

    /// La colonna Nome non è mai nascondibile (come nel Finder).
    private var hideableColumns: [ColumnDescriptor] {
        allColumns.filter { $0.id != "name" }
    }

    /// Le colonne effettivamente mostrate in tabella (escluse quelle nascoste dall'utente).
    private var visibleColumns: [ColumnDescriptor] {
        allColumns.filter { $0.id == "name" || !hiddenColumnIDs.contains($0.id) }
    }

    /// Chiave per memorizzare lo stato mostra/nascondi PER CARTELLA.
    private var folderKey: String {
        selectedFolderURL?.path ?? ""
    }

    /// Colonne nascoste nella cartella corrente (lo stato è indipendente per ogni cartella).
    private var hiddenColumnIDs: Set<String> {
        var result: Set<String> = []
        for key in configurationAncestorKeys {
            if let hidden = hiddenByFolder[key] {
                result.formUnion(hidden)
                break
            }
        }
        for field in metadataFields {
            if let templateID = templateFieldID(for: field),
               globallyHiddenTemplateFieldIDs.contains(templateID) {
                result.insert(field.id)
            }
        }
        return result
    }

    private var configurationAncestorKeys: [String] {
        guard let selectedFolderURL else { return [""] }
        let folder = selectedFolderURL.standardizedFileURL
        let candidate = configurationRootURL?.standardizedFileURL
        let root = candidate.flatMap {
            folder.path == $0.path || folder.path.hasPrefix($0.path + "/") ? $0 : nil
        } ?? folder
        var keys: [String] = []
        var current = folder
        while true {
            keys.append(current.path)
            if current.path == root.path { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { break }
            current = parent
        }
        return keys.reversed()
    }

    private var table: some View {
        Table(cachedVisibleItems, selection: $selection, sortOrder: $tableSortOrder) {
            TableColumnForEach(visibleColumns) { column in
                TableColumn(column.title, sortUsing: sortComparator(for: column, index: cachedIndex)) { item in
                    cell(for: item, column: column)
                }
                .width(min: column.minWidth, ideal: column.idealWidth)
                .customizationID(column.id)
                // La visibilità è gestita da noi (menù "Colonne"): disattiviamo quella nativa
                // così il menù di sistema sull'header non mostra più "Nascondi/Mostra".
                .disabledCustomizationBehavior(.visibility)
            }

            // Colonna vuota finale: fa da spaziatore e, soprattutto, offre una maniglia a destra
            // per ridimensionare l'ultima colonna dati (SwiftUI non dà un handle sul bordo estremo).
            TableColumn("") { _ in
                Color.clear
            }
            .width(min: 16, ideal: 60)
            .customizationID("__trailing_spacer__")
            .disabledCustomizationBehavior(.all)
        }
        .font(.system(size: contentFontSize))
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            rowContextMenu(for: ids)
        } primaryAction: { ids in
            // Doppio clic: apre l'elemento.
            if let id = ids.first, let item = visibleItems.first(where: { $0.id == id }) {
                openItem(item)
            }
        }
        .onAppear {
            restoreHiddenColumns()
            restoreGloballyHiddenTemplateFields()
        }
        .onChange(of: hiddenByFolder) {
            persistHiddenColumns()
        }
        .onChange(of: globallyHiddenTemplateFieldIDs) {
            persistGloballyHiddenTemplateFields()
        }
        // Tasto Invio: rinomina l'elemento selezionato (come nel Finder). Nessun gesto sul
        // nome, quindi la selezione col clic resta nativa e affidabile.
        .onKeyPress(.return) {
            guard editingItemID == nil,
                  selection.count == 1,
                  let id = selection.first,
                  let item = visibleItems.first(where: { $0.id == id }) else { return .ignored }
            beginRename(item)
            return .handled
        }
        // Tasto Cancella (⌫): chiede conferma prima di cestinare la selezione.
        .onDeleteCommand {
            requestTrash(selectedItems)
        }
        // Drop di file trascinati da fuori (Finder, ecc.): vengono spostati nella cartella
        // attualmente aperta. moveItems salta i file già presenti e ricarica la vista.
        .dropDestination(for: URL.self) { urls, _ in
            guard let destination = selectedFolderURL, !urls.isEmpty else { return false }
            moveItems(urls.map(\.path), destination)
            return true
        }
        .alert(L("delete.confirm.title"), isPresented: $showDeleteConfirmation) {
            Button(L("common.cancel"), role: .cancel) {
                itemsPendingDeletion = []
            }
            Button(L("delete.confirm.button"), role: .destructive) {
                trashItems(itemsPendingDeletion)
                selection = []
                itemsPendingDeletion = []
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    @ViewBuilder
    private func rowContextMenu(for ids: Set<FileItem.ID>) -> some View {
        let targets = visibleItems.filter { ids.contains($0.id) }

        if let single = targets.first, targets.count == 1 {
            Button {
                openItem(single)
            } label: {
                Label(L("ctx.open"), systemImage: single.isFolder ? "folder" : "doc")
            }

            Button {
                quickLookItem = single
            } label: {
                Label(L("ctx.quickLook"), systemImage: "eye")
            }

            Button {
                revealInFinder([single])
            } label: {
                Label(L("ctx.revealFinder"), systemImage: "magnifyingglass")
            }

            if single.isFolder {
                Button {
                    let metadataRoot = configurationRootURL ?? selectedFolderURL ?? single.url
                    openWindow(value: FolderWindowRequest(
                        folderPath: single.url.standardizedFileURL.path,
                        configurationRootPath: metadataRoot.standardizedFileURL.path
                    ))
                } label: {
                    Label(L("ctx.openNewWindow"), systemImage: "macwindow.badge.plus")
                }
            }

            if aiEnabled {
                Divider()

                if single.isFolder {
                    Button {
                        startChat(candidates: folderChatCandidates(single),
                                  scopeLabel: "\(L("chat.scope.folder")): \(single.name)")
                    } label: {
                        Label(L("ctx.chatFolder"), systemImage: "bubble.left.and.bubble.right")
                    }
                } else {
                    Button {
                        startChat(candidates: [single.identity],
                                  scopeLabel: "\(L("chat.scope.file")): \(single.name)",
                                  focusedFile: single)
                    } label: {
                        Label(L("ctx.chatFile"), systemImage: "bubble.left.and.bubble.right")
                    }

                    Button {
                        findSimilar(to: single)
                    } label: {
                        Label(L("ctx.findSimilar"), systemImage: "sparkles")
                    }
                }
            }

            Divider()

            Button {
                copyToPasteboard([single])
            } label: {
                Label(L("ctx.copy"), systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)

            Button {
                itemPendingRename = single
            } label: {
                Label(L("ctx.rename"), systemImage: "pencil")
            }

            Button {
                moveItem(single)
            } label: {
                Label(L("ctx.move"), systemImage: "folder")
            }

            Divider()

            Button {
                copyMarkdownLinks([single])
            } label: {
                Label(L("ctx.copyMarkdownLink"), systemImage: "link")
            }

            Divider()

            Button(role: .destructive) {
                requestTrash([single])
            } label: {
                Label(L("ctx.trash"), systemImage: "trash")
            }
        } else if !targets.isEmpty {
            Button {
                copyToPasteboard(targets)
            } label: {
                Label("\(L("ctx.copy")) (\(targets.count))", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)

            Button {
                revealInFinder(targets)
            } label: {
                Label(L("ctx.revealFinder"), systemImage: "magnifyingglass")
            }

            Divider()

            Button {
                copyMarkdownLinks(targets)
            } label: {
                Label(L("ctx.copyMarkdownLink"), systemImage: "link")
            }

            Divider()

            Button(role: .destructive) {
                requestTrash(targets)
            } label: {
                Label("\(L("ctx.trash")) (\(targets.count))", systemImage: "trash")
            }
        }
    }

    private func restoreHiddenColumns() {
        guard !hiddenColumnsData.isEmpty,
              let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: hiddenColumnsData) else { return }
        hiddenByFolder = decoded
    }

    private func persistHiddenColumns() {
        if let data = try? JSONEncoder().encode(hiddenByFolder) {
            hiddenColumnsData = data
        }
    }

    private func toggleColumnVisibility(_ id: String) {
        if let field = metadataFields.first(where: { $0.id == id }),
           let templateID = templateFieldID(for: field) {
            if globallyHiddenTemplateFieldIDs.contains(templateID) {
                globallyHiddenTemplateFieldIDs.remove(templateID)
            } else {
                globallyHiddenTemplateFieldIDs.insert(templateID)
            }
            return
        }
        var set = hiddenByFolder[folderKey] ?? []
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        hiddenByFolder[folderKey] = set
    }

    private func showAllColumns() {
        // Anche l'insieme vuoto è una configurazione esplicita: impedisce a una vecchia
        // configurazione della sottocartella di prevalere sulla scelta del genitore.
        hiddenByFolder[folderKey] = []
        globallyHiddenTemplateFieldIDs.removeAll()
    }

    private func templateFieldID(for field: MetadataField) -> String? {
        activeTemplate?.fields.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                == field.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                && $0.kind == field.kind
        })?.id
    }

    private func restoreGloballyHiddenTemplateFields() {
        guard !globallyHiddenTemplateFieldsData.isEmpty,
              let decoded = try? JSONDecoder().decode(Set<String>.self, from: globallyHiddenTemplateFieldsData) else { return }
        globallyHiddenTemplateFieldIDs = decoded
    }

    private func persistGloballyHiddenTemplateFields() {
        if let data = try? JSONEncoder().encode(globallyHiddenTemplateFieldIDs) {
            globallyHiddenTemplateFieldsData = data
        }
    }

    // MARK: - Cells

    /// Altezza riga fissa e compatta (vicina al nativo): garantisce che TUTTE le righe
    /// abbiano la stessa altezza, a prescindere dal contenuto (cartelle, file, celle tag/
    /// data, riga selezionata) e dalle colonne metadata presenti in quella cartella.
    private var rowHeight: CGFloat {
        max(contentFontSize + 7, 20)
    }

    private func cell(for item: FileItem, column: ColumnDescriptor) -> some View {
        cellContent(for: item, column: column)
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
    }

    @ViewBuilder
    private func cellContent(for item: FileItem, column: ColumnDescriptor) -> some View {
        switch column.kind {
        case .name:
            nameCell(item)
        case .size:
            Text(item.sizeDescription)
                .foregroundStyle(.secondary)
        case .type:
            Text(item.type)
                .foregroundStyle(.secondary)
        case .created:
            Text(item.createdDescription)
                .foregroundStyle(.secondary)
        case .metadata(let field):
            metadataCell(for: item, field: field)
        }
    }

    /// Stessa cella (icona reale + nome) per file e cartelle, altezza riga uniforme.
    /// NIENTE gesti di tap qui: la selezione è gestita nativamente dalla tabella (clic
    /// singolo) e resta così perfettamente affidabile. Apertura: doppio clic via
    /// `primaryAction`. Rinomina: tasto Invio sulla riga selezionata (vedi `.onKeyPress`
    /// nella tabella) o menu contestuale.
    @ViewBuilder
    private func nameCell(_ item: FileItem) -> some View {
        let label = nameLabel(item)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

        if editingItemID == item.id {
            label
        } else if item.isFolder {
            label
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(targetedFolderID == item.id ? Color.accentColor.opacity(0.16) : Color.clear)

                        // `SwiftUI.Table` intercetta il drop prima dei modifier SwiftUI
                        // applicati alle celle. Un ricevitore AppKit registrato per file URL
                        // rende invece la singola riga-cartella una destinazione affidabile.
                        FileFolderDropTarget(
                            isTargeted: Binding(
                                get: { targetedFolderID == item.id },
                                set: { targeted in
                                    if targeted {
                                        targetedFolderID = item.id
                                    } else if targetedFolderID == item.id {
                                        targetedFolderID = nil
                                    }
                                }
                            ),
                            onDrop: { urls in
                                guard !urls.isEmpty else { return false }
                                moveItems(urls.map(\.path), item.url)
                                return true
                            }
                        )
                    }
                )
        } else {
            label
        }
    }

    @ViewBuilder
    private func nameLabel(_ item: FileItem) -> some View {
        let iconSide = max(contentFontSize + 1, 14)
        HStack(spacing: 6) {
            // Il trascinamento del file parte solo dall'icona: così il clic sul TESTO del
            // nome resta istantaneo come le altre celle (il drag su tutta la cella
            // introduceva un ritardo alla pressione per distinguere clic/trascinamento).
            icon(for: item, side: iconSide)

            if editingItemID == item.id {
                TextField(L("common.name"), text: $editingName)
                    .textFieldStyle(.plain)
                    .focused($nameFieldFocused)
                    .onSubmit { commitRename(item) }
                    .onExitCommand { cancelRename() }
                    .onChange(of: nameFieldFocused) { _, focused in
                        if !focused { commitRename(item) }
                    }
            } else {
                Text(displayName(for: item))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    /// Icona del file/cartella. È l'unico punto trascinabile della riga: afferrando
    /// l'icona si può trascinare il file fuori dall'app senza rallentare il clic sul nome.
    /// Usa un ponte AppKit (`FileDragIcon`) che avvia una sessione di trascinamento nativa
    /// con TUTTI i file selezionati (come Finder), cosa non possibile col `.draggable` di
    /// SwiftUI su una singola cella. Un clic semplice sull'icona seleziona solo quella riga.
    @ViewBuilder
    private func icon(for item: FileItem, side: CGFloat) -> some View {
        if editingItemID == item.id {
            Image(nsImage: FileIconProvider.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
        } else {
            FileDragIcon(
                image: FileIconProvider.icon(for: item),
                dragURLs: { dragURLs(for: item) },
                onClick: { selection = [item.id] }
            )
            .frame(width: side, height: side)
        }
    }

    /// URL da trascinare afferrando l'icona di `item`: se `item` fa parte di una selezione
    /// multipla si trascinano tutti gli elementi selezionati (comportamento Finder),
    /// altrimenti solo `item`.
    private func dragURLs(for item: FileItem) -> [URL] {
        if selection.contains(item.id) && selection.count > 1 {
            return visibleItems.filter { selection.contains($0.id) }.map(\.url)
        }
        return [item.url]
    }

    /// Nome mostrato in tabella: se le estensioni sono nascoste (e l'elemento è un file
    /// con estensione), rimuove il suffisso dell'estensione. Cartelle e file senza
    /// estensione restano invariati.
    private func displayName(for item: FileItem) -> String {
        guard !showFileExtensions, !item.isFolder else { return item.name }
        let ext = item.url.pathExtension
        guard !ext.isEmpty else { return item.name }
        return (item.name as NSString).deletingPathExtension
    }

    /// Ricostruisce il nome completo del file a partire dal nome mostrato: quando le
    /// estensioni sono nascoste riaggancia l'estensione originale, così rinominando un
    /// file l'estensione viene preservata. Quando sono visualizzate il nome è già completo.
    private func fullName(fromDisplay display: String, for item: FileItem) -> String {
        guard !showFileExtensions, !item.isFolder else { return display }
        let ext = item.url.pathExtension
        guard !ext.isEmpty else { return display }
        return "\(display).\(ext)"
    }

    private func beginRename(_ item: FileItem) {
        editingName = displayName(for: item)
        editingItemID = item.id
        nameFieldFocused = true
    }

    private func commitRename(_ item: FileItem) {
        guard editingItemID == item.id else { return }
        editingItemID = nil
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newFullName = fullName(fromDisplay: trimmed, for: item)
        if newFullName != item.name {
            renameItem(item, newFullName)
        }
    }

    private func cancelRename() {
        editingItemID = nil
    }

    @ViewBuilder
    private func metadataCell(for item: FileItem, field: MetadataField) -> some View {
        switch field.kind {
        case .text:
            // Niente popover in hover: la nota della riga selezionata è mostrata nel
            // pannello dedicato in fondo alla sidebar.
            EditableTextCell(text: valueBinding(for: item, field: field))
        case .number:
            EditableTextCell(text: valueBinding(for: item, field: field), alignment: .trailing, monospacedDigits: true)
        case .date:
            DateMetadataCell(text: valueBinding(for: item, field: field))
        case .kanban:
            // Lo stato Kanban è modificabile sia sui file sia sulle cartelle (come le altre select).
            selectCell(for: item, field: field)
        case .select:
            selectCell(for: item, field: field)
        case .link:
            HStack(spacing: 6) {
                EditableTextCell(text: valueBinding(for: item, field: field), placeholder: L("link.placeholder"))

                Button {
                    chooseLink(for: item, field: field)
                } label: {
                    Image(systemName: "link.badge.plus")
                }
                .buttonStyle(.borderless)

                Button {
                    chooseWikiLink(for: item, field: field)
                } label: {
                    Image(systemName: "note.text.badge.plus")
                }
                .buttonStyle(.borderless)

                Button {
                    openLink(for: item, field: field)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .disabled(metadataStore.value(for: item, field: field).isEmpty)
            }
        }
    }

    private func selectCell(for item: FileItem, field: MetadataField) -> some View {
        ZStack(alignment: .leading) {
            Picker("", selection: valueBinding(for: item, field: field)) {
                Text(L("common.empty")).tag("")
                ForEach(field.options) { option in
                    Text(option.label).tag(option.label)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .opacity(0.02)
            .frame(maxWidth: .infinity, alignment: .leading)

            MetadataTagView(
                label: selectedOption(for: item, field: field).label,
                color: selectedOption(for: item, field: field).color,
                isEmpty: metadataStore.value(for: item, field: field).isEmpty
            )
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func valueBinding(for item: FileItem, field: MetadataField) -> Binding<String> {
        Binding(
            get: {
                metadataStore.value(for: item, field: field)
            },
            set: { newValue in
                metadataStore.update(item: item, field: field, value: newValue)
            }
        )
    }

    private func selectedOption(for item: FileItem, field: MetadataField) -> MetadataSelectOption {
        let value = metadataStore.value(for: item, field: field)
        return field.options.first { $0.label == value } ?? MetadataSelectOption(label: value, color: .gray)
    }

    // MARK: - Sorting

    private func sortComparator(for column: ColumnDescriptor, index: [String: [String: String]]) -> FileItemSortComparator {
        switch column.kind {
        case .metadata(let field):
            return FileItemSortComparator(
                columnID: column.id,
                kind: field.kind,
                metadataValuesByItemID: index[field.id] ?? [:]
            )
        default:
            return FileItemSortComparator(columnID: column.id, kind: nil)
        }
    }

    // MARK: - Filters

    private func toggleFilter(fieldID: String, label: String) {
        var labels = optionFilters[fieldID] ?? []
        if labels.contains(label) {
            labels.remove(label)
        } else {
            labels.insert(label)
        }
        if labels.isEmpty {
            optionFilters[fieldID] = nil
        } else {
            optionFilters[fieldID] = labels
        }
    }

    // MARK: - Actions

    private func revealInFinder(_ items: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    /// Copia gli elementi selezionati negli appunti come fa il Finder: scrive gli URL dei
    /// file, così un Incolla (⌘V) nel Finder o in un'altra app crea copie reali dei file.
    private func copyToPasteboard(_ items: [FileItem]) {
        let urls = items.map(\.url) as [NSURL]
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
    }

    /// Copia uno o più collegamenti Markdown assoluti. `absoluteString` produce URL `file://`
    /// correttamente percent-encoded, quindi spazi e caratteri accentati restano cliccabili.
    private func copyMarkdownLinks(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let markdown = items.map { item in
            let escapedName = item.name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "]", with: "\\]")
            return "[\(escapedName)](\(item.url.absoluteString))"
        }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    private func exportCSV() {
        let fields = metadataFields
        var header = [L("csv.name"), L("csv.size"), L("csv.type"), L("csv.created")]
        header.append(contentsOf: fields.map(\.name))

        var rows: [String] = [header.map(csvEscaped).joined(separator: ",")]
        for item in visibleItems {
            var row = [item.name, item.sizeDescription, item.type, item.createdDescription]
            for field in fields {
                row.append(metadataStore.value(for: item, field: field))
            }
            rows.append(row.map(csvEscaped).joined(separator: ","))
        }

        let csv = rows.joined(separator: "\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(selectedFolderURL?.lastPathComponent ?? "FolderBase").csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.data(using: .utf8)?.write(to: url)
    }

    private func csvEscaped(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Larghezza iniziale "standard" di una colonna appena creata: minima per il tipo di
    /// dato, ma ampia (~60 caratteri) per le note libere.
    private func idealWidth(for field: MetadataField) -> CGFloat {
        switch field.kind {
        case .text:
            return 420   // ~60 caratteri a font 13
        case .number:
            return 100
        case .date:
            return 90
        case .kanban:
            return 50
        case .select:
            return 150
        case .link:
            return 260
        }
    }

    /// Larghezza minima molto contenuta: la larghezza iniziale (idealWidth) resta ampia,
    /// ma l'utente può sempre rimpicciolire ogni colonna, note comprese.
    private func minWidth(for field: MetadataField) -> CGFloat {
        switch field.kind {
        case .text:
            return 50
        case .number:
            return 50
        case .date:
            return 60
        case .kanban:
            return 40
        case .select:
            return 60
        case .link:
            return 70
        }
    }

    // MARK: - Links

    private func chooseLink(for item: FileItem, field: MetadataField) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = L("panel.link")

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        metadataStore.update(item: item, field: field, value: url.path)
    }

    private func chooseWikiLink(for item: FileItem, field: MetadataField) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = L("panel.linkNote")

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        metadataStore.update(item: item, field: field, value: "[[\(url.deletingPathExtension().lastPathComponent)]]")
    }

    private func openLink(for item: FileItem, field: MetadataField) {
        let value = metadataStore.value(for: item, field: field)
        guard !value.isEmpty else { return }

        let destination = parsedLinkDestination(value)

        if let url = URL(string: destination), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else if let resolvedURL = resolveLocalLinkFast(destination) {
            NSWorkspace.shared.open(resolvedURL)
        } else {
            guard let root = selectedFolderURL else { return }
            let key = root.path + "\u{0}" + destination
            if let cached = noteLinkCache[key] {
                NSWorkspace.shared.open(cached)
                return
            }
            guard !missingNoteLinks.contains(key) else { return }

            Task {
                let resolved = await Task.detached(priority: .userInitiated) {
                    Self.findNote(named: destination, under: root)
                }.value
                if let resolved {
                    noteLinkCache[key] = resolved
                    NSWorkspace.shared.open(resolved)
                } else {
                    missingNoteLinks.insert(key)
                }
            }
        }
    }

    private func parsedLinkDestination(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") {
            let inner = String(trimmed.dropFirst(2).dropLast(2))
            return inner.components(separatedBy: "|").first ?? inner
        }

        if let openParen = trimmed.firstIndex(of: "("),
           trimmed.hasSuffix(")") {
            let destinationStart = trimmed.index(after: openParen)
            return String(trimmed[destinationStart..<trimmed.index(before: trimmed.endIndex)])
        }

        return trimmed
    }

    private func resolveLocalLinkFast(_ destination: String) -> URL? {
        if destination.hasPrefix("/") {
            let url = URL(fileURLWithPath: destination)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        guard let selectedFolderURL else { return nil }

        let directURL = selectedFolderURL.appendingPathComponent(destination)
        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }

        let markdownURL = selectedFolderURL.appendingPathComponent(destination).appendingPathExtension("md")
        if FileManager.default.fileExists(atPath: markdownURL.path) {
            return markdownURL
        }

        return nil
    }

    nonisolated private static func findNote(named name: String, under folderURL: URL) -> URL? {
        guard !FileSystemPolicy.isInTrash(folderURL) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            if FileSystemPolicy.isInTrash(url) {
                enumerator.skipDescendants()
                continue
            }
            let stem = url.deletingPathExtension().lastPathComponent
            if stem == name || url.lastPathComponent == name {
                return url
            }
        }

        return nil
    }
}

private struct ColumnDescriptor: Identifiable {
    enum Kind {
        case name
        case size
        case type
        case created
        case metadata(MetadataField)
    }

    let id: String
    let title: String
    let kind: Kind
    let minWidth: CGFloat
    let idealWidth: CGFloat
}

struct FileItemSortComparator: SortComparator, Hashable {
    var columnID: String
    var kind: MetadataFieldKind?
    var metadataValuesByItemID: [String: String] = [:]
    var order: SortOrder = .forward

    func compare(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        let result: ComparisonResult

        switch columnID {
        case "name":
            result = lhs.sortNameKey.localizedStandardCompare(rhs.sortNameKey)
        case "size":
            result = compareValues(lhs.size ?? -1, rhs.size ?? -1)
        case "type":
            result = lhs.sortTypeKey.localizedStandardCompare(rhs.sortTypeKey)
        case "created":
            result = compareValues(lhs.created, rhs.created)
        default:
            result = compareMetadata(lhs, rhs)
        }

        let resolved = result == .orderedSame ? lhs.sortNameKey.localizedStandardCompare(rhs.sortNameKey) : result
        return order == .forward ? resolved : resolved.reversed
    }

    private func compareMetadata(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        let lhsValue = metadataValuesByItemID[lhs.id] ?? ""
        let rhsValue = metadataValuesByItemID[rhs.id] ?? ""

        // I valori vuoti vanno sempre in fondo, a prescindere dalla direzione.
        if lhsValue.isEmpty != rhsValue.isEmpty {
            return lhsValue.isEmpty ? .orderedDescending : .orderedAscending
        }

        switch kind {
        case .number:
            let lhsNum = MetadataValueFormatter.number(from: lhsValue) ?? 0
            let rhsNum = MetadataValueFormatter.number(from: rhsValue) ?? 0
            return compareValues(lhsNum, rhsNum)
        default:
            // Le date sono salvate come "yyyy-MM-dd", quindi il confronto stringa è cronologico.
            return lhsValue.localizedStandardCompare(rhsValue)
        }
    }

    private func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }
}

struct MetadataTagView: View {
    let label: String
    let color: MetadataTagColor
    var isEmpty = false

    var body: some View {
        if isEmpty || label.isEmpty {
            Color.clear
                .frame(width: 80, height: 18)
                .contentShape(Rectangle())
        } else {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(color.swiftUIColor, in: Capsule())
                .foregroundStyle(color.foregroundColor)
                .overlay {
                    Capsule()
                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }
}

/// Cella di testo "leggera": a riposo mostra un semplice `Text` e monta il `TextField`
/// solo quando l'utente clicca per modificare. Un TextField vivo per ogni cella visibile
/// è molto più pesante di un Text statico: con molte righe e colonne questo riduce
/// drasticamente il costo di rendering della Table. Il valore viene scritto nello store
/// a ogni tasto (come prima), ma la notifica alla UI è coalizzata dallo store stesso.
private struct EditableTextCell: View {
    @Binding var text: String
    var placeholder = ""
    var alignment: TextAlignment = .leading
    var monospacedDigits = false
    var showsHoverPreview = false

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovering = false
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            editor
        } else {
            display
        }
    }

    @ViewBuilder
    private var editor: some View {
        let field = TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .focused($focused)
            .onSubmit { endEditing() }
            .onExitCommand { endEditing() }
            .onChange(of: draft) { text = draft }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { endEditing() }
            }

        if monospacedDigits {
            field.monospacedDigit()
        } else {
            field
        }
    }

    @ViewBuilder
    private var display: some View {
        let label = displayText
            .lineLimit(1)
            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
            .contentShape(Rectangle())
            .onTapGesture { beginEditing() }

        if showsHoverPreview {
            label
                .onHover { hovering in
                    isHovering = hovering && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                    Text(text)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 360, alignment: .leading)
                        .padding(12)
                }
        } else {
            label
        }
    }

    private var displayText: Text {
        let base = Text(text.isEmpty ? placeholder : text)
        return monospacedDigits ? base.monospacedDigit() : base
    }

    private func beginEditing() {
        draft = text
        isHovering = false
        isEditing = true
        // Il focus va assegnato dopo che il TextField è montato nella gerarchia.
        DispatchQueue.main.async { focused = true }
    }

    private func endEditing() {
        guard isEditing else { return }
        isEditing = false
        if draft != text { text = draft }
    }
}

/// Icona trascinabile con drag nativo AppKit: avvia una sessione di trascinamento con
/// più file (tutti quelli selezionati), che SwiftUI `.draggable` non consente da una
/// singola cella. Un clic semplice (senza trascinamento) inoltra `onClick` per selezionare.
private struct FileDragIcon: NSViewRepresentable {
    let image: NSImage
    let dragURLs: () -> [URL]
    let onClick: () -> Void

    func makeNSView(context: Context) -> FileDragSourceView {
        let view = FileDragSourceView()
        view.image = image
        view.dragURLsProvider = dragURLs
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: FileDragSourceView, context: Context) {
        view.image = image
        view.dragURLsProvider = dragURLs
        view.onClick = onClick
        view.needsDisplay = true
    }
}

/// Destinazione AppKit trasparente usata sulle righe-cartella della `Table`.
/// Non partecipa all'hit-testing dei clic, quindi selezione, doppio clic e menu contestuale
/// restano gestiti dalla tabella; riceve soltanto le sessioni di trascinamento di file URL.
private struct FileFolderDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isTargeted: $isTargeted, onDrop: onDrop)
    }

    func makeNSView(context: Context) -> FileFolderDropTargetView {
        let view = FileFolderDropTargetView()
        view.handler = context.coordinator
        return view
    }

    func updateNSView(_ view: FileFolderDropTargetView, context: Context) {
        context.coordinator.isTargeted = $isTargeted
        context.coordinator.onDrop = onDrop
        view.handler = context.coordinator
    }

    final class Coordinator {
        var isTargeted: Binding<Bool>
        var onDrop: ([URL]) -> Bool

        init(isTargeted: Binding<Bool>, onDrop: @escaping ([URL]) -> Bool) {
            self.isTargeted = isTargeted
            self.onDrop = onDrop
        }
    }
}

private final class FileFolderDropTargetView: NSView {
    weak var handler: FileFolderDropTarget.Coordinator?

    /// Registro dei bersagli visibili. Serve al drag interno avviato da `FileDragSourceView`:
    /// la `SwiftUI.Table` intercetta le normali API di drop, quindi la sorgente individua
    /// direttamente la cella-cartella sotto il punto di rilascio in coordinate schermo.
    private static var visibleTargets: [WeakTarget] = []

    private final class WeakTarget {
        weak var value: FileFolderDropTargetView?
        init(_ value: FileFolderDropTargetView) { self.value = value }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.visibleTargets.removeAll { $0.value == nil || $0.value === self }
        if window != nil { Self.visibleTargets.append(WeakTarget(self)) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func updateInternalDragTarget(at screenPoint: NSPoint) {
        let target = target(at: screenPoint)
        for entry in visibleTargets {
            guard let view = entry.value else { continue }
            view.handler?.isTargeted.wrappedValue = (view === target)
        }
    }

    static func performInternalDrop(at screenPoint: NSPoint, urls: [URL]) -> Bool {
        let target = target(at: screenPoint)
        updateInternalDragTarget(at: NSPoint(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude))
        guard let target, !urls.isEmpty else { return false }
        return target.handler?.onDrop(urls) ?? false
    }

    private static func target(at screenPoint: NSPoint) -> FileFolderDropTargetView? {
        visibleTargets.removeAll { $0.value == nil }
        return visibleTargets.compactMap(\.value).last { view in
            guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let windowRect = view.convert(view.bounds, to: nil)
            return window.convertToScreen(windowRect).contains(screenPoint)
        }
    }
}

/// NSView che disegna l'icona e, al trascinamento, avvia una `NSDraggingSession` con un
/// `NSDraggingItem` per ogni file (fileURL su pasteboard → il Finder li sposta/copia tutti).
final class FileDragSourceView: NSView {
    var image: NSImage?
    var dragURLsProvider: () -> [URL] = { [] }
    var onClick: () -> Void = {}

    private var mouseDownLocation: NSPoint = .zero
    private var didDrag = false
    private var draggedURLs: [URL] = []

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let dx = event.locationInWindow.x - mouseDownLocation.x
        let dy = event.locationInWindow.y - mouseDownLocation.y
        // Soglia ~4px: sotto è un clic, sopra è un trascinamento.
        guard (dx * dx + dy * dy) > 16 else { return }

        let urls = dragURLsProvider()
        guard !urls.isEmpty else { return }
        didDrag = true
        draggedURLs = urls

        let draggingItems: [NSDraggingItem] = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let dragImage = NSWorkspace.shared.icon(forFile: url.path)
            // Impila leggermente le icone quando i file sono più d'uno.
            let frame = NSRect(x: CGFloat(index) * 6, y: CGFloat(index) * 6,
                               width: bounds.width, height: bounds.height)
            item.setDraggingFrame(frame, contents: dragImage)
            return item
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick() }
    }
}

extension FileDragSourceView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link]
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        FileFolderDropTargetView.updateInternalDragTarget(at: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        _ = FileFolderDropTargetView.performInternalDrop(at: screenPoint, urls: draggedURLs)
        draggedURLs = []
    }
}

private struct DateMetadataCell: View {
    @Binding var text: String
    @State private var isEditing = false
    @State private var isHovering = false
    @FocusState private var focused: Bool

    private var date: Date? {
        MetadataValueFormatter.date(from: text)
    }

    /// La data è considerata scaduta se il suo giorno è precedente a oggi (oggi NON è
    /// scaduto). Le date scadute vengono mostrate in rosso.
    private var isExpired: Bool {
        guard let date else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: date) < calendar.startOfDay(for: Date())
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { date ?? Date() },
            set: { text = MetadataValueFormatter.string(from: $0) }
        )
    }

    var body: some View {
        Group {
            if isEditing {
                // In editing: campo con giorno/mese/anno che scorrono con le frecce. Cliccando
                // fuori (perdita di focus) l'editing termina e resta la sola data.
                DatePicker("", selection: dateBinding, displayedComponents: .date)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .focused($focused)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { isEditing = false }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if text.isEmpty {
                // Cella vuota: un clic imposta la data odierna ed entra in editing.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEditing() }
            } else {
                // A riposo mostra solo la data. Un clic entra in editing. La X per cancellare
                // compare al passaggio del mouse (così a riposo la cella resta pulita).
                HStack(spacing: 4) {
                    Text(MetadataValueFormatter.displayDate(from: text))
                        .foregroundStyle(isExpired ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { beginEditing() }

                    if isHovering {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                .onHover { isHovering = $0 }
            }
        }
    }

    private func beginEditing() {
        if text.isEmpty { text = MetadataValueFormatter.string(from: Date()) }
        isEditing = true
        // Il focus va assegnato dopo che il DatePicker è montato nella gerarchia.
        DispatchQueue.main.async { focused = true }
    }
}

extension MetadataTagColor {
    var swiftUIColor: Color {
        switch self {
        case .gray:
            return .secondary
        case .red:
            return .red
        case .orange:
            return .orange
        case .yellow:
            return .yellow
        case .green:
            return .green
        case .blue:
            return .blue
        case .purple:
            return .purple
        case .pink:
            return .pink
        }
    }

    var foregroundColor: Color {
        switch self {
        case .yellow:
            return .black
        default:
            return .white
        }
    }
}

/// Richiesta di creazione di un nuovo elemento nella cartella corrente (file o cartella).
/// Identifiable per pilotare la sheet.
private struct NewItemRequest: Identifiable {
    let id = UUID()
    let isDirectory: Bool
}

/// Piccola sheet per creare un file o una cartella nella cartella corrente. Per i file
/// propone di default l'estensione ".md" (modificabile). Riusa la closure `createItem`
/// di MainWindowView, che crea l'elemento su disco e ricarica la vista.
private struct NewItemSheet: View {
    let isDirectory: Bool
    let createItem: (String, String, Bool) -> String?
    let dismiss: () -> Void

    @ObservedObject private var loc = LocalizationManager.shared
    @State private var name = ""
    @State private var fileExtension = "md"
    @State private var didFail = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isDirectory ? L("newItem.directoryTitle") : L("newItem.fileTitle"))
                .font(.headline)

            HStack(spacing: 8) {
                TextField(L("common.name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .focused($nameFocused)

                if !isDirectory {
                    Text(".")
                        .foregroundStyle(.secondary)
                    TextField(L("folders.extension"), text: $fileExtension)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            if didFail {
                Label(L("folders.createFailed"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L("common.cancel"), action: dismiss)
                Button(isDirectory ? L("folders.createFolder") : L("folders.createFile")) {
                    if createItem(name, fileExtension, isDirectory) != nil {
                        dismiss()
                    } else {
                        didFail = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { nameFocused = true }
    }
}

private struct RenameItemView: View {
    let item: FileItem
    /// Se `true` il campo mostra e modifica il nome completo (estensione inclusa);
    /// se `false` mostra solo il nome base e l'estensione originale viene preservata.
    let showExtension: Bool
    var rename: (String) -> Void
    var cancel: () -> Void

    @ObservedObject private var loc = LocalizationManager.shared
    @State private var name: String

    init(item: FileItem, showExtension: Bool, rename: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.item = item
        self.showExtension = showExtension
        self.rename = rename
        self.cancel = cancel
        _name = State(initialValue: RenameItemView.displayName(for: item, showExtension: showExtension))
    }

    private static func displayName(for item: FileItem, showExtension: Bool) -> String {
        guard !showExtension, !item.isFolder else { return item.name }
        let ext = item.url.pathExtension
        guard !ext.isEmpty else { return item.name }
        return (item.name as NSString).deletingPathExtension
    }

    private func fullName(from display: String) -> String {
        guard !showExtension, !item.isFolder else { return display }
        let ext = item.url.pathExtension
        guard !ext.isEmpty else { return display }
        return "\(display).\(ext)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("ctx.rename"))
                .font(.headline)

            TextField(L("common.name"), text: $name)

            HStack {
                Spacer()

                Button(L("common.cancel"), action: cancel)

                Button(L("ctx.rename")) {
                    rename(fullName(from: name))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fullName(from: name) == item.name)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
