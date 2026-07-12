import XCTest
@testable import FolderBase

final class TextExtractorTests: XCTestCase {
    func testExtractsUTF8PlainText() throws {
        let url = temporaryTextURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Caffè — UTF-8".utf8).write(to: url)

        let result = TextExtractor.extractText(from: url)

        XCTAssertEqual(result?.text, "Caffè — UTF-8")
        XCTAssertEqual(result?.ocrUsed, false)
    }

    func testExtractsLatin1PlainTextFallback() throws {
        let url = temporaryTextURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes: [UInt8] = [0x43, 0x61, 0x66, 0x66, 0xE8] // "Caffè" in ISO Latin-1
        try Data(bytes).write(to: url)

        let result = TextExtractor.extractText(from: url)

        XCTAssertEqual(result?.text, "Caffè")
        XCTAssertEqual(result?.ocrUsed, false)
    }

    private func temporaryTextURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
    }
}
