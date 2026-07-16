import XCTest
@testable import FolderBase

final class RecentFoldersStoreTests: XCTestCase {
    func testManualOrderPersistsAndSelectingAgainDoesNotChangeIt() {
        let suite = "RecentFoldersStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = URL(fileURLWithPath: "/tmp/first")
        let second = URL(fileURLWithPath: "/tmp/second")
        let store = RecentFoldersStore(defaults: defaults)
        store.add(first)
        store.add(second)
        store.move(second, offset: -1)
        store.add(second)

        XCTAssertEqual(store.folderURLs.map(\.path), [second.path, first.path])
        XCTAssertEqual(RecentFoldersStore(defaults: defaults).folderURLs.map(\.path), [second.path, first.path])
    }
}
