import SwiftUI

/// Albero espandibile delle sottocartelle a partire da una cartella radice.
/// Cliccando un nodo si naviga la tabella a destra; il chevron espande/comprime.
struct DirectoryTreeView: View {
    let rootURL: URL
    let selectedFolderURL: URL?
    let fontSize: Double
    let onSelect: (URL) -> Void

    var body: some View {
        DirectoryNodeView(
            url: rootURL,
            selectedFolderURL: selectedFolderURL,
            fontSize: fontSize,
            isRoot: true,
            onSelect: onSelect
        )
        .id(rootURL.path)
    }
}

private struct DirectoryNodeView: View {
    let url: URL
    let selectedFolderURL: URL?
    let fontSize: Double
    let isRoot: Bool
    let onSelect: (URL) -> Void

    @State private var isExpanded: Bool
    @State private var children: [URL] = []
    @State private var didLoad = false

    init(url: URL, selectedFolderURL: URL?, fontSize: Double, isRoot: Bool, onSelect: @escaping (URL) -> Void) {
        self.url = url
        self.selectedFolderURL = selectedFolderURL
        self.fontSize = fontSize
        self.isRoot = isRoot
        self.onSelect = onSelect
        _isExpanded = State(initialValue: isRoot)
    }

    private var isSelected: Bool {
        selectedFolderURL?.standardizedFileURL.path == url.standardizedFileURL.path
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(children, id: \.path) { child in
                DirectoryNodeView(
                    url: child,
                    selectedFolderURL: selectedFolderURL,
                    fontSize: fontSize,
                    isRoot: false,
                    onSelect: onSelect
                )
            }
        } label: {
            Button {
                onSelect(url)
            } label: {
                Label(url.lastPathComponent, systemImage: isSelected ? "folder.fill" : "folder")
                    .font(.system(size: fontSize))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .onChange(of: isExpanded) {
            if isExpanded { loadChildrenIfNeeded() }
        }
        .onAppear {
            if isExpanded { loadChildrenIfNeeded() }
        }
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
