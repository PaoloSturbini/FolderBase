import SwiftUI

struct MainWindowView: View {
    @StateObject private var metadataStore = MetadataStore()
    @StateObject private var recentFoldersStore = RecentFoldersStore()
    @State private var selectedFolderURL: URL?
    @State private var items: [FileItem] = []
    @State private var errorMessage: String?
    @State private var backStack: [URL] = []
    @State private var forwardStack: [URL] = []
    @AppStorage("sidebarFontSize") private var sidebarFontSize = 14.0
    @AppStorage("contentFontSize") private var contentFontSize = 16.0
    @State private var folderWatcher: FolderWatcher?

    private let fileBrowserService = FileBrowserService()

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedFolderURL: selectedFolderURL,
                recentFolderURLs: recentFoldersStore.folderURLs,
                treeRootURL: selectedFolderURL,
                sidebarFontSize: $sidebarFontSize,
                contentFontSize: $contentFontSize,
                selectFolder: selectFolder,
                removeFolder: removeRecentFolder,
                chooseFolder: chooseFolder,
                navigateTo: navigate
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            FileTableView(
                items: $items,
                metadataStore: metadataStore,
                selectedFolderURL: selectedFolderURL,
                errorMessage: errorMessage,
                canGoBack: !backStack.isEmpty,
                canGoForward: !forwardStack.isEmpty,
                openItem: openItem,
                goBack: goBack,
                goForward: goForward,
                goUp: goUp,
                contentFontSize: contentFontSize
            )
        }
        .frame(minWidth: 1100, minHeight: 650)
        .onAppear(perform: loadInitialFolderIfNeeded)
    }

    private func loadInitialFolderIfNeeded() {
        guard selectedFolderURL == nil,
              let recent = recentFoldersStore.folderURLs.first else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: recent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        selectedFolderURL = recent
        backStack = []
        forwardStack = []
        loadFolder(recent)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scegli"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        selectedFolderURL = url
        recentFoldersStore.add(url)
        backStack = []
        forwardStack = []
        loadFolder(url)
    }

    private func selectFolder(_ url: URL) {
        selectedFolderURL = url
        recentFoldersStore.add(url)
        backStack = []
        forwardStack = []
        loadFolder(url)
    }

    private func removeRecentFolder(_ url: URL) {
        recentFoldersStore.remove(url)

        if selectedFolderURL?.path == url.path {
            selectedFolderURL = nil
            items = []
            errorMessage = nil
            folderWatcher?.stop()
            folderWatcher = nil
        }
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
        loadFolder(url)
    }

    private func goBack() {
        guard let previousURL = backStack.popLast() else { return }

        if let selectedFolderURL {
            forwardStack.append(selectedFolderURL)
        }

        selectedFolderURL = previousURL
        loadFolder(previousURL)
    }

    private func goForward() {
        guard let nextURL = forwardStack.popLast() else { return }

        if let selectedFolderURL {
            backStack.append(selectedFolderURL)
        }

        selectedFolderURL = nextURL
        loadFolder(nextURL)
    }

    private func goUp() {
        guard let selectedFolderURL else { return }
        let parentURL = selectedFolderURL.deletingLastPathComponent()
        guard parentURL.path != selectedFolderURL.path else { return }

        navigate(to: parentURL)
    }

    private func loadFolder(_ url: URL) {
        do {
            items = try fileBrowserService.contentsOfDirectory(at: url, metadataStore: metadataStore)
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }

        startWatching(url)
    }

    private func startWatching(_ url: URL) {
        folderWatcher = FolderWatcher(url: url) {
            reloadCurrentFolder()
        }
    }

    private func reloadCurrentFolder() {
        guard let selectedFolderURL else { return }

        if let refreshed = try? fileBrowserService.contentsOfDirectory(at: selectedFolderURL, metadataStore: metadataStore) {
            items = refreshed
            errorMessage = nil
        }
    }
}
