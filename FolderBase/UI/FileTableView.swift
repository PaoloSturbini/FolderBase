import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileTableView: View {
    @Binding var items: [FileItem]
    @ObservedObject var metadataStore: MetadataStore

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
    let trashItems: ([FileItem]) -> Void
    let isLoading: Bool
    let contentFontSize: Double
    let templates: [MetadataTemplate]
    let applyTemplate: (MetadataTemplate) -> Void

    @State private var isAddingField = false
    @State private var fieldPendingEdit: MetadataField?
    @State private var itemPendingRename: FileItem?
    @State private var editingItemID: FileItem.ID?
    @State private var editingName: String = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var quickLookItem: FileItem?
    @State private var isBulkEditing = false
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
            MetadataFieldEditorView(title: "Nuova colonna") { name, kind, options in
                if let selectedFolderURL {
                    metadataStore.addField(folderURL: selectedFolderURL, name: name, kind: kind, options: options)
                }
                isAddingField = false
            } cancel: {
                isAddingField = false
            }
        }
        .sheet(item: $fieldPendingEdit) { field in
            MetadataFieldEditorView(title: "Modifica colonna", field: field) { name, kind, options in
                if let selectedFolderURL {
                    metadataStore.updateField(folderURL: selectedFolderURL, field: field, name: name, kind: kind, options: options)
                }
                fieldPendingEdit = nil
            } cancel: {
                fieldPendingEdit = nil
            }
        }
        .sheet(item: $itemPendingRename) { item in
            RenameItemView(item: item) { newName in
                renameItem(item, newName)
                itemPendingRename = nil
            } cancel: {
                itemPendingRename = nil
            }
        }
        .sheet(item: $quickLookItem) { item in
            QuickLookSheet(url: item.url) { quickLookItem = nil }
        }
        .sheet(isPresented: $isBulkEditing) {
            BulkEditView(fields: metadataFields) { field, value in
                // Lo stato Kanban non si applica alle cartelle.
                let targets = field.kind == .kanban ? selectedItems.filter { !$0.isFolder } : selectedItems
                metadataStore.updateBulk(items: targets, field: field, value: value)
                isBulkEditing = false
            } cancel: {
                isBulkEditing = false
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Scegli una cartella")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Apri Configurazione nella sidebar e aggiungi una cartella.")
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
                    "Nessuna colonna Kanban",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Aggiungi una colonna di tipo Kanban per usare la vista a board.")
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
            .help("Indietro")

            Button(action: goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)
            .help("Avanti")

            Button(action: goUp) {
                Image(systemName: "arrow.up")
            }
            .help("Cartella superiore")

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
            TextField("Cerca", text: $searchText)
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
            if !selection.isEmpty {
                Text("\(selection.count) selez.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    isBulkEditing = true
                } label: {
                    Label("Modifica", systemImage: "square.and.pencil")
                }
                .disabled(metadataFields.isEmpty)
                .help("Imposta un valore metadata sugli elementi selezionati")

                Button(role: .destructive) {
                    trashItems(selectedItems)
                    selection = []
                } label: {
                    Label("Cestina", systemImage: "trash")
                }
                .help("Sposta nel Cestino gli elementi selezionati")

                Divider().frame(height: 20)
            }

            if hasKanbanField {
                Picker("Vista", selection: $viewMode) {
                    Image(systemName: "tablecells").tag(ViewMode.table)
                    Image(systemName: "rectangle.split.3x1").tag(ViewMode.board)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 90)
                .help("Tabella o board Kanban")
            }

            columnsMenu

            Button {
                tableSortOrder = []
            } label: {
                Label("Ordine predefinito", systemImage: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .disabled(tableSortOrder.isEmpty)
            .help("Ripristina ordine predefinito")

            Button {
                isAddingField = true
            } label: {
                Label("Colonna", systemImage: "plus")
            }
            .help("Aggiungi colonna metadata")

            Button(action: exportCSV) {
                Label("Esporta CSV", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .disabled(items.isEmpty)
            .help("Esporta la tabella in CSV")
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
                Button("Mostra tutte le colonne") {
                    showAllColumns()
                }
            }
        } label: {
            Label("Colonne", systemImage: "tablecells")
        }
        .labelStyle(.iconOnly)
        .help("Mostra, nascondi o gestisci le colonne")
    }

    @ViewBuilder
    private func columnSubmenu(_ column: ColumnDescriptor) -> some View {
        if column.id == "name" {
            Button {
            } label: {
                Label("Nome (sempre visibile)", systemImage: "checkmark")
            }
            .disabled(true)
        } else {
            Menu(column.title) {
                let isHidden = hiddenColumnIDs.contains(column.id)
                Button {
                    toggleColumnVisibility(column.id)
                } label: {
                    Label(isHidden ? "Mostra colonna" : "Nascondi colonna", systemImage: isHidden ? "eye" : "eye.slash")
                }

                if case .metadata(let field) = column.kind {
                    Divider()

                    Button {
                        fieldPendingEdit = field
                    } label: {
                        Label("Modifica…", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        if let selectedFolderURL {
                            metadataStore.removeField(folderURL: selectedFolderURL, field: field)
                            var set = hiddenByFolder[folderKey] ?? []
                            set.remove(field.id)
                            hiddenByFolder[folderKey] = set.isEmpty ? nil : set
                        }
                    } label: {
                        Label("Elimina colonna", systemImage: "trash")
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
                Text("Nessun template — creane uno in Configurazione")
            } else {
                Section("Applica template") {
                    ForEach(templates) { template in
                        Button {
                            applyTemplate(template)
                        } label: {
                            Label("\(template.name) (\(template.fields.count) colonne)", systemImage: "rectangle.stack")
                        }
                    }
                }
            }
        } label: {
            Label("Applica template", systemImage: "rectangle.stack.badge.plus")
        }
        .labelStyle(.iconOnly)
        .help("Genera le colonne di questa cartella da un template")
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

    /// Indice metadata [fieldID: [itemID: value]], costruito una volta e riusato per
    /// ordinamento, filtro e ricerca (evita scansioni ripetute durante il render).
    private var metadataIndex: [String: [String: String]] {
        var index: [String: [String: String]] = [:]
        for field in metadataFields {
            var perItem: [String: String] = [:]
            for item in items {
                let value = metadataStore.value(for: item, field: field)
                if !value.isEmpty { perItem[item.id] = value }
            }
            index[field.id] = perItem
        }
        return index
    }

    private var filteredItems: [FileItem] {
        let index = metadataIndex
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return items.filter { item in
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

    private var visibleItems: [FileItem] {
        let base = filteredItems
        guard let comparator = tableSortOrder.first else { return base }
        return base.sorted { comparator.compare($0, $1) == .orderedAscending }
    }

    private var selectedItems: [FileItem] {
        items.filter { selection.contains($0.id) }
    }

    /// Tutte le colonne (standard + metadata), comprese quelle nascoste.
    private var allColumns: [ColumnDescriptor] {
        var result: [ColumnDescriptor] = [
            ColumnDescriptor(id: "name", title: "Nome", kind: .name, minWidth: 160, idealWidth: 320),
            ColumnDescriptor(id: "size", title: "Dimensioni", kind: .size, minWidth: 80, idealWidth: 110),
            ColumnDescriptor(id: "type", title: "Tipo", kind: .type, minWidth: 90, idealWidth: 170),
            ColumnDescriptor(id: "created", title: "Creato", kind: .created, minWidth: 120, idealWidth: 160)
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
        let index = metadataIndex
        return Table(visibleItems, selection: $selection, sortOrder: $tableSortOrder, columnCustomization: $columnCustomization) {
            TableColumnForEach(visibleColumns) { column in
                TableColumn(column.title, sortUsing: sortComparator(for: column, index: index)) { item in
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
    }

    @ViewBuilder
    private func rowContextMenu(for ids: Set<FileItem.ID>) -> some View {
        let targets = items.filter { ids.contains($0.id) }

        if let single = targets.first, targets.count == 1 {
            Button {
                openItem(single)
            } label: {
                Label("Apri", systemImage: single.isFolder ? "folder" : "doc")
            }

            Button {
                quickLookItem = single
            } label: {
                Label("Anteprima rapida", systemImage: "eye")
            }

            Button {
                revealInFinder([single])
            } label: {
                Label("Mostra nel Finder", systemImage: "magnifyingglass")
            }

            Divider()

            Button {
                copyToPasteboard([single])
            } label: {
                Label("Copia", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)

            Button {
                itemPendingRename = single
            } label: {
                Label("Rinomina", systemImage: "pencil")
            }

            Button {
                moveItem(single)
            } label: {
                Label("Sposta…", systemImage: "folder")
            }

            if !metadataFields.isEmpty {
                Button {
                    selection = [single.id]
                    isBulkEditing = true
                } label: {
                    Label("Imposta metadata…", systemImage: "square.and.pencil")
                }
            }

            Divider()

            Button(role: .destructive) {
                trashItems([single])
                selection.remove(single.id)
            } label: {
                Label("Sposta nel Cestino", systemImage: "trash")
            }
        } else if !targets.isEmpty {
            Button {
                copyToPasteboard(targets)
            } label: {
                Label("Copia (\(targets.count))", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)

            Button {
                revealInFinder(targets)
            } label: {
                Label("Mostra nel Finder", systemImage: "magnifyingglass")
            }

            if !metadataFields.isEmpty {
                Button {
                    isBulkEditing = true
                } label: {
                    Label("Imposta metadata su \(targets.count) elementi…", systemImage: "square.and.pencil")
                }
            }

            Divider()

            Button(role: .destructive) {
                trashItems(targets)
                selection = []
            } label: {
                Label("Sposta nel Cestino (\(targets.count))", systemImage: "trash")
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
    /// Clic singolo sul nome → rinomina sul posto (TextField in linea); doppio clic →
    /// apre l'elemento (cartella: entra nella sottocartella; file: app predefinita).
    /// Durante la modifica niente tap/drag, così i clic vanno al campo di testo.
    @ViewBuilder
    private func nameCell(_ item: FileItem) -> some View {
        let label = nameLabel(item)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

        if editingItemID == item.id {
            label
        } else {
            label
                .help(item.isFolder ? "Doppio clic per aprire la cartella · clic singolo per rinominare" : "Doppio clic per aprire con l'app predefinita · clic singolo per rinominare")
                .draggable(item.url)
                .onTapGesture(count: 2) { openItem(item) }
                .onTapGesture(count: 1) { beginRename(item) }
        }
    }

    @ViewBuilder
    private func nameLabel(_ item: FileItem) -> some View {
        let iconSide = max(contentFontSize + 3, 16)
        HStack(spacing: 8) {
            Image(nsImage: FileIconProvider.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSide, height: iconSide)

            if editingItemID == item.id {
                TextField("Nome", text: $editingName)
                    .textFieldStyle(.plain)
                    .focused($nameFieldFocused)
                    .onSubmit { commitRename(item) }
                    .onExitCommand { cancelRename() }
                    .onChange(of: nameFieldFocused) { _, focused in
                        if !focused { commitRename(item) }
                    }
            } else {
                Text(item.name)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private func beginRename(_ item: FileItem) {
        editingName = item.name
        editingItemID = item.id
        nameFieldFocused = true
    }

    private func commitRename(_ item: FileItem) {
        guard editingItemID == item.id else { return }
        editingItemID = nil
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != item.name {
            renameItem(item, trimmed)
        }
    }

    private func cancelRename() {
        editingItemID = nil
    }

    @ViewBuilder
    private func metadataCell(for item: FileItem, field: MetadataField) -> some View {
        switch field.kind {
        case .text:
            NoteTextCell(text: valueBinding(for: item, field: field))
        case .number:
            NumberMetadataCell(text: valueBinding(for: item, field: field))
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
                TextField("Percorso o URL", text: valueBinding(for: item, field: field))
                    .textFieldStyle(.plain)

                Button {
                    chooseLink(for: item, field: field)
                } label: {
                    Image(systemName: "link.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Scegli file o cartella")

                Button {
                    chooseWikiLink(for: item, field: field)
                } label: {
                    Image(systemName: "note.text.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Collega nota come wiki link")

                Button {
                    openLink(for: item, field: field)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .disabled(metadataStore.value(for: item, field: field).isEmpty)
                .help("Apri link")
            }
        }
    }

    private func selectCell(for item: FileItem, field: MetadataField) -> some View {
        ZStack(alignment: .leading) {
            Picker("", selection: valueBinding(for: item, field: field)) {
                Text("<vuoto>").tag("")
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
        var header = ["Nome", "Dimensioni", "Tipo", "Creato"]
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

    private func minWidth(for field: MetadataField) -> CGFloat {
        switch field.kind {
        case .text:
            return 240
        case .number:
            return 70
        case .date:
            return 120
        case .kanban, .select:
            return 110
        case .link:
            return 160
        }
    }

    // MARK: - Links

    private func chooseLink(for item: FileItem, field: MetadataField) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Collega"

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
        panel.prompt = "Collega nota"

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

private struct NoteTextCell: View {
    @Binding var text: String
    @State private var isHovering = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .onHover { hovering in
                isHovering = hovering && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                ScrollView {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(width: 360)
                .frame(minHeight: 80, maxHeight: 220)
            }
    }
}

private struct NumberMetadataCell: View {
    @Binding var text: String

    var body: some View {
        // Nessun placeholder: una cella vuota appena creata non mostra nulla.
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
    }
}

private struct DateMetadataCell: View {
    @Binding var text: String

    private var dateBinding: Binding<Date> {
        Binding(
            get: { MetadataValueFormatter.date(from: text) ?? Date() },
            set: { text = MetadataValueFormatter.string(from: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            if text.isEmpty {
                // Cella vuota appena creata: non mostra nulla. Un clic imposta la data odierna
                // e fa apparire il selettore.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        text = MetadataValueFormatter.string(from: Date())
                    }
            } else {
                DatePicker("", selection: dateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)

                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Rimuovi data")

                Spacer(minLength: 0)
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

private struct BulkEditView: View {
    let fields: [MetadataField]
    var apply: (MetadataField, String) -> Void
    var cancel: () -> Void

    @State private var selectedFieldID: String = ""
    @State private var textValue = ""
    @State private var dateValue = Date()

    private var selectedField: MetadataField? {
        fields.first { $0.id == selectedFieldID } ?? fields.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Imposta metadata sulla selezione")
                .font(.headline)

            Picker("Colonna", selection: $selectedFieldID) {
                ForEach(fields) { field in
                    Text(field.name).tag(field.id)
                }
            }

            if let field = selectedField {
                valueEditor(for: field)
            }

            HStack {
                Spacer()
                Button("Annulla", action: cancel)
                Button("Applica") {
                    if let field = selectedField {
                        apply(field, resolvedValue(for: field))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedField == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if selectedFieldID.isEmpty { selectedFieldID = fields.first?.id ?? "" }
        }
    }

    @ViewBuilder
    private func valueEditor(for field: MetadataField) -> some View {
        switch field.kind {
        case .kanban, .select:
            Picker("Valore", selection: $textValue) {
                Text("<vuoto>").tag("")
                ForEach(field.options) { option in
                    Text(option.label).tag(option.label)
                }
            }
        case .date:
            DatePicker("Valore", selection: $dateValue, displayedComponents: .date)
        case .number:
            TextField("Valore numerico", text: $textValue)
                .multilineTextAlignment(.trailing)
        case .text, .link:
            TextField("Valore", text: $textValue)
        }
    }

    private func resolvedValue(for field: MetadataField) -> String {
        switch field.kind {
        case .date:
            return MetadataValueFormatter.string(from: dateValue)
        default:
            return textValue
        }
    }
}

private struct RenameItemView: View {
    let item: FileItem
    var rename: (String) -> Void
    var cancel: () -> Void

    @State private var name: String

    init(item: FileItem, rename: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.item = item
        self.rename = rename
        self.cancel = cancel
        _name = State(initialValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rinomina")
                .font(.headline)

            TextField("Nome", text: $name)

            HStack {
                Spacer()

                Button("Annulla", action: cancel)

                Button("Rinomina") {
                    rename(name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == item.name)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
