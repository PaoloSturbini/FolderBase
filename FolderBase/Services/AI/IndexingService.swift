import Foundation
import Combine

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

        task = Task { [weak self] in
            let total = files.count
            var processed = 0

            for item in files {
                if Task.isCancelled { break }

                let url = item.url
                let hash = Self.changeHash(for: url)

                // Skip: file già indicizzato e immutato.
                if let hash, let existing = store.contentHash(for: item.identity), existing == hash {
                    processed += 1
                    self?.progress = Progress(processed: processed, total: total)
                    continue
                }

                let effectiveHash = hash ?? UUID().uuidString
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

                if size > (self?.maxFileSize ?? .max) {
                    store.markContentUnsupported(for: item, hash: effectiveHash)
                } else {
                    // Estrazione pesante fuori dal main actor.
                    let extracted = await Task.detached(priority: .utility) {
                        TextExtractor.extractText(from: url)
                    }.value

                    if let extracted,
                       !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        store.storeExtractedText(for: item, text: extracted.text, ocrUsed: extracted.ocrUsed, hash: effectiveHash)
                    } else {
                        store.markContentUnsupported(for: item, hash: effectiveHash)
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

    /// Hash leggero di change-detection: dimensione + data di modifica. Non è crittografico,
    /// serve solo a capire se un file è cambiato dall'ultima indicizzazione.
    static func changeHash(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let size = values.fileSize ?? 0
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(size)-\(mtime)"
    }
}
