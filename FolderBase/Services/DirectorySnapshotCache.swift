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
    private var staleKeys: Set<String> = []
    private var clock: UInt64 = 0
    private let capacity: Int
    private let itemCapacity: Int
    private var cachedItemCount = 0

    /// Il limite per numero di snapshot evita troppe entry; quello pesato per numero di righe
    /// impedisce che poche directory enormi trattengano centinaia di migliaia di `FileItem`.
    init(capacity: Int = 120, itemCapacity: Int = 50_000) {
        self.capacity = max(5, capacity)
        self.itemCapacity = max(1, itemCapacity)
    }

    func snapshot(for url: URL, allowStale: Bool = false) -> DirectorySnapshot? {
        let key = url.standardizedFileURL.path
        guard allowStale || !staleKeys.contains(key) else { return nil }
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.lastAccess = clock
        entries[key] = entry
        return entry.snapshot
    }

    func store(_ items: [FileItem], for url: URL) {
        let key = url.standardizedFileURL.path
        clock &+= 1
        cachedItemCount -= entries[key]?.snapshot.items.count ?? 0
        entries[key] = Entry(
            snapshot: DirectorySnapshot(items: items, loadedAt: Date()),
            lastAccess: clock
        )
        cachedItemCount += items.count
        staleKeys.remove(key)
        trimIfNeeded()
    }

    func invalidate(paths: [String]) {
        guard !paths.isEmpty else { return }
        let normalized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for key in entries.keys where normalized.contains(where: { changed in
            let parent = URL(fileURLWithPath: changed).deletingLastPathComponent().standardizedFileURL.path
            return key == changed || key == parent || key.hasPrefix(changed + "/")
        }) {
            staleKeys.insert(key)
        }
        lastInvalidatedPaths = normalized
        invalidationGeneration &+= 1
    }

    func invalidateAll() {
        entries.removeAll()
        staleKeys.removeAll()
        cachedItemCount = 0
        lastInvalidatedPaths = []
        invalidationGeneration &+= 1
    }

    private func trimIfNeeded() {
        guard entries.count > capacity || (cachedItemCount > itemCapacity && entries.count > 1) else { return }
        let oldestKeys = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }.map(\.key)
        for key in oldestKeys {
            guard entries.count > capacity || (cachedItemCount > itemCapacity && entries.count > 1) else { break }
            if let removed = entries.removeValue(forKey: key) {
                cachedItemCount -= removed.snapshot.items.count
                staleKeys.remove(key)
            }
        }
    }
}
