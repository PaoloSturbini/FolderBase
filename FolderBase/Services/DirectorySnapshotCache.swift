import Foundation

struct DirectorySnapshot: Sendable {
    let items: [FileItem]
    let loadedAt: Date

    var childDirectories: [URL] { items.lazy.filter(\.isFolder).map(\.url) }
}

/// Cache LRU condivisa da tabella e albero. Back/Forward può mostrare subito lo snapshot già
/// visitato, mentre una lettura aggiornata viene eseguita in background.
@MainActor
final class DirectorySnapshotCache: ObservableObject {
    @Published private(set) var invalidationGeneration = 0
    @Published private(set) var lastInvalidatedPaths: [String] = []

    private struct Entry {
        var snapshot: DirectorySnapshot
        var lastAccess: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private let capacity: Int

    init(capacity: Int = 40) { self.capacity = max(5, capacity) }

    func snapshot(for url: URL) -> DirectorySnapshot? {
        let key = url.standardizedFileURL.path
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.lastAccess = clock
        entries[key] = entry
        return entry.snapshot
    }

    func store(_ items: [FileItem], for url: URL) {
        clock &+= 1
        entries[url.standardizedFileURL.path] = Entry(
            snapshot: DirectorySnapshot(items: items, loadedAt: Date()),
            lastAccess: clock
        )
        trimIfNeeded()
    }

    func invalidate(paths: [String]) {
        guard !paths.isEmpty else { return }
        let normalized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for key in entries.keys where normalized.contains(where: { changed in
            key == changed || key.hasPrefix(changed + "/") || changed.hasPrefix(key + "/")
        }) {
            entries[key] = nil
        }
        lastInvalidatedPaths = normalized
        invalidationGeneration &+= 1
    }

    func invalidateAll() {
        entries.removeAll()
        lastInvalidatedPaths = []
        invalidationGeneration &+= 1
    }

    private func trimIfNeeded() {
        guard entries.count > capacity else { return }
        let excess = entries.count - capacity
        for key in entries.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }).prefix(excess).map(\.key) {
            entries[key] = nil
        }
    }
}
