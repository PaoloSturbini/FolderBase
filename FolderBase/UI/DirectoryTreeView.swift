import AppKit
import SwiftUI

enum DirectoryTreeAction { case copy, rename, move, reveal, markdown, trash }

/// Albero virtualizzato: mantiene un solo elenco piatto delle righe visibili. In questo modo
/// cambiare selezione non ricostruisce ricorsivamente tutti i nodi già visitati.
struct DirectoryTreeView: View {
    let rootURL: URL
    let selectedFolderURL: URL?
    let fontSize: Double
    let onSelect: (URL) -> Void
    let onMoveItems: ([String], URL) -> Void
    let onRemoveRoot: (URL) -> Void
    let configurationRootURL: URL?
    let onAction: (URL, DirectoryTreeAction) -> Void
    let metadataStore: MetadataStore
    let chatService: ChatService
    @ObservedObject var directoryCache: DirectorySnapshotCache
    @Environment(\.openWindow) private var openWindow

    @State private var expandedPaths: Set<String> = []
    @State private var childrenByPath: [String: [URL]] = [:]
    @State private var loadingPaths: Set<String> = []
    @State private var chatPreparationTask: Task<Void, Never>?

    fileprivate struct Row: Identifiable, Equatable {
        let url: URL
        let depth: Int
        let isExpanded: Bool
        let isLoaded: Bool
        let hasChildren: Bool
        var id: String { url.standardizedFileURL.path }
    }

    private var rootPath: String { rootURL.standardizedFileURL.path }

    private var visibleRows: [Row] {
        var result: [Row] = []
        func append(_ url: URL, depth: Int) {
            let path = url.standardizedFileURL.path
            let expanded = expandedPaths.contains(path)
            let children = childrenByPath[path]
            result.append(Row(url: url, depth: depth, isExpanded: expanded, isLoaded: children != nil, hasChildren: children?.isEmpty == false))
            guard expanded, let children = childrenByPath[path] else { return }
            for child in children { append(child, depth: depth + 1) }
        }
        append(rootURL, depth: 0)
        return result
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(visibleRows) { row in
                DirectoryTreeRow(
                    row: row,
                    isSelected: selectedFolderURL?.standardizedFileURL.path == row.id,
                    fontSize: fontSize,
                    onSelect: { onSelect(row.url) },
                    onToggle: { toggle(row.url) },
                    onMoveItems: { onMoveItems($0, row.url) },
                    onRemoveRoot: row.depth == 0 ? { onRemoveRoot(row.url) } : nil,
                    onAction: { action in onAction(row.url, action) },
                    onOpenWindow: openInNewWindow,
                    onChat: { prepareChat(for: row.url) }
                )
                .equatable()
            }
        }
        .onAppear { expandPathToSelection() }
        .onChange(of: selectedFolderURL?.standardizedFileURL.path) { expandPathToSelection() }
        .onChange(of: directoryCache.invalidationGeneration) { reloadInvalidatedBranches() }
    }

    private func openInNewWindow(_ url: URL) {
        openWindow(value: FolderWindowRequest(
            folderPath: url.path,
            configurationRootPath: (configurationRootURL ?? rootURL).path
        ))
    }

    private func prepareChat(for folder: URL) {
        chatPreparationTask?.cancel()
        let label = "\(L("chat.scope.folder")): \(folder.lastPathComponent)"
        chatPreparationTask = Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                Set(IndexingService.fileItems(under: folder, limit: 20_000).map(\.identity))
            }.value
            guard !Task.isCancelled else { return }
            chatService.configure(candidates: candidates, scopeLabel: label)
            ChatWindowPresenter.show(chatService: chatService, store: metadataStore, focusedFile: nil)
        }
    }

    private func toggle(_ url: URL) {
        let path = url.standardizedFileURL.path
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
            loadChildren(of: url)
        }
    }

    private func expandPathToSelection() {
        expandedPaths.insert(rootPath)
        loadChildren(of: rootURL)
        guard let selected = selectedFolderURL?.standardizedFileURL,
              selected.path == rootPath || selected.path.hasPrefix(rootPath + "/") else { return }

        var ancestors: [URL] = []
        var current = selected
        while current.path != rootPath {
            current = current.deletingLastPathComponent().standardizedFileURL
            guard current.path == rootPath || current.path.hasPrefix(rootPath + "/") else { break }
            ancestors.append(current)
        }
        for ancestor in ancestors.reversed() {
            expandedPaths.insert(ancestor.path)
            loadChildren(of: ancestor)
        }
    }

    private func reloadInvalidatedBranches() {
        let invalidated = directoryCache.lastInvalidatedPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        guard !invalidated.isEmpty else { return }
        for path in expandedPaths where invalidated.contains(where: { changed in
            path == changed || path == URL(fileURLWithPath: changed).deletingLastPathComponent().standardizedFileURL.path
        }) {
            childrenByPath[path] = nil
            loadChildren(of: URL(fileURLWithPath: path))
        }
    }

    private func loadChildren(of url: URL) {
        let path = url.standardizedFileURL.path
        guard childrenByPath[path] == nil, loadingPaths.insert(path).inserted else { return }
        if let cached = directoryCache.snapshot(for: url, allowStale: true) {
            childrenByPath[path] = cached.childDirectories
        }
        Task {
            let preview = try? await DirectoryLoadCoordinator.shared.preview(at: url, showHiddenFiles: false)
            let loaded = preview?.items ?? []
            guard !Task.isCancelled else { return }
            directoryCache.store(loaded, for: url)
            childrenByPath[path] = loaded.lazy.filter(\.isFolder).map(\.url)
            loadingPaths.remove(path)
        }
    }
}

