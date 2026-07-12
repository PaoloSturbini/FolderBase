import XCTest
@testable import FolderBase

final class IndexingServiceTests: XCTestCase {
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
