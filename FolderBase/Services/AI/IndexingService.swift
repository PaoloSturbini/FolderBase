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
    /// File per cui l'EMBEDDING è fallito nell'ultima esecuzione (motore non raggiungibile o in
    /// errore): il testo è stato salvato ma i vettori no. Serve alla UI per NON fallire in
    /// silenzio — prima l'indicizzazione "finiva" senza dire che i vettori mancavano.
    @Published private(set) var embeddingFailures = 0
    /// Nomi dei file il cui embedding è fallito nell'ultima esecuzione (limitati, per la UI).
    @Published private(set) var embeddingFailedFiles: [String] = []
    /// Diagnosi calcolata a fine indicizzazione (solo se ci sono fallimenti): distingue un motore
    /// non raggiungibile (problema di servizio/configurazione, NON dei file) da un problema dei
    /// singoli file (il motore risponde ma quei contenuti non sono stati embeddati).
    @Published private(set) var embeddingFailureDiagnosis: EmbeddingFailureDiagnosis?

    enum EmbeddingFailureDiagnosis: Equatable {
        case engineUnreachable(detail: String)
        case fileSpecific
    }

    /// Quanti nomi di file falliti conservare per mostrarli nella UI.
    private let maxReportedFailedFiles = 20

    /// File oltre questa dimensione vengono saltati (leggerli interi non ha senso per la ricerca).
    private let maxFileSize = 50 * 1024 * 1024
    /// Limite di sicurezza al numero di file enumerati in modo ricorsivo.
    private let maxRecursiveFiles = 20000
    /// Limite intenzionalmente conservativo: OCR ed embedding possono entrambi essere onerosi.
    /// Le scritture restano serializzate dal consumer sul `MainActor`/database actor.
    private let maxConcurrentFiles = 3

    private var task: Task<Void, Never>?
    private var activeRunID: UUID?

    func cancel() {
        activeRunID = nil
        task?.cancel()
        task = nil
        isIndexing = false
        progress = nil
    }

    /// Indicizza i file (non le cartelle) della lista fornita — es. la cartella corrente (flat).
    func index(items: [FileItem], store: MetadataStore) {
        guard !isIndexing else { return }
        let exclusions = AIExclusionPolicy.excludedPaths()
        let files = items.filter { !$0.isFolder && !AIExclusionPolicy.isExcluded($0.url, excludedPaths: exclusions) }
        guard !files.isEmpty else { return }

        isIndexing = true
        progress = Progress(processed: 0, total: files.count)
        let embedder = EmbeddingEngine.active()
        let runID = UUID()
        activeRunID = runID
        task = Task { [weak self] in
            await self?.runLoop(files: files, store: store, embedder: embedder)
            self?.finish(runID: runID)
        }
    }

    /// Indicizza ricorsivamente una cartella e tutte le sue sottocartelle.
    func indexRecursively(root: URL, store: MetadataStore) {
        guard !isIndexing else { return }
        isIndexing = true
        progress = Progress(processed: 0, total: 0)   // total 0 → "analisi in corso"
        let limit = maxRecursiveFiles
        let embedder = EmbeddingEngine.active()
        let exclusions = AIExclusionPolicy.excludedPaths(forRoot: root)
        let runID = UUID()
        activeRunID = runID
        task = Task { [weak self] in
            let scan = Task.detached(priority: .utility) {
                Self.fileItems(under: root, limit: limit, contentOnly: true, excludedPaths: exclusions)
            }
            let files = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard let self, !Task.isCancelled else { self?.finish(runID: runID); return }
            await self.runLoop(files: files, store: store, embedder: embedder)
            self.finish(runID: runID)
        }
    }

    /// Garantisce che un file scelto esplicitamente per la chat sia disponibile nell'indice.
    /// È utile per file nuovi in una sottocartella dopo l'ultima indicizzazione della radice.
    @discardableResult
    func ensureIndexed(item: FileItem, store: MetadataStore) async -> Bool {
        let currentHash = Self.changeHash(for: item.url)
        let storedHash = await store.contentHash(for: item.identity)
        if currentHash != nil, currentHash == storedHash,
           await store.extractedText(for: item.identity) != nil {
            return true
        }

        // Se è in corso l'indicizzazione della radice, non scartare silenziosamente la richiesta
        // della chat. Attendi quel lavoro e verifica di nuovo il file; se non è stato incluso,
        // indicizzalo subito come operazione singola.
        if isIndexing {
            await task?.value
            let refreshedHash = Self.changeHash(for: item.url)
            let refreshedStoredHash = await store.contentHash(for: item.identity)
            let refreshedText = await store.extractedText(for: item.identity)
            if refreshedHash != nil,
               refreshedHash == refreshedStoredHash,
               refreshedText != nil {
                return true
            }
        }
        guard !isIndexing, !item.isFolder, TextExtractor.isIndexableCandidate(item.url) else { return false }

        isIndexing = true
        progress = Progress(processed: 0, total: 1)
        let runID = UUID()
        activeRunID = runID
        await runLoop(files: [item], store: store, embedder: EmbeddingEngine.active())
        finish(runID: runID)
        return await store.extractedText(for: item.identity) != nil
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
        let exclusions = AIExclusionPolicy.excludedPaths(forRoot: root)
        let fingerprints = await Task.detached(priority: .utility) {
            Self.fingerprints(under: root, limit: limit, contentOnly: true, excludedPaths: exclusions)
        }.value
        guard !fingerprints.isEmpty else { return .notIndexed }

        let indexed = await store.indexedHashes()
        // File senza testo estraibile (es. .xls legacy, .html vuoti, immagini senza testo): sono
        // stati processati, non c'è altro da fare → vanno contati come "coperti", altrimenti
        // tengono la cartella arancione per sempre pur essendo a posto.
        let unsupported = await store.unsupportedHashes()
        var eligibleTotal = 0
        var upToDate = 0
        for fingerprint in fingerprints {
            let identity = fingerprint.identity
            if unsupported[identity] == fingerprint.hash {
                // Elaborato ma privo di testo: non fa parte del totale indicizzabile.
                continue
            }
            eligibleTotal += 1
            // Il testo correttamente estratto è già un indice completo per ricerca e chat FTS.
            // Un embedding fallito viene segnalato separatamente, ma non deve lasciare per sempre
            // la cartella arancione né provocare reindicizzazioni infinite dello stesso testo.
            if indexed[identity] == fingerprint.hash { upToDate += 1 }
        }

        if eligibleTotal == 0 { return .notIndexed }
        let total = eligibleTotal
        // Anche un solo file nuovo o cambiato rende lo stato non aggiornato: una tolleranza
        // percentuale faceva apparire verdi archivi grandi pur lasciando fuori documenti recenti.
        return upToDate == total ? .upToDate(files: total) : .stale(indexed: upToDate, total: total)
    }

    /// Diagnostica gli elementi che mantengono una cartella in stato "Da aggiornare".
    /// Usata dalla verifica e mantenuta separata dalla UI per poter testare casi reali.
    func missingIndexableFiles(root: URL, store: MetadataStore) async -> [URL] {
        let exclusions = AIExclusionPolicy.excludedPaths(forRoot: root)
        let limit = maxRecursiveFiles
        let items = await Task.detached(priority: .utility) {
            Self.fileItems(under: root, limit: limit, contentOnly: true, excludedPaths: exclusions)
        }.value
        let indexed = await store.indexedHashes()
        let unsupported = await store.unsupportedHashes()
        return items.compactMap { item in
            guard let hash = Self.changeHash(for: item.url) else { return item.url }
            if unsupported[item.identity] == hash { return nil }
            return indexed[item.identity] == hash ? nil : item.url
        }
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

    private func finish(runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        isIndexing = false
        progress = nil
        task = nil
    }

    private func runLoop(files rawFiles: [FileItem], store: MetadataStore, embedder: TextEmbedder) async {
        // Salta a monte i file da cui non si ricava testo (video, archivi, binari…): non ha senso
        // tentarne l'estrazione. L'enumerazione ricorsiva li ha già filtrati; questo copre anche
        // l'indicizzazione "flat" della cartella corrente, i cui item arrivano dalla tabella.
        let files = rawFiles.filter { TextExtractor.isIndexableCandidate($0.url) }
        var total = files.count
        progress = Progress(processed: 0, total: total)
        guard total > 0 else { return }
        embeddingFailures = 0
        embeddingFailedFiles = []
        embeddingFailureDiagnosis = nil
        var processed = 0
        // Prefisso del motore attivo: un file è "a posto" solo se ha i vettori di QUESTO motore
        // (altrimenti va reindicizzato — es. dopo un cambio provider).
        let providerPrefix = Self.activeProviderPrefix()

        await withTaskGroup(of: PreparedFile.self) { group in
            var nextIndex = 0
            var inFlight = 0

            func enqueue(_ plan: FilePlan) {
                group.addTask(priority: .utility) {
                    await Self.prepare(plan, embedder: embedder)
                }
                inFlight += 1
            }

            // Il producer consulta lo stato SQLite in modo seriale; solo estrazione/OCR/embedding
            // entrano nel gruppo limitato. Il consumer effettua ugualmente un commit alla volta.
            while nextIndex < files.count || inFlight > 0 {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                while nextIndex < files.count && inFlight < maxConcurrentFiles {
                    let item = files[nextIndex]
                    nextIndex += 1
                    let hash = Self.changeHash(for: item.url)
                    let effectiveHash = hash ?? UUID().uuidString
                    let storedHash = hash == nil ? nil : await store.contentHash(for: item.identity)
                    let upToDate = hash != nil && storedHash == hash
                    if upToDate, await store.hasVectors(for: item.identity, providerPrefix: providerPrefix) {
                        processed += 1
                        progress = Progress(processed: processed, total: total)
                    } else {
                        let existingText = upToDate ? await store.extractedText(for: item.identity) : nil
                        enqueue(FilePlan(item: item, hash: effectiveHash, existingText: existingText, maxFileSize: maxFileSize))
                    }
                }
                guard inFlight > 0, let prepared = await group.next() else { continue }
                inFlight -= 1
                if Task.isCancelled { group.cancelAll(); break }
                if await commit(prepared, store: store) {
                    processed += 1
                } else {
                    // Dopo il tentativo sappiamo che il file non contiene testo indicizzabile:
                    // rimuovilo anche dal denominatore, così il totale finale coincide con quello
                    // mostrato dal ricalcolo dello stato e il progresso può arrivare al 100%.
                    total = max(processed, total - 1)
                }
                progress = Progress(processed: processed, total: total)
            }
        }

        // Con dei fallimenti, interroga il motore UNA volta per capire di chi è la colpa:
        // se non risponde il problema è il motore (i file sono a posto), altrimenti sono
        // i singoli file. La UI usa questa diagnosi per un messaggio non ambiguo.
        if !Task.isCancelled, embeddingFailures > 0 {
            switch await EmbeddingEngine.healthCheck() {
            case .ok:
                embeddingFailureDiagnosis = .fileSpecific
            case let .unreachable(detail):
                embeddingFailureDiagnosis = .engineUnreachable(detail: detail)
            }
        }
    }

    private struct FilePlan: Sendable {
        let item: FileItem
        let hash: String
        let existingText: String?
        let maxFileSize: Int
    }

    private enum PreparedFile: Sendable {
        case vectorsOnly(item: FileItem, build: ChunkBuild)
        case indexed(item: FileItem, hash: String, extracted: ExtractedText, build: ChunkBuild)
        case unsupported(item: FileItem, hash: String)
    }

    nonisolated private static func prepare(_ plan: FilePlan, embedder: TextEmbedder) async -> PreparedFile {
        if let text = plan.existingText {
            return .vectorsOnly(item: plan.item, build: await buildChunkVectors(from: text, embedder: embedder))
        }
        if Task.isCancelled { return .unsupported(item: plan.item, hash: plan.hash) }
        let size = (try? plan.item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= plan.maxFileSize,
              let extracted = TextExtractor.extractText(from: plan.item.url),
              !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unsupported(item: plan.item, hash: plan.hash)
        }
        let build = await buildChunkVectors(from: extracted.text, embedder: embedder)
        return .indexed(item: plan.item, hash: plan.hash, extracted: extracted, build: build)
    }

    /// Ritorna true se il file contiene testo e fa quindi parte del totale indicizzabile finale.
    private func commit(_ prepared: PreparedFile, store: MetadataStore) async -> Bool {
        switch prepared {
        case let .vectorsOnly(item, build):
            if !build.embedderFailed { await store.replaceChunks(for: item.identity, chunks: build.vectors) }
            else { recordEmbeddingFailure(fileName: item.name) }
            return true
        case let .indexed(item, hash, extracted, build):
            if !build.embedderFailed {
                await store.storeIndexedContent(for: item, text: extracted.text, ocrUsed: extracted.ocrUsed, hash: hash, chunks: build.vectors)
            } else {
                await store.storeExtractedText(for: item, text: extracted.text, ocrUsed: extracted.ocrUsed, hash: hash)
                recordEmbeddingFailure(fileName: item.name)
            }
            return true
        case let .unsupported(item, hash):
            await store.markContentUnsupported(for: item, hash: hash)
            return false
        }
    }

    private func recordEmbeddingFailure(fileName: String) {
        embeddingFailures += 1
        if embeddingFailedFiles.count < maxReportedFailedFiles {
            embeddingFailedFiles.append(fileName)
        }
    }

    /// Esito della costruzione dei vettori di un file: i vettori riusciti e quanti chunk c'erano.
    /// `embedderFailed` = almeno un chunk non è stato embeddato. Un risultato parziale non deve
    /// sostituire un indice completo né far apparire il file aggiornato.
    struct ChunkBuild: Sendable {
        let vectors: [ChunkVector]
        let chunkCount: Int
        var embedderFailed: Bool { vectors.count != chunkCount }
    }

    /// Chunk del testo + embedding (in BATCH: una richiesta sola per i provider di rete). Eseguita
    /// su thread di background (`nonisolated`).
    nonisolated static func buildChunkVectors(from text: String, embedder: TextEmbedder) async -> ChunkBuild {
        let chunks = TextChunker.chunks(from: text)
        guard !chunks.isEmpty else { return ChunkBuild(vectors: [], chunkCount: 0) }

        let embeddings = await embedder.embedBatch(chunks)
        var result: [ChunkVector] = []
        for (index, embedding) in embeddings.enumerated() where index < chunks.count {
            guard let embedding else { continue }
            result.append((ordinal: index, text: chunks[index], providerID: embedding.providerID, vector: embedding.vector))
        }
        return ChunkBuild(vectors: result, chunkCount: chunks.count)
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
    /// - Parameter contentOnly: se `true`, include solo i file da cui è plausibile estrarre testo
    ///   (vedi `TextExtractor.isIndexableCandidate`). Usato dalla pipeline di indicizzazione per non
    ///   accodare né contare file inutili (video, archivi, binari…). La ricerca per nome lascia il
    ///   default `false`, così continua a trovare TUTTI i file del sottoalbero.
    nonisolated static func indexableURLs(
        under root: URL,
        limit: Int,
        contentOnly: Bool = false,
        excludedPaths: [String] = AIExclusionPolicy.excludedPaths()
    ) -> [URL] {
        guard !FileSystemPolicy.isInTrash(root),
              !AIExclusionPolicy.isExcluded(root, excludedPaths: excludedPaths) else { return [] }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            if AIExclusionPolicy.isExcluded(url, excludedPaths: excludedPaths) {
                enumerator.skipDescendants()
                continue
            }
            if FileSystemPolicy.isInTrash(url) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
            if values?.isPackage == true {
                enumerator.skipDescendants()
                if indexablePackageExtensions.contains(url.pathExtension.lowercased()) {
                    urls.append(url)   // pacchetti iWork: sempre candidati (gestiti via anteprima)
                }
            } else if values?.isRegularFile == true {
                if !contentOnly || TextExtractor.isIndexableCandidate(url) { urls.append(url) }
            }
            if urls.count >= limit { break }
        }
        return urls
    }

    nonisolated static func fileItems(
        under root: URL,
        limit: Int,
        contentOnly: Bool = false,
        excludedPaths: [String] = AIExclusionPolicy.excludedPaths()
    ) -> [FileItem] {
        indexableURLs(
            under: root, limit: limit, contentOnly: contentOnly, excludedPaths: excludedPaths
        ).compactMap { fileItem(for: $0) }
    }

    nonisolated static func fileItem(for url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileResourceIdentifierKey, .volumeIdentifierKey, .creationDateKey, .fileSizeKey]) else { return nil }
        let identity = MetadataStore.identity(for: url, resourceValues: values)
        let name = url.lastPathComponent
        let type = url.pathExtension.uppercased()
        return FileItem(
            identity: identity,
            url: url,
            name: name,
            type: type,
            created: values.creationDate ?? .distantPast,
            size: Int64(values.fileSize ?? 0),
            isFolder: false,
            sortNameKey: name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
            sortTypeKey: type.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        )
    }

    /// (identità, hash) per ogni file del sottoalbero: usato per calcolare lo stato di copertura.
    /// `contentOnly` allinea il denominatore della copertura all'insieme che l'indicizzazione
    /// processa davvero (solo file con contenuto estraibile).
    nonisolated static func fingerprints(
        under root: URL,
        limit: Int,
        contentOnly: Bool = false,
        excludedPaths: [String] = AIExclusionPolicy.excludedPaths()
    ) -> [(identity: String, hash: String)] {
        indexableURLs(
            under: root, limit: limit, contentOnly: contentOnly, excludedPaths: excludedPaths
        ).compactMap { url in
            guard let hash = changeHash(for: url),
                  let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]) else { return nil }
            return (MetadataStore.identity(for: url, resourceValues: values), hash)
        }
    }
}
