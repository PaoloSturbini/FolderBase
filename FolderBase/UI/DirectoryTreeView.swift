import SwiftUI

/// Albero espandibile delle sottocartelle a partire da una cartella radice.
/// Ogni nodo (radice inclusa) usa ESATTAMENTE la stessa riga, così la spaziatura è uniforme.
/// Il percorso della cartella selezionata si auto-espande. Trascinando file su un nodo
/// li si sposta in quella cartella.
struct DirectoryTreeView: View {
    let rootURL: URL
    let selectedFolderURL: URL?
    let fontSize: Double
    let onSelect: (URL) -> Void
    let onMoveItems: ([String], URL) -> Void
    let onRemoveRoot: (URL) -> Void
    @ObservedObject var directoryCache: DirectorySnapshotCache

    var body: some View {
        DirectoryNodeView(
            url: rootURL,
            depth: 0,
            selectedFolderURL: selectedFolderURL,
            fontSize: fontSize,
            onSelect: onSelect,
            onMoveItems: onMoveItems,
            onRemoveRoot: onRemoveRoot,
            directoryCache: directoryCache
        )
        .id(rootURL.path)
    }
}

private struct DirectoryNodeView: View {
    let url: URL
    let depth: Int
    let selectedFolderURL: URL?
    let fontSize: Double
    let onSelect: (URL) -> Void
    let onMoveItems: ([String], URL) -> Void
    let onRemoveRoot: (URL) -> Void
    @ObservedObject var directoryCache: DirectorySnapshotCache

    @State private var isExpanded = false
    @State private var children: [URL] = []
    @State private var didLoad = false
    @State private var isDropTargeted = false
    @AppStorage(AppAccentColor.storageKey) private var appAccentRaw = AppAccentColor.blue.rawValue
    @AppStorage(AppAccentColor.customHexKey) private var appAccentCustomHex = ""
    private var accent: Color { AppAccentColor.color(forRaw: appAccentRaw, customHex: appAccentCustomHex) }

    private var isSelected: Bool {
        let selectedPath = selectedFolderURL?.standardizedFileURL.path
        let nodePath = url.standardizedFileURL.path
        if depth == 0, let selectedPath {
            return selectedPath == nodePath || selectedPath.hasPrefix(nodePath + "/")
        }
        // La barra azzurra identifica sempre la radice gestita dell'albero corrente.
        // La sottocartella selezionata resta riconoscibile perché il suo percorso è aperto,
        // senza creare una seconda evidenziazione concorrente.
        return false
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
                        onSelect: onSelect,
                        onMoveItems: onMoveItems,
                        onRemoveRoot: onRemoveRoot,
                        directoryCache: directoryCache
                    )
                }
            }
        }
        .onAppear { autoExpandIfNeeded() }
        .onChange(of: directoryCache.invalidationGeneration) {
            let nodePath = url.standardizedFileURL.path
            guard directoryCache.lastInvalidatedPaths.isEmpty || directoryCache.lastInvalidatedPaths.contains(where: {
                $0 == nodePath || $0.hasPrefix(nodePath + "/") || nodePath.hasPrefix($0 + "/")
            }) else { return }
            reload()
        }
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
                        .foregroundStyle(isSelected ? accent : .secondary)
                    Text(url.lastPathComponent)
                        .foregroundStyle(isSelected ? accent : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if depth == 0 {
                Button {
                    onRemoveRoot(url)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L("sidebar.removeFolder"))
            }
        }
        .font(.system(size: fontSize))
        .padding(.vertical, 3)
        .padding(.trailing, 6)
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? accent.opacity(0.15) : (isDropTargeted ? accent.opacity(0.10) : Color.clear))
        )
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            onMoveItems(urls.map(\.path), url)
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

    /// Legge le sottocartelle su un thread di background: su cartelle grandi o volumi
    /// di rete la lettura sincrona bloccava il main thread a ogni espansione del nodo.
    private func loadChildrenIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        if let cached = directoryCache.snapshot(for: url) {
            children = cached.childDirectories
            return
        }

        let targetURL = url
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? FileBrowserService().contentsOfDirectory(at: targetURL, showHiddenFiles: false)
            }.value ?? []
            guard url == targetURL else { return }
            directoryCache.store(loaded, for: targetURL)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                children = loaded.lazy.filter(\.isFolder).map(\.url)
            }
        }
    }
}
