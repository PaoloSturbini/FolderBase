import AppKit
import SwiftUI

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
    let contentFontSize: Double

    @State private var isAddingField = false
    @State private var sortColumnID: String?
    @State private var sortAscending = true
    @State private var columnCustomization = TableColumnCustomization<FileItem>()
    @AppStorage("columnCustomization") private var columnCustomizationData = Data()

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
                table
                    .navigationTitle(selectedFolderURL?.lastPathComponent ?? "FolderBase")
            }
        }
        .sheet(isPresented: $isAddingField) {
            AddMetadataFieldView { name, kind, options in
                if let selectedFolderURL {
                    metadataStore.addField(folderURL: selectedFolderURL, name: name, kind: kind, options: options)
                }
                isAddingField = false
            } cancel: {
                isAddingField = false
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

            Text("Usa il pulsante nella sidebar per caricare file e metadata.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            Divider()
                .frame(height: 20)

            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            Text(selectedFolderURL?.path ?? "")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()

            sortMenu

            columnsMenu

            Button {
                isAddingField = true
            } label: {
                Label("Colonna", systemImage: "plus")
            }
            .help("Aggiungi colonna metadata")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .border(Color(nsColor: .separatorColor), width: 0.5)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(columns) { column in
                Button {
                    setSort(column.id)
                } label: {
                    if sortColumnID == column.id {
                        Label(column.title, systemImage: sortAscending ? "chevron.up" : "chevron.down")
                    } else {
                        Text(column.title)
                    }
                }
            }

            if sortColumnID != nil {
                Divider()
                Button("Ordine predefinito") {
                    sortColumnID = nil
                }
            }
        } label: {
            Label("Ordina", systemImage: "arrow.up.arrow.down")
        }
        .help("Ordina per colonna")
    }

    private var columnsMenu: some View {
        Menu {
            if metadataFields.isEmpty {
                Text("Nessuna colonna metadata")
            } else {
                Section("Elimina colonna") {
                    ForEach(metadataFields) { field in
                        Button(role: .destructive) {
                            if let selectedFolderURL {
                                metadataStore.removeField(folderURL: selectedFolderURL, field: field)
                            }
                        } label: {
                            Label(field.name, systemImage: "trash")
                        }
                    }
                }
            }
        } label: {
            Label("Colonne", systemImage: "slider.horizontal.3")
        }
        .help("Gestisci colonne metadata")
    }

    private var columns: [ColumnDescriptor] {
        var result: [ColumnDescriptor] = [
            ColumnDescriptor(id: "name", title: "Nome", kind: .name, minWidth: 160, idealWidth: 320),
            ColumnDescriptor(id: "size", title: "Dimensioni", kind: .size, minWidth: 80, idealWidth: 110),
            ColumnDescriptor(id: "type", title: "Tipo", kind: .type, minWidth: 90, idealWidth: 170),
            ColumnDescriptor(id: "created", title: "Creato", kind: .created, minWidth: 120, idealWidth: 160)
        ]

        for field in metadataStore.fields(for: selectedFolderURL) {
            result.append(
                ColumnDescriptor(
                    id: field.id,
                    title: field.name,
                    kind: .metadata(field),
                    minWidth: 90,
                    idealWidth: width(for: field)
                )
            )
        }

        return result
    }

    private var displayedItems: [FileItem] {
        guard let sortColumnID else { return items }

        let ascending = items.sorted { lhs, rhs in
            ascendingCompare(lhs, rhs, columnID: sortColumnID)
        }

        return sortAscending ? ascending : Array(ascending.reversed())
    }

    private var table: some View {
        Table(displayedItems, columnCustomization: $columnCustomization) {
            TableColumnForEach(columns) { column in
                TableColumn(column.title) { item in
                    cell(for: item, column: column)
                }
                .width(min: column.minWidth, ideal: column.idealWidth)
                .customizationID(column.id)
            }
        }
        .font(.system(size: contentFontSize))
        .onAppear(perform: restoreColumnCustomization)
        .onChange(of: columnCustomization) {
            persistColumnCustomization()
        }
    }

    private func restoreColumnCustomization() {
        guard !columnCustomizationData.isEmpty,
              let decoded = try? JSONDecoder().decode(TableColumnCustomization<FileItem>.self, from: columnCustomizationData) else { return }
        columnCustomization = decoded
    }

    private func persistColumnCustomization() {
        if let data = try? JSONEncoder().encode(columnCustomization) {
            columnCustomizationData = data
        }
    }

    @ViewBuilder
    private func cell(for item: FileItem, column: ColumnDescriptor) -> some View {
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

    private func nameCell(_ item: FileItem) -> some View {
        Button {
            openItem(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isFolder ? "folder.fill" : "doc.fill")
                    .foregroundStyle(item.isFolder ? .blue : .secondary)
                Text(item.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.isFolder ? "Apri sottocartella" : "Apri con l'app predefinita")
    }

    @ViewBuilder
    private func metadataCell(for item: FileItem, field: MetadataField) -> some View {
        switch field.kind {
        case .text:
            TextField(field.name, text: valueBinding(for: item, field: field))
                .textFieldStyle(.plain)
        case .select:
            Picker(field.name, selection: valueBinding(for: item, field: field)) {
                ForEach(options(for: field), id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
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
                    openLink(for: item, field: field)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .disabled(metadataStore.value(for: item.url, field: field).isEmpty)
                .help("Apri link")
            }
        }
    }

    private func valueBinding(for item: FileItem, field: MetadataField) -> Binding<String> {
        Binding(
            get: {
                metadataStore.value(for: item.url, field: field)
            },
            set: { newValue in
                metadataStore.update(fileURL: item.url, field: field, value: newValue)
            }
        )
    }

    private func options(for field: MetadataField) -> [String] {
        return field.options.isEmpty ? [""] : field.options
    }

    private var metadataFields: [MetadataField] {
        metadataStore.fields(for: selectedFolderURL)
    }

    private func setSort(_ columnID: String) {
        if sortColumnID == columnID {
            sortAscending.toggle()
        } else {
            sortColumnID = columnID
            sortAscending = true
        }
    }

    private func ascendingCompare(_ lhs: FileItem, _ rhs: FileItem, columnID: String) -> Bool {
        switch columnID {
        case "name":
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case "size":
            return (lhs.size ?? -1) < (rhs.size ?? -1)
        case "type":
            return lhs.type.localizedStandardCompare(rhs.type) == .orderedAscending
        case "created":
            return lhs.created < rhs.created
        default:
            guard let field = metadataFields.first(where: { $0.id == columnID }) else {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            let lhsValue = metadataStore.value(for: lhs.url, field: field)
            let rhsValue = metadataStore.value(for: rhs.url, field: field)
            return lhsValue.localizedStandardCompare(rhsValue) == .orderedAscending
        }
    }

    private func width(for field: MetadataField) -> CGFloat {
        switch field.kind {
        case .text:
            return 240
        case .select:
            return 150
        case .link:
            return 320
        }
    }

    private func chooseLink(for item: FileItem, field: MetadataField) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Collega"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        metadataStore.update(fileURL: item.url, field: field, value: url.path)
    }

    private func openLink(for item: FileItem, field: MetadataField) {
        let value = metadataStore.value(for: item.url, field: field)
        guard !value.isEmpty else { return }

        if let url = URL(string: value), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: value))
        }
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

private struct AddMetadataFieldView: View {
    var add: (String, MetadataFieldKind, [String]) -> Void
    var cancel: () -> Void

    @State private var name = ""
    @State private var kind: MetadataFieldKind = .text
    @State private var optionsText = "Todo\nDoing\nDone"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nuova colonna")
                .font(.headline)

            TextField("Nome colonna", text: $name)

            Picker("Tipo", selection: $kind) {
                ForEach(MetadataFieldKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }

            if kind == .select {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Valori")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $optionsText)
                        .font(.body)
                        .frame(height: 110)
                        .border(Color(nsColor: .gridColor))
                }
            }

            HStack {
                Spacer()

                Button("Annulla", action: cancel)

                Button("Aggiungi") {
                    add(name, kind, parsedOptions)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var parsedOptions: [String] {
        optionsText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
