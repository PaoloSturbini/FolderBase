import SwiftUI

/// Albero espandibile delle sottocartelle a partire da una cartella radice.
/// Ogni nodo (radice inclusa) usa ESATTAMENTE la stessa riga, così la spaziatura è uniforme.
/// Il percorso della cartella selezionata si auto-espande. Trascinando file su un nodo
/// li si sposta in quella cartella.
struct DirectoryTreeView: View {
    let rootURL: URL
    let selectedFolderURL: URL?
    let fontSize: Double
    let refreshToken: UUID
    let onSelect: (URL) -> Void
    let onMoveItems: ([String], URL) -> Void

    var body: some View {
        DirectoryNodeView(
            url: rootURL,
            depth: 0,
            selectedFolderURL: selectedFolderURL,
            fontSize: fontSize,
            refreshToken: refreshToken,
            onSelect: onSelect,
            onMoveItems: onMoveItems
        )
        .id(rootURL.path)
    }
}

private struct DirectoryNodeView: View {
    let url: URL
    let depth: Int
    let selectedFolderURL: URL?
    let fontSize: Double
    let refreshToken: UUID
    let onSelect: (URL) -> Void
    let onMoveItems: ([String], URL) -> Void

    @State private var isExpanded = false
    @State private var children: [URL] = []
    @State private var didLoad = false
    @State private var isDropTargeted = false

    private var isSelected: Bool {
        selectedFolderURL?.standardizedFileURL.path == url.standardizedFileURL.path
    }

    /// Vero se la cartella selezionata è questa o una sua discendente.
    private var containsSelection: Bool {
        guard let selected = selectedFolderURL?.standardizedFileURL.path else { return false }
        let base = url.standardizedFileURL.path
        return selected == base || selected.hasPrefix(base + "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row

            if isExpanded {
                ForEach(children, id: \.path) { child in
                    DirectoryNodeView(
                        url: child,
                        depth: depth + 1,
                        selectedFolderURL: selectedFolderURL,
                        fontSize: fontSize,
                        refreshToken: refreshToken,
                        onSelect: onSelect,
                        onMoveItems: onMoveItems
                    )
                }
            }
        }
        .onAppear { autoExpandIfNeeded() }
        .onChange(of: refreshToken) { reload() }
        .onChange(of: selectedFolderURL) { autoExpandIfNeeded() }
    }

    private var row: some View {
        HStack(spacing: 4) {
            Button {
                toggleExpand()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: max(fontSize - 4, 8)))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .opacity(didLoad && children.isEmpty ? 0 : 1)
            }
            .buttonStyle(.plain)

            Button {
                onSelect(url)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "folder.fill" : "folder")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(url.lastPathComponent)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: fontSize))
        .padding(.vertical, 3)
        .padding(.trailing, 6)
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (isDropTargeted ? Color.accentColor.opacity(0.10) : Color.clear))
        )
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { paths, _ in
            onMoveItems(paths, url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private func toggleExpand() {
        isExpanded.toggle()
        if isExpanded { loadChildrenIfNeeded() }
    }

    /// La radice parte aperta; i nodi lungo il percorso selezionato si espandono da soli.
    /// Senza animazione, per non far "scivolare" l'albero durante la navigazione.
    private func autoExpandIfNeeded() {
        if depth == 0 || containsSelection {
            if !isExpanded {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isExpanded = true }
            }
            loadChildrenIfNeeded()
        }
    }

    private func reload() {
        didLoad = false
        if isExpanded { loadChildrenIfNeeded() }
    }

    private func loadChildrenIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        children = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
