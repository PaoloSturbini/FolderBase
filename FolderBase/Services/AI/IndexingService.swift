import Foundation
import Combine

/// Un chunk di testo con il suo embedding, pronto per essere salvato in `chunk_vectors`.
typealias ChunkVector = (ordinal: Int, text: String, providerID: String, vector: [Float])

/// Stato di indicizzazione di una cartella (calcolato come copertura reale del sottoalbero).
enum FolderIndexStatus: Equatable {
    case unknown                          // non ancora calcolato
    case notIndexed                       // nessun file indicizzato → pallino grigio
    case upToDate(files: Int)             // tutto (o quasi) aggiornato → pallino verde
    case stale(indexed: Int, total: Int)  // molti file nuovi/cambiati → pallino arancione
}

/// Orchestra l'indicizzazione del CONTENUTO dei file (Fase 0/1: estrazione testo/OCR, chunk +
/// embedding). Rispetta gli invarianti di performance: l'estrazione/embedding pesanti girano su
/// thread di background (`Task.detached`), le scritture su SQLite avvengono sul main actor
/// (il DB di `MetadataStore` non è condivisibile tra thread). Il progresso è osservabile.
@MainActor
final class IndexingService: ObservableObject {
    struct Progress: Equatable {
        var processed: Int
        var total: Int   // 0 = analisi/enumerazione cartella in corso
    }

    @Published private(set) var isIndexing = false
    @Published private(set) var progress: Progress?

