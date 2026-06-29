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
        folderURLs.removeAll { $0.path == standardizedURL.path }
        folderURLs.insert(standardizedURL, at: 0)
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

    private func save() {
        defaults.set(folderURLs.map(\.path), forKey: key)
    }
}
