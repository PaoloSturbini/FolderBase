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
}
