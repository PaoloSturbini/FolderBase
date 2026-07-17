import XCTest
@testable import FolderBase

final class FileBrowserPerformanceTests: XCTestCase {
    func testSmallDirectoryUsesOneDetailedPublication() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBasePreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("large.dat")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 1, count: 4096)))

        let preview = try FileBrowserService().previewOfDirectory(at: directory)

        XCTAssertFalse(preview.needsEnrichment)
        XCTAssertEqual(preview.items.count, 1)
        XCTAssertEqual(preview.items[0].size, 4096)
        XCTAssertNotEqual(preview.items[0].created, .distantPast)
    }

    func testLargeDirectoryKeepsLightweightFirstPaint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBaseLargePreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("large.dat")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 1, count: 4096)))

        let preview = try FileBrowserService().previewOfDirectory(at: directory, detailedThreshold: 0)

        XCTAssertTrue(preview.needsEnrichment)
        XCTAssertNil(preview.items[0].size)
        XCTAssertEqual(preview.items[0].created, .distantPast)
    }
}