private struct DirectoryTreeRow: View, Equatable {
    let row: DirectoryTreeView.Row
    let isSelected: Bool
    let fontSize: Double
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onMoveItems: ([String]) -> Void
    let onRemoveRoot: (() -> Void)?
    let onAction: (DirectoryTreeAction) -> Void
    let onOpenWindow: (URL) -> Void
    let onChat: () -> Void

    @State private var isDropTargeted = false
    @AppStorage(AIProviderSettings.Keys.enabled) private var aiEnabled = true
    @AppStorage(AppAccentColor.storageKey) private var appAccentRaw = AppAccentColor.blue.rawValue
    @AppStorage(AppAccentColor.customHexKey) private var appAccentCustomHex = ""
    private var accent: Color { AppAccentColor.color(forRaw: appAccentRaw, customHex: appAccentCustomHex) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.isSelected == rhs.isSelected && lhs.fontSize == rhs.fontSize
    }

    var body: some View {
        let content = HStack(spacing: 4) {
            Button(action: onToggle) {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: max(fontSize - 4, 8)))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .opacity(row.isLoaded && !row.hasChildren ? 0 : 1)
            }
            .buttonStyle(.plain)

            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "folder.fill" : "folder")
                        .foregroundStyle(isSelected ? accent : .secondary)
                    Text(row.url.lastPathComponent)
                        .foregroundStyle(isSelected ? accent : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onRemoveRoot {
                Button(action: onRemoveRoot) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: fontSize))
        .padding(.vertical, 3)
        .padding(.trailing, 6)
        .padding(.leading, 6 + CGFloat(row.depth) * 14)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? accent.opacity(0.15) : (isDropTargeted ? accent.opacity(0.10) : .clear)))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in onMoveItems(urls.map(\.path)); return true } isTargeted: { isDropTargeted = $0 }
        .contextMenu { contextMenu }

        if row.depth > 0 { content.draggable(row.url) } else { content }
    }

    @ViewBuilder private var contextMenu: some View {
        Button(action: onSelect) { Label(L("ctx.open"), systemImage: "folder") }
        Button { onAction(.reveal) } label: { Label(L("ctx.revealFinder"), systemImage: "magnifyingglass") }
        Button { showFileInformation(for: row.url) } label: { Label(L("ctx.information"), systemImage: "info.circle") }
        Button { onOpenWindow(row.url) } label: { Label(L("ctx.openNewWindow"), systemImage: "macwindow.badge.plus") }
        if aiEnabled {
            Divider()
            Button(action: onChat) { Label(L("ctx.chatFolder"), systemImage: "bubble.left.and.bubble.right") }
        }
        Divider()
        Button { onAction(.copy) } label: { Label(L("ctx.copy"), systemImage: "doc.on.doc") }
        Button { onAction(.rename) } label: { Label(L("ctx.rename"), systemImage: "pencil") }
        Button { onAction(.move) } label: { Label(L("ctx.move"), systemImage: "folder") }
        Divider()
        Button { onAction(.markdown) } label: { Label(L("ctx.copyMarkdownLink"), systemImage: "link") }
        Divider()
        Button(role: .destructive) { onAction(.trash) } label: { Label(L("ctx.trash"), systemImage: "trash") }
    }
}
