import XCTest
@testable import FolderBase

final class DirectorySnapshotCacheTests: XCTestCase {
    @MainActor
    func testInvalidationAffectsOnlyRelatedBranches() {
        let cache = DirectorySnapshotCache(capacity: 10)
        let root = URL(fileURLWithPath: "/tmp/root")
        let child = root.appendingPathComponent("child")
        let other = URL(fileURLWithPath: "/tmp/other")
        cache.store([], for: root)
        cache.store([], for: child)
        cache.store([], for: other)

        cache.invalidate(paths: [child.appendingPathComponent("file.txt").path])

        XCTAssertNotNil(cache.snapshot(for: root))
        XCTAssertNil(cache.snapshot(for: child))
        XCTAssertNotNil(cache.snapshot(for: child, allowStale: true))
        XCTAssertNotNil(cache.snapshot(for: other))

        cache.store([], for: child)
        XCTAssertNotNil(cache.snapshot(for: child))
    }

    @MainActor
    func testLeastRecentlyUsedEntryIsEvicted() {
        let cache = DirectorySnapshotCache(capacity: 5)
        let urls = (0..<6).map { URL(fileURLWithPath: "/tmp/cache-\($0)") }
        for url in urls.prefix(5) { cache.store([], for: url) }
        _ = cache.snapshot(for: urls[0])
        cache.store([], for: urls[5])

        XCTAssertNotNil(cache.snapshot(for: urls[0]))
        XCTAssertNil(cache.snapshot(for: urls[1]))
        XCTAssertNotNil(cache.snapshot(for: urls[5]))
    }

    @MainActor
    func testItemBudgetEvictsHeavyLeastRecentlyUsedSnapshots() {
        let cache = DirectorySnapshotCache(capacity: 10, itemCapacity: 5)
        let first = URL(fileURLWithPath: "/tmp/heavy-first")
        let second = URL(fileURLWithPath: "/tmp/heavy-second")
        let third = URL(fileURLWithPath: "/tmp/heavy-third")

        cache.store(makeItems(count: 3, prefix: "a"), for: first)
        cache.store(makeItems(count: 2, prefix: "b"), for: second)
        cache.store(makeItems(count: 2, prefix: "c"), for: third)

        XCTAssertNil(cache.snapshot(for: first))
        XCTAssertNotNil(cache.snapshot(for: second))
        XCTAssertNotNil(cache.snapshot(for: third))
    }

    private func makeItems(count: Int, prefix: String) -> [FileItem] {
        (0..<count).map { index in
            let name = "\(prefix)-\(index)"
            return FileItem(
                identity: name,
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                name: name,
                type: "TXT",
                created: .distantPast,
                size: 0,
                isFolder: false,
                sortNameKey: name,
                sortTypeKey: "txt"
            )
        }
    }
}
