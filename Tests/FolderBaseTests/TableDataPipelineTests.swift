import XCTest
@testable import FolderBase

final class TableDataPipelineTests: XCTestCase {
    private func item(_ name: String, size: Int64 = 0) -> FileItem {
        FileItem(
            identity: name, url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
            type: "TXT", created: .distantPast, size: size, isFolder: false,
            sortNameKey: name.lowercased(), sortTypeKey: "txt"
        )
    }

    func testBuildIndexIncludesMetadataInSearchText() throws {
        let field = MetadataField(id: "status", name: "Status", kind: .select, options: [])
        let source = [item("Alpha"), item("Beta")]
        let metadata = ["Beta": FileMetadata(values: ["status": "Urgente"])]

        let built = try XCTUnwrap(TableDataPipeline.buildIndex(
            source: source, fields: [field], metadata: metadata
        ))

        XCTAssertEqual(built.index["status"]?["Beta"], "Urgente")
        XCTAssertTrue(built.searchText["Beta"]?.contains("urgente") == true)
        XCTAssertEqual(built.sourceIDs, Set(["Alpha", "Beta"]))
    }

    func testVisibleItemsFiltersAndSortsSnapshot() throws {
        let source = [item("Charlie", size: 3), item("Alpha", size: 1), item("Bravo", size: 2)]
        let search = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0.name.lowercased()) })
        var comparator = FileItemSortComparator(columnID: "size")
        comparator.order = .reverse

        let visible = try XCTUnwrap(TableDataPipeline.visibleItems(
            source: source, index: [:], searchTextByID: search, filters: [:], needle: "a",
            similarRank: nil, relevanceRank: nil, comparator: comparator
        ))

        XCTAssertEqual(visible.map(\.name), ["Charlie", "Bravo", "Alpha"])
    }

    func testMetadataLoadForNewFolderRequiresFullRebuild() {
        let previousFolderIDs: Set<String> = ["old-a", "old-b"]
        let newFolderIDs: Set<String> = ["new-a", "new-b"]

        XCTAssertTrue(TableDataPipeline.metadataUpdateNeedsFullRebuild(
            changedIDs: newFolderIDs,
            sourceIDs: newFolderIDs,
            cachedSourceIDs: previousFolderIDs
        ))
        XCTAssertFalse(TableDataPipeline.metadataUpdateNeedsFullRebuild(
            changedIDs: ["old-a"],
            sourceIDs: newFolderIDs,
            cachedSourceIDs: previousFolderIDs
        ))
        XCTAssertFalse(TableDataPipeline.metadataUpdateNeedsFullRebuild(
            changedIDs: ["new-a"],
            sourceIDs: newFolderIDs,
            cachedSourceIDs: newFolderIDs
        ))
    }
}