    /// File oltre questa dimensione vengono saltati (leggerli interi non ha senso per la ricerca).
    private let maxFileSize = 50 * 1024 * 1024
    /// Limite di sicurezza al numero di file enumerati in modo ricorsivo.
    private let maxRecursiveFiles = 20000

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isIndexing = false
        progress = nil
    }

    /// Indicizza i file (non le cartelle) della lista fornita — es. la cartella corrente (flat).
    func index(items: [FileItem], store: MetadataStore) {
        guard !isIndexing else { return }
        let files = items.filter { !$0.isFolder }
        guard !files.isEmpty else { return }

        isIndexing = true
        progress = Progress(processed: 0, total: files.count)
        let embedder = EmbeddingEngine.active()
        task = Task { [weak self] in
            await self?.runLoop(files: files, store: store, embedder: embedder)
            self?.finish()
        }
    }

    /// Indicizza ricorsivamente una cartella e tutte le sue sottocartelle.
    func indexRecursively(root: URL, store: MetadataStore) {
        guard !isIndexing else { return }
        isIndexing = true
        progress = Progress(processed: 0, total: 0)   // total 0 → "analisi in corso"
        let limit = maxRecursiveFiles
        let embedder = EmbeddingEngine.active()
        task = Task { [weak self] in
            let files = await Task.detached(priority: .utility) {
                Self.fileItems(under: root, limit: limit)
            }.value
            guard let self, !Task.isCancelled else { self?.finish(); return }
            await self.runLoop(files: files, store: store, embedder: embedder)
            self.finish()
        }
    }

    /// Carica lo stato MEMORIZZATO dell'ultima verifica (istantaneo, nessuna enumerazione).
    /// Ritorna `.unknown` se non è mai stato calcolato per questa cartella.
    func loadStatus(root: URL, store: MetadataStore) -> (status: FolderIndexStatus, checkedAt: Date)? {
        guard let record = store.folderIndexStatus(path: root.path) else { return nil }
        let status: FolderIndexStatus
        switch record.state {
        case "upToDate": status = .upToDate(files: record.total)
        case "stale": status = .stale(indexed: record.indexed, total: record.total)
        default: status = .notIndexed
        }
        return (status, record.checkedAt)
    }

    /// Ricalcola lo stato (enumera il sottoalbero) e lo MEMORIZZA. Da chiamare su richiesta o a
    /// fine indicizzazione, non a ogni apertura della Configurazione.
    @discardableResult
    func recomputeStatus(root: URL, store: MetadataStore) async -> FolderIndexStatus {
        let result = await status(root: root, store: store)
        let state: String
        let indexed: Int
        let total: Int
        switch result {
        case let .upToDate(files):
            (state, indexed, total) = ("upToDate", files, files)
        case let .stale(indexedCount, totalCount):
            (state, indexed, total) = ("stale", indexedCount, totalCount)
        case .notIndexed, .unknown:
            (state, indexed, total) = ("notIndexed", 0, 0)
        }
        store.saveFolderIndexStatus(path: root.path, state: state, indexed: indexed, total: total)
        return result
    }

    /// Calcola lo stato di indicizzazione di una cartella confrontando i file del suo sottoalbero
    /// con quelli già indicizzati e aggiornati nel DB.
    func status(root: URL, store: MetadataStore) async -> FolderIndexStatus {
        let limit = maxRecursiveFiles
        let fingerprints = await Task.detached(priority: .utility) {
            Self.fingerprints(under: root, limit: limit)
        }.value
        guard !fingerprints.isEmpty else { return .notIndexed }

        let indexed = store.indexedHashes()
        // Un file è "aggiornato" solo se il testo è indicizzato (hash combacia) E ha embedding per
        // il MOTORE ATTUALE: cambiando provider i vettori non sono compatibili → il pallino diventa
        // arancione finché non si reindicizza.
        let vectorized = store.identitiesWithVectors(providerPrefix: Self.activeProviderPrefix())
        var textIndexed = 0
        var upToDate = 0
        for fingerprint in fingerprints where indexed[fingerprint.identity] == fingerprint.hash {
            textIndexed += 1
            if vectorized.contains(fingerprint.identity) { upToDate += 1 }
        }

        if textIndexed == 0 { return .notIndexed }
        let total = fingerprints.count
        let changed = total - upToDate
        // Verde se aggiornata (tolleranza ~5%, min 3 file); arancione se molti file nuovi/cambiati
        // o con vettori di un altro motore.
        let threshold = max(3, total / 20)
        return changed <= threshold ? .upToDate(files: total) : .stale(indexed: upToDate, total: total)
    }

    /// Prefisso dei providerID compatibili con il motore attualmente selezionato.
    nonisolated static func activeProviderPrefix() -> String {
        switch AIProviderSettings.provider {
        case .apple: return "apple-nl-"
        case .ollama: return "ollama-\(AIProviderSettings.ollamaModel)"
        case .openai: return "openai-\(AIProviderSettings.openAIModel)"
        }
    }

    // MARK: - Loop di indicizzazione

    private func finish() {
        isIndexing = false
        progress = nil
        task = nil
    }

    private func runLoop(files: [FileItem], store: MetadataStore, embedder: TextEmbedder) async {
        let total = files.count
        progress = Progress(processed: 0, total: total)
        var processed = 0
        // Prefisso del motore attivo: un file è "a posto" solo se ha i vettori di QUESTO motore
        // (altrimenti va reindicizzato — es. dopo un cambio provider).
        let providerPrefix = Self.activeProviderPrefix()

        for item in files {
            if Task.isCancelled { break }

            let url = item.url
            let hash = Self.changeHash(for: url)
            let effectiveHash = hash ?? UUID().uuidString
            let upToDate = (hash != nil && store.contentHash(for: item.identity) == hash)

            if upToDate, store.hasVectors(for: item.identity, providerPrefix: providerPrefix) {
                processed += 1
                progress = Progress(processed: processed, total: total)
                continue
            }

            if upToDate, let existingText = store.extractedText(for: item.identity) {
                // Testo già estratto: rigenera solo gli embedding, senza ri-estrarre né ri-OCR.
                let chunks = await Task.detached(priority: .utility) {
                    await Self.buildChunkVectors(from: existingText, embedder: embedder)
                }.value
                store.replaceChunks(for: item.identity, chunks: chunks)
            } else {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > maxFileSize {
                    store.markContentUnsupported(for: item, hash: effectiveHash)
                } else {
                    let result = await Task.detached(priority: .utility) { () -> (ExtractedText, [ChunkVector])? in
                        guard let extracted = TextExtractor.extractText(from: url),
                              !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        return (extracted, await Self.buildChunkVectors(from: extracted.text, embedder: embedder))
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
            progress = Progress(processed: processed, total: total)
        }
    }

    /// Chunk del testo + embedding di ciascun chunk con l'embedder attivo. Eseguita su thread di
    /// background (`nonisolated`).
    nonisolated static func buildChunkVectors(from text: String, embedder: TextEmbedder) async -> [ChunkVector] {
        let chunks = TextChunker.chunks(from: text)
        var result: [ChunkVector] = []
        for (index, chunk) in chunks.enumerated() {
            guard let embedding = await embedder.embed(chunk) else { continue }
            result.append((ordinal: index, text: chunk, providerID: embedding.providerID, vector: embedding.vector))
        }
        return result
    }

    /// Hash leggero di change-detection: dimensione + data di modifica. Non è crittografico,
    /// serve solo a capire se un file è cambiato dall'ultima indicizzazione.
    nonisolated static func changeHash(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let size = values.fileSize ?? 0
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(size)-\(mtime)"
    }

    // MARK: - Enumerazione ricorsiva

    /// Estensioni a pacchetto (bundle-directory) comunque indicizzabili come singolo file.
    nonisolated static let indexablePackageExtensions: Set<String> = ["pages", "numbers", "key"]

    /// URL dei file indicizzabili sotto `root` (ricorsivo). Salta i file nascosti e non discende
    /// nei pacchetti (i .app ecc. sono ignorati; i pacchetti iWork sono trattati come singolo file).
    nonisolated static func indexableURLs(under root: URL, limit: Int) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
            if values?.isPackage == true {
                enumerator.skipDescendants()
                if indexablePackageExtensions.contains(url.pathExtension.lowercased()) {
                    urls.append(url)
                }
            } else if values?.isRegularFile == true {
                urls.append(url)
            }
            if urls.count >= limit { break }
        }
        return urls
    }

    nonisolated static func fileItems(under root: URL, limit: Int) -> [FileItem] {
        indexableURLs(under: root, limit: limit).compactMap { fileItem(for: $0) }
    }

    nonisolated static func fileItem(for url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileResourceIdentifierKey, .volumeIdentifierKey, .creationDateKey, .fileSizeKey]) else { return nil }
        let identity = MetadataStore.identity(for: url, resourceValues: values)
        return FileItem(
            identity: identity,
            url: url,
            name: url.lastPathComponent,
            type: url.pathExtension.uppercased(),
            created: values.creationDate ?? .distantPast,
            size: Int64(values.fileSize ?? 0),
            isFolder: false
        )
    }

    /// (identità, hash) per ogni file del sottoalbero: usato per calcolare lo stato di copertura.
    nonisolated static func fingerprints(under root: URL, limit: Int) -> [(identity: String, hash: String)] {
        indexableURLs(under: root, limit: limit).compactMap { url in
            guard let hash = changeHash(for: url),
                  let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]) else { return nil }
            return (MetadataStore.identity(for: url, resourceValues: values), hash)
        }
    }
}
