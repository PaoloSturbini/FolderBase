import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileTableView: View {
    @Binding var items: [FileItem]
    @ObservedObject var metadataStore: MetadataStore
    @ObservedObject private var loc = LocalizationManager.shared

    let selectedFolderURL: URL?
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
    let templates: [MetadataTemplate]
    let applyTemplate: (MetadataTemplate) -> Void

    @State private var isAddingField = false
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
    @State private var searchText = ""
    @State private var optionFilters: [String: Set<String>] = [:]
    @State private var viewMode: ViewMode = .table
    @State private var boardFieldID: String?
    @State private var columnCustomization = TableColumnCustomization<FileItem>()
    @AppStorage("columnCustomization") private var columnCustomizationData = Data()
    @State private var hiddenByFolder: [String: Set<String>] = [:]
    @AppStorage("hiddenColumnsByFolder") private var hiddenColumnsData = Data()

    /// Cache di indice metadata ed elenco visibile (filtrato+ordinato): ricalcolati SOLO
    /// quando cambiano dati, ricerca, filtri o ordinamento (vedi `refreshDisplayCache`),
    /// non a ogni render della view come accadeva con le computed property.
    @State private var cachedIndex: [String: [String: String]] = [:]
    @State private var cachedVisibleItems: [FileItem] = []

    private enum ViewMode: String, CaseIterable, Identifiable {
        case table
        case board
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
                if !optionFilters.isEmpty || !searchText.isEmpty {
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
            MetadataFieldEditorView(title: L("field.edit"), field: field) { name, kind, options in
                if let selectedFolderURL {
                    metadataStore.updateField(folderURL: selectedFolderURL, field: field, name: name, kind: kind, options: options)
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
        .onAppear { refreshDisplayCache() }
        .onChange(of: items) { refreshDisplayCache() }
        .onChange(of: searchText) { refreshDisplayCache() }
        .onChange(of: optionFilters) { refreshDisplayCache() }
        .onChange(of: tableSortOrder) { refreshDisplayCache() }
        .onChange(of: metadataFields) { refreshDisplayCache() }
        .onChange(of: metadataStore.metadataByFileIdentity) { refreshDisplayCache() }
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
            .hoverDescription(L("nav.back"))

            Button(action: goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)
            .hoverDescription(L("nav.forward"))

            Button(action: goUp) {
                Image(systemName: "arrow.up")
            }
            .hoverDescription(L("nav.up"))

            if metadataFields.isEmpty {
                templateMenu
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

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("table.search"), text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 160)
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

    @ViewBuilder
    private var toolbarButtons: some View {
        HStack(spacing: 8) {
            if hasKanbanField {
                Picker(L("toolbar.view"), selection: $viewMode) {
                    Image(systemName: "tablecells").tag(ViewMode.table)
                    Image(systemName: "rectangle.split.3x1").tag(ViewMode.board)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 90)
                .hoverDescription(L("toolbar.viewHelp"))
            }

            Button {
                newItemRequest = NewItemRequest(isDirectory: false)
            } label: {
                Label(L("toolbar.newFile"), systemImage: "doc.badge.plus")
            }
            .labelStyle(.iconOnly)
            .disabled(selectedFolderURL == nil)
            .hoverDescription(L("toolbar.newFileHelp"))

            Button {
                newItemRequest = NewItemRequest(isDirectory: true)
            } label: {
                Label(L("toolbar.newFolder"), systemImage: "folder.badge.plus")
            }
            .labelStyle(.iconOnly)
            .disabled(selectedFolderURL == nil)
            .hoverDescription(L("toolbar.newFolderHelp"))

            // Icona descrittiva per aggiungere una colonna metadata, a destra di
            // "Nuovo file" e "Nuova cartella" (sostituisce il vecchio pulsante "+ Colonna").
            Button {
                isAddingField = true
            } label: {
                Label(L("toolbar.addColumn"), systemImage: "rectangle.badge.plus")
            }
            .labelStyle(.iconOnly)
            .disabled(selectedFolderURL == nil)
            .hoverDescription(L("toolbar.addColumnHelp"))

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
            .hoverDescription(L("toolbar.defaultOrderHelp"))

            Button(action: exportCSV) {
                Label(L("toolbar.exportCSV"), systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .disabled(items.isEmpty)
            .hoverDescription(L("toolbar.exportCSVHelp"))
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
        .hoverDescription(L("toolbar.columnsHelp"))
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
                            metadataStore.removeField(folderURL: selectedFolderURL, field: field)
                            var set = hiddenByFolder[folderKey] ?? []
                            set.remove(field.id)
                            hiddenByFolder[folderKey] = set.isEmpty ? nil : set
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

    /// Pulsante (in alto a sinistra) per applicare un template a una cartella priva di
    /// struttura FolderBase. Appare solo quando non ci sono ancora colonne metadata.
    private var templateMenu: some View {
        Menu {
            if templates.isEmpty {
                Text(L("templateMenu.empty"))
            } else {
                Section(L("templateMenu.apply")) {
                    ForEach(templates) { template in
                        Button {
                            applyTemplate(template)
                        } label: {
                            Label("\(template.name) (\(template.fields.count) \(L("templateMenu.columnsWord")))", systemImage: "rectangle.stack")
                        }
                    }
                }
            }
        } label: {
            Label(L("templateMenu.apply"), systemImage: "rectangle.stack.badge.plus")
        }
        .labelStyle(.iconOnly)
        .hoverDescription(L("templateMenu.help"))
    }

    // MARK: - Data shaping

    private var metadataFields: [MetadataField] {
        metadataStore.fields(for: selectedFolderURL)
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
    private func refreshDisplayCache() {
        var index: [String: [String: String]] = [:]
        for field in metadataFields {
            var perItem: [String: String] = [:]
            for item in items {
                let value = metadataStore.value(for: item, field: field)
                if !value.isEmpty { perItem[item.id] = value }
            }
            index[field.id] = perItem
        }
        cachedIndex = index

        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [FileItem]

        if optionFilters.isEmpty, needle.isEmpty {
            result = items
        } else {
            result = items.filter { item in
                // Filtri per opzione (AND tra campi, OR tra valori dello stesso campo).
                for (fieldID, labels) in optionFilters where !labels.isEmpty {
                    let value = index[fieldID]?[item.id] ?? ""
                    if !labels.contains(value) { return false }
                }

                guard !needle.isEmpty else { return true }
                if item.name.lowercased().contains(needle) { return true }
                for (_, perItem) in index {
                    if let value = perItem[item.id], value.lowercased().contains(needle) { return true }
                }
                return false
            }
        }

        if let comparator = tableSortOrder.first {
            result.sort { comparator.compare($0, $1) == .orderedAscending }
        }
        cachedVisibleItems = result
    }

    private var selectedItems: [FileItem] {
        items.filter { selection.contains($0.id) }
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
            ColumnDescriptor(id: "name", title: L("col.name"), kind: .name, minWidth: 80, idealWidth: 320),
            ColumnDescriptor(id: "size", title: L("col.size"), kind: .size, minWidth: 50, idealWidth: 110),
            ColumnDescriptor(id: "type", title: L("col.type"), kind: .type, minWidth: 50, idealWidth: 170),
            ColumnDescriptor(id: "created", title: L("col.created"), kind: .created, minWidth: 60, idealWidth: 160)
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
        hiddenByFolder[folderKey] ?? []
    }

    private var table: some View {
        Table(cachedVisibleItems, selection: $selection, sortOrder: $tableSortOrder, columnCustomization: $columnCustomization) {
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
        }
        .font(.system(size: contentFontSize))
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            rowContextMenu(for: ids)
        } primaryAction: { ids in
            // Doppio clic: apre l'elemento.
            if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                openItem(item)
            }
        }
        .onAppear {
            restoreColumnCustomization()
            restoreHiddenColumns()
        }
        .onChange(of: columnCustomization) {
            persistColumnCustomization()
        }
        .onChange(of: hiddenByFolder) {
            persistHiddenColumns()
        }
        // Tasto Invio: rinomina l'elemento selezionato (come nel Finder). Nessun gesto sul
        // nome, quindi la selezione col clic resta nativa e affidabile.
        .onKeyPress(.return) {
            guard editingItemID == nil,
                  selection.count == 1,
                  let id = selection.first,
                  let item = items.first(where: { $0.id == id }) else { return .ignored }
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
        let targets = items.filter { ids.contains($0.id) }

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

            Button(role: .destructive) {
                requestTrash(targets)
            } label: {
                Label("\(L("ctx.trash")) (\(targets.count))", systemImage: "trash")
            }
        }
    }

    private func restoreColumnCustomization() {
        if !columnCustomizationData.isEmpty,
           let decoded = try? JSONDecoder().decode(TableColumnCustomization<FileItem>.self, from: columnCustomizationData) {
            columnCustomization = decoded
        }

        // La visibilità è ora gestita da noi (menù "Colonne"): forziamo visibili tutte le
        // colonne nella personalizzazione nativa, così quelle nascoste in passato col vecchio
        // menù di sistema tornano visibili e non restano blottate.
        for column in allColumns {
            columnCustomization[visibility: column.id] = .visible
        }
    }

    private func persistColumnCustomization() {
        if let data = try? JSONEncoder().encode(columnCustomization) {
            columnCustomizationData = data
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
        var set = hiddenByFolder[folderKey] ?? []
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        hiddenByFolder[folderKey] = set.isEmpty ? nil : set
    }

    private func showAllColumns() {
        hiddenByFolder[folderKey] = nil
    }

    // MARK: - Cells

    /// Altezza riga fissa e compatta (vicina al nativo): garantisce che TUTTE le righe
    /// abbiano la stessa altezza, a prescindere dal contenuto (cartelle, file, celle tag/
    /// data, riga selezionata) e dalle colonne metadata presenti in quella cartella.
    private var rowHeight: CGFloat {
        max(contentFontSize + 9, 22)
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
        } else {
            label
                .help(item.isFolder ? L("name.helpFolder") : L("name.helpFile"))
        }
    }

    @ViewBuilder
    private func nameLabel(_ item: FileItem) -> some View {
        let iconSide = max(contentFontSize + 3, 16)
        HStack(spacing: 8) {
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
            .help(L("name.dragHint"))
        }
    }

    /// URL da trascinare afferrando l'icona di `item`: se `item` fa parte di una selezione
    /// multipla si trascinano tutti gli elementi selezionati (comportamento Finder),
    /// altrimenti solo `item`.
    private func dragURLs(for item: FileItem) -> [URL] {
        if selection.contains(item.id) && selection.count > 1 {
            return items.filter { selection.contains($0.id) }.map(\.url)
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
            EditableTextCell(text: valueBinding(for: item, field: field), showsHoverPreview: true)
        case .number:
            EditableTextCell(text: valueBinding(for: item, field: field), alignment: .trailing, monospacedDigits: true)
        case .date:
            DateMetadataCell(text: valueBinding(for: item, field: field))
        case .kanban:
            // Lo stato Kanban si applica solo ai file, non alle cartelle.
            if item.isFolder {
                Color.clear.frame(maxWidth: .infinity)
            } else {
                selectCell(for: item, field: field)
            }
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
                .help(L("link.chooseFile"))

                Button {
                    chooseWikiLink(for: item, field: field)
                } label: {
                    Image(systemName: "note.text.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(L("link.wiki"))

                Button {
                    openLink(for: item, field: field)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .disabled(metadataStore.value(for: item, field: field).isEmpty)
                .help(L("link.open"))
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
            return 140
        case .kanban, .select:
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
        case .kanban, .select:
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
        } else if let resolvedURL = resolveLocalLink(destination) {
            NSWorkspace.shared.open(resolvedURL)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: destination))
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

    private func resolveLocalLink(_ destination: String) -> URL? {
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

        return findNote(named: destination, under: selectedFolderURL)
    }

    private func findNote(named name: String, under folderURL: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            let stem = url.deletingPathExtension().lastPathComponent
            if stem == name || url.lastPathComponent == name {
                return url
            }
        }

        return nil
    }
}

/// Mostra, al passaggio del mouse, una descrizione dell'elemento in un popover con lo
/// STESSO stile dell'anteprima delle note (vedi `EditableTextCell`): testo semplice su
/// sfondo popover. Sostituisce il tooltip nativo `.help()` sulle icone della barra in alto.
/// Un breve ritardo evita che appaia per semplice sfioramento o che disturbi il clic.
private struct HoverDescription: ViewModifier {
    let text: String
    @State private var isShowing = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering && !text.isEmpty {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if !Task.isCancelled { isShowing = true }
                    }
                } else {
                    isShowing = false
                }
            }
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                Text(text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(12)
            }
    }
}

extension View {
    /// Descrizione a comparsa (hover) in stile "campo note".
    func hoverDescription(_ text: String) -> some View {
        modifier(HoverDescription(text: text))
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
            result = lhs.name.localizedStandardCompare(rhs.name)
        case "size":
            result = compareValues(lhs.size ?? -1, rhs.size ?? -1)
        case "type":
            result = lhs.type.localizedStandardCompare(rhs.type)
        case "created":
            result = compareValues(lhs.created, rhs.created)
        default:
            result = compareMetadata(lhs, rhs)
        }

        let resolved = result == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : result
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

/// NSView che disegna l'icona e, al trascinamento, avvia una `NSDraggingSession` con un
/// `NSDraggingItem` per ogni file (fileURL su pasteboard → il Finder li sposta/copia tutti).
final class FileDragSourceView: NSView {
    var image: NSImage?
    var dragURLsProvider: () -> [URL] = { [] }
    var onClick: () -> Void = {}

    private var mouseDownLocation: NSPoint = .zero
    private var didDrag = false

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
}

private struct DateMetadataCell: View {
    @Binding var text: String
    @State private var isEditing = false

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
            if text.isEmpty {
                // Cella vuota appena creata: non mostra nulla. Un clic imposta la data odierna.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        text = MetadataValueFormatter.string(from: Date())
                    }
            } else {
                // Mostra solo la data (niente frecce né pulsante di rimozione). Rossa se futura.
                // Un clic apre un calendario in popover per modificarla.
                Text(MetadataValueFormatter.displayDate(from: text))
                    .foregroundStyle(isExpired ? Color.red : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { isEditing = true }
                    .popover(isPresented: $isEditing) {
                        DatePicker("", selection: dateBinding, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding()
                    }
            }
        }
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
