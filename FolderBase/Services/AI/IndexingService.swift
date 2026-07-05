import Foundation
import Combine

/// Un chunk di testo con il suo embedding, pronto per essere salvato in `chunk_vectors`.
typealias ChunkVector = (ordinal: Int, text: String, providerID: String, vector: [Float])

/// Orchestra l'indicizzazione del CONTENUTO dei file di una cartella (Fase 0: estrazione
/// testo/OCR + full-text search). Rispetta gli invarianti di performance del progetto:
/// l'estrazione pesante (OCR, lettura file) gira su thread di background via `Task.detached`,
/// mentre le scritture su SQLite avvengono sul main actor (il DB di `MetadataStore` non è
/// condivisibile tra thread). Il progresso è osservabile dalla UI.
@MainActor
final class IndexingService: ObservableObject {
    struct Progress: Equatable {
        var processed: Int
        var total: Int
    }

    @Published private(set) var isIndexing = false
    @Published private(set) var progress: Progress?

    /// File oltre questa dimensione vengono saltati (marcati "unsupported"): leggerli
    /// interamente in memoria non avrebbe senso per la ricerca testuale.
    private let maxFileSize = 50 * 1024 * 1024

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isIndexing = false
        progress = nil
    }

    /// Indicizza i file (non le cartelle) della lista fornita. I file immutati dall'ultima
    /// indicizzazione (stesso hash size+mtime) vengono saltati.
    func index(items: [FileItem], store: MetadataStore) {
        guard !isIndexing else { return }
        let files = items.filter { !$0.isFolder }
        guard !files.isEmpty else { return }

        isIndexing = true
        progress = Progress(processed: 0, total: files.count)

        let maxSize = maxFileSize
        task = Task { [weak self] in
            let total = files.count
            var processed = 0

            for item in files {
                if Task.isCancelled { break }

                let url = item.url
                let hash = Self.changeHash(for: url)
                let effectiveHash = hash ?? UUID().uuidString
                let upToDate = (hash != nil && store.contentHash(for: item.identity) == hash)

                if upToDate, store.hasVectors(for: item.identity) {
                    // Già indicizzato per testo e per semantica: niente da fare.
                    processed += 1
                    self?.progress = Progress(processed: processed, total: total)
                    continue
                }

                if upToDate, let existingText = store.extractedText(for: item.identity) {
                    // Testo già estratto (es. indicizzato in Fase 0 prima dei vettori): rigenera
                    // SOLO gli embedding, senza ri-estrarre né ri-OCR.
                    let chunks = await Task.detached(priority: .utility) {
                        Self.buildChunkVectors(from: existingText)
                    }.value
                    store.replaceChunks(for: item.identity, chunks: chunks)
                } else {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > maxSize {
                        store.markContentUnsupported(for: item, hash: effectiveHash)
                    } else {
                        // Estrazione + embedding, tutto fuori dal main actor.
                        let result = await Task.detached(priority: .utility) { () -> (ExtractedText, [ChunkVector])? in
                            guard let extracted = TextExtractor.extractText(from: url),
                                  !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                            return (extracted, Self.buildChunkVectors(from: extracted.text))
                        }.value

                        if let (extracted, chunks) = result {
                            store.storeExtractedText(for: item, text: extracted.text, ocrUsed: extracted.ocrUsed, hash: effectiveHash)
                            store.replaceChunks(for: item.identity, chunks: chunks)
                        } else {
                            store.markContentUnsupported(for: item, hash: effectiveHash)
                        }
                    }
                }

                processed += 1
                self?.progress = Progress(processed: processed, total: total)
            }

            self?.isIndexing = false
            self?.progress = nil
            self?.task = nil
        }
    }

    /// Chunk del testo + embedding di ciascun chunk (on-device). Eseguita su thread di background
    /// (`nonisolated`: non tocca lo stato del main actor).
    nonisolated static func buildChunkVectors(from text: String) -> [ChunkVector] {
        let chunks = TextChunker.chunks(from: text)
        var result: [ChunkVector] = []
        for (index, chunk) in chunks.enumerated() {
            guard let embedding = AppleNLEmbedder.shared.embed(chunk) else { continue }
            result.append((ordinal: index, text: chunk, providerID: embedding.providerID, vector: embedding.vector))
        }
        return result
    }

    /// Hash leggero di change-detection: dimensione + data di modifica. Non è crittografico,
    /// serve solo a capire se un file è cambiato dall'ultima indicizzazione.
    static func changeHash(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let size = values.fileSize ?? 0
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(size)-\(mtime)"
    }
}
