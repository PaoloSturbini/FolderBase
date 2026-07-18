import XCTest
@testable import FolderBase

final class AIExclusionPolicyTests: XCTestCase {
    func testFolderExclusionMatchesDescendantsButNotSimilarSibling() {
        let excluded = ["/tmp/project/private"]

        XCTAssertTrue(AIExclusionPolicy.isExcluded(path: "/tmp/project/private", excludedPaths: excluded))
        XCTAssertTrue(AIExclusionPolicy.isExcluded(path: "/tmp/project/private/report.pdf", excludedPaths: excluded))
        XCTAssertFalse(AIExclusionPolicy.isExcluded(path: "/tmp/project/private-copy/report.pdf", excludedPaths: excluded))
    }

    func testEncodingNormalizesAndDeduplicatesPaths() {
        let data = AIExclusionPolicy.encode(["/tmp/project/./private", "/tmp/project/private"])

        XCTAssertEqual(AIExclusionPolicy.decode(data), ["/tmp/project/private"])
    }

    func testSuggestionsFindHiddenAndGeneratedFoldersOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBaseExclusionSuggestions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [".git", "node_modules", "Documenti"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let suggestions = AIExclusionPolicy.suggestions(under: [root], excluding: [])
        let names = Set(suggestions.map { URL(fileURLWithPath: $0.path).lastPathComponent })

        XCTAssertEqual(names, [".git", "node_modules"])
    }

    func testRecursiveEnumerationSkipsExplicitlyExcludedFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBaseExcludedEnumeration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let included = root.appendingPathComponent("included", isDirectory: true)
        let excluded = root.appendingPathComponent("excluded", isDirectory: true)
        try FileManager.default.createDirectory(at: included, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: included.appendingPathComponent("keep.txt").path, contents: Data("ok".utf8)
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: excluded.appendingPathComponent("secret.txt").path, contents: Data("no".utf8)
        ))

        let urls = IndexingService.indexableURLs(
            under: root, limit: 100, excludedPaths: [excluded.path]
        )

        XCTAssertEqual(urls.map(\.lastPathComponent), ["keep.txt"])
    }
}
