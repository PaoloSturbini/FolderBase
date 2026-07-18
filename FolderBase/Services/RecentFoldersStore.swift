import Foundation

final class RecentFoldersStore: ObservableObject {
    @Published private(set) var folderURLs: [URL] = []

    private let defaults: UserDefaults
    private let key = "recentFolderPaths"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard !folderURLs.contains(where: { $0.path == standardizedURL.path }) else { return }
        folderURLs.append(standardizedURL)
        save()
    }

    /// Sposta una cartella di una posizione mantenendo l'ordine scelto dall'utente persistente.
    func move(_ url: URL, offset: Int) {
        guard let source = folderURLs.firstIndex(where: { $0.path == url.standardizedFileURL.path }) else { return }
        let destination = source + offset
        guard folderURLs.indices.contains(destination) else { return }
        let moved = folderURLs.remove(at: source)
        folderURLs.insert(moved, at: destination)
        save()
    }

    func remove(_ url: URL) {
        folderURLs.removeAll { $0.path == url.standardizedFileURL.path }
        save()
    }

    private func load() {
        let paths = defaults.stringArray(forKey: key) ?? []
        folderURLs = paths.map { URL(fileURLWithPath: $0) }
    }

    func reloadFromDefaults() {
        load()
    }

    private func save() {
        defaults.set(folderURLs.map(\.path), forKey: key)
    }
}
