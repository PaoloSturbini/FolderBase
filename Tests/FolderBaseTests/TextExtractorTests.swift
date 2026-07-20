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

    func testUnknownBinaryFileIsNotAnIndexableCandidate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(Array("bplist00".utf8) + [0, 1, 2, 3]).write(to: url)

        XCTAssertFalse(TextExtractor.isIndexableCandidate(url))
    }

    func testExtensionlessTextAndEmailAreIndexableCandidates() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let email = plain.appendingPathExtension("eml")
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: email)
        }
        try Data("Documento testuale senza estensione".utf8).write(to: plain)
        try Data("Subject: Test\n\nCorpo della email".utf8).write(to: email)

        XCTAssertTrue(TextExtractor.isIndexableCandidate(plain))
        XCTAssertTrue(TextExtractor.isIndexableCandidate(email))
        XCTAssertTrue(TextExtractor.extractText(from: email)?.text.contains("Corpo della email") == true)
    }


    private func temporaryTextURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
    }
}
