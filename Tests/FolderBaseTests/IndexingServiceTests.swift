import XCTest
@testable import FolderBase

final class IndexingServiceTests: XCTestCase {
    @MainActor
    func testSeparatedIndexStoresANewFileWithoutMetadataFilesTable() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBaseSeparatedIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let document = support.appendingPathComponent("nuovo.md")
        try "Testo del nuovo documento".write(to: document, atomically: true, encoding: .utf8)

        let store = MetadataStore(supportURLOverride: support)
        let item = try XCTUnwrap(IndexingService.fileItem(for: document))
        let hash = try XCTUnwrap(IndexingService.changeHash(for: document))
        await store.storeExtractedText(for: item, text: "Testo del nuovo documento", ocrUsed: false, hash: hash)

        let storedText = await store.extractedText(for: item.identity)
        let storedHash = await store.contentHash(for: item.identity)
        XCTAssertEqual(storedText, "Testo del nuovo documento")
        XCTAssertEqual(storedHash, hash)
    }

    func testChunkerSplitsLongTextWithoutSentenceSeparators() {
        let chunks = TextChunker.chunks(from: String(repeating: "a", count: 2_100), targetChars: 800)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.count), [800, 800, 500])
    }

    func testPartialEmbeddingBatchIsReportedAsFailure() async {
        let text = String(repeating: "Prima frase abbastanza lunga. ", count: 50)
            + String(repeating: "Seconda frase abbastanza lunga. ", count: 50)
        let build = await IndexingService.buildChunkVectors(
            from: text,
            embedder: PartialEmbedder()
        )

        XCTAssertGreaterThan(build.chunkCount, 1)
        XCTAssertGreaterThan(build.vectors.count, 0)
        XCTAssertLessThan(build.vectors.count, build.chunkCount)
        XCTAssertTrue(build.embedderFailed)
    }

}

private struct PartialEmbedder: TextEmbedder {
    func embed(_ text: String) async -> EmbeddingResult? {
        EmbeddingResult(providerID: "partial-test", vector: [1])
    }

    func embedBatch(_ texts: [String]) async -> [EmbeddingResult?] {
        texts.enumerated().map { index, _ in
            index == texts.count - 1 ? nil : EmbeddingResult(providerID: "partial-test", vector: [1])
        }
    }
}
