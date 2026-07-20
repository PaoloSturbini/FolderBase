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

    func testPerRootEncodingKeepsOverlappingFoldersIndependent() {
        let parent = URL(fileURLWithPath: "/tmp/project")
        let nested = URL(fileURLWithPath: "/tmp/project/archive")
        let data = AIExclusionPolicy.encode([
            parent.path: ["/tmp/project/private"],
            nested.path: ["/tmp/project/archive/drafts"]
        ])
        let decoded = AIExclusionPolicy.decodeByRoot(data, knownRoots: [parent, nested])

        XCTAssertEqual(decoded[parent.path], ["/tmp/project/private"])
        XCTAssertEqual(decoded[nested.path], ["/tmp/project/archive/drafts"])
    }

    func testLegacyExclusionsMigrateToMostSpecificKnownRoot() {
        let parent = URL(fileURLWithPath: "/tmp/project")
        let nested = URL(fileURLWithPath: "/tmp/project/archive")
        let legacy = AIExclusionPolicy.encode([
            "/tmp/project/private", "/tmp/project/archive/drafts"
        ])
        let decoded = AIExclusionPolicy.decodeByRoot(legacy, knownRoots: [parent, nested])

        XCTAssertEqual(decoded[parent.path], ["/tmp/project/private"])
        XCTAssertEqual(decoded[nested.path], ["/tmp/project/archive/drafts"])
    }

    func testTopLevelRootsDoNotCreateSeparateIndexesForSubfolders() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let child = URL(fileURLWithPath: "/tmp/project/archive")
        let other = URL(fileURLWithPath: "/tmp/other")

        XCTAssertEqual(
            AIExclusionPolicy.topLevelRoots([child, root, other]).map(\.path),
            [root.path, other.path]
        )
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

    func testRecursiveEnumerationIncludesFilesInDeepSubfolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBaseNestedEnumeration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("one/two/three", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let document = nested.appendingPathComponent("document.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: document.path, contents: Data("nested".utf8)))

        let urls = IndexingService.indexableURLs(under: root, limit: 100, contentOnly: true, excludedPaths: [])

        XCTAssertEqual(urls.map(\.standardizedFileURL.path), [document.standardizedFileURL.path])
    }
}
