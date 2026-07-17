import Foundation
import SQLite3
import Accelerate
import Combine
import OSLog

struct FileMetadata: Codable, Equatable, Sendable {
    var values: [String: String]

    static let empty = FileMetadata(values: [:])
}

private struct LegacyMetadataDocument: Codable {
    var fieldsByFolder: [String: [MetadataField]]
    var metadataByPath: [String: FileMetadata]
}

/// La connessione SQLite e tutte le cache collegate appartengono al main actor.
/// Le operazioni filesystem/AI costose producono risultati in background e consegnano qui
/// solo gli aggiornamenti da applicare, evitando accessi concorrenti alla stessa connessione.
@MainActor
final class MetadataStore: ObservableObject {
    private static let performanceLog = Logger(subsystem: "com.paolosturbini.folderbase", category: "Performance")
    @Published private(set) var fieldsByFolder: [String: [MetadataField]] = [:] {
        didSet { effectiveFieldsCache.removeAll(keepingCapacity: true) }
    }

    /// Non-@Published: la notifica a SwiftUI è gestita manualmente (vedi
    /// `notifyMetadataChanged`) così le modifiche "per tasto" vengono coalizzate invece
    /// di invalidare l'intera tabella a ogni carattere digitato.
    private(set) var metadataByFileIdentity: [String: FileMetadata] = [:]
    let metadataChanges = PassthroughSubject<Set<String>, Never>()
    /// Evento separato per cambi di schema/colonne. Le viste che mostrano solo valori non
    /// devono osservare l'intero store e ridisegnarsi per ogni mutazione non pertinente.
    let metadataStructureChanges = PassthroughSubject<Void, Never>()

    private let dbURL: URL
    private let indexDBURL: URL
    private let legacyMetadataURL: URL
    private var db: OpaquePointer?
    private var databaseActor: SQLiteDatabaseActor?
    private var indexDatabaseActor: SQLiteDatabaseActor?

    /// Cache di prepared statement riusabili (chiave = SQL) per i percorsi caldi a SQL fisso
    /// come `persistValue`, invocato ad ogni flush di digitazione. Evita la ricompilazione del
    /// bytecode SQLite ad ogni scrittura. Gli statement vengono finalizzati alla chiusura.
    private var statementCache: [String: OpaquePointer] = [:]

    /// Cache path → identity per evitare di calcolare/registrare l'identità sul disco
    /// nei percorsi di sola lettura (chiamati ad ogni render di SwiftUI).
    private var identityCacheByPath: [String: String] = [:]

    /// Scritture su disco posticipate (debounce), indicizzate per chiave file+campo.
    private var pendingWrites: [String: DispatchWorkItem] = [:]
    private var pendingValues: [String: (identity: String, fieldID: String, value: String)] = [:]
    private let writeDebounce: TimeInterval = 0.4

    /// Notifica posticipata a SwiftUI per i cambi metadata (vedi `notifyMetadataChanged`).
    private var pendingChangeNotification: DispatchWorkItem?
    private var pendingChangedIdentities: Set<String> = []
    private let notifyDebounce: TimeInterval = 0.2

    /// Identità già presenti nella tabella `files`: evita di registrare di nuovo file noti.
    private var registeredIdentities: Set<String> = []

    /// Cache di `managedDirectories()`: viene chiamata a ogni navigazione (per
    /// riconfigurare FSEvents) ma il suo contenuto cambia solo quando si registrano,
    /// spostano o eliminano file gestiti.
    private var managedDirectoriesCache: [String]?
    /// Identità richieste dalla vista corrente. I valori metadata vengono caricati solo per
    /// questo working set, invece di materializzare l'intero archivio a ogni refresh.
    private var activeMetadataIdentities: Set<String> = []
    /// Lo schema ereditato cambia solo con una mutazione strutturale, non durante la navigazione.
    /// Evita di ricostruire antenati, collisioni e opzioni a ogni body pass della Table/sidebar.
    private var effectiveFieldsCache: [String: [MetadataField]] = [:]

    init(fileManager: FileManager = .default, supportURLOverride: URL? = nil) {
        let supportURL = supportURLOverride ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderBase", isDirectory: true)

        self.dbURL = supportURL.appendingPathComponent("folderbase.sqlite")
        self.indexDBURL = supportURL.appendingPathComponent("folderbase-index.sqlite")
        self.legacyMetadataURL = supportURL.appendingPathComponent("metadata.json")

        do {
            try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try Self.prepareContentDatabase(at: indexDBURL)
            try openDatabase()
            try migrateSchema()
            try migrateLegacyJSONIfNeeded()
            registeredIdentities = (try? loadRegisteredIdentities()) ?? []
            refreshPublishedState()
            databaseActor = try SQLiteDatabaseActor(url: dbURL)
            configureSeparatedIndex()
        } catch {
            assertionFailure("Failed to initialize metadata store: \(error)")
            fieldsByFolder = [:]
            metadataByFileIdentity = [:]
        }
    }

    deinit {
        // I DispatchWorkItem pendenti trattengono lo store fino all'esecuzione; a questo punto
        // non possono più esistere scritture da scaricare. La chiusura resta sincrona e sicura.
        for statement in statementCache.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    /// Prepara il DB AI separato. Se esiste un indice legacy, la copia avviene in background e
    /// nel frattempo le ricerche continuano a usare il DB storico; al termine il routing passa
    /// atomicamente al nuovo actor.
    private func configureSeparatedIndex() {
        let source = dbURL
        let destination = indexDBURL
        let needsMigration = Self.contentRowCount(at: destination) == 0 && Self.contentRowCount(at: source) > 0
        if !needsMigration {
            try? Self.prepareContentDatabase(at: destination)
            indexDatabaseActor = try? SQLiteDatabaseActor(url: destination)
            return
        }
        Task { [weak self] in
            let migrated = await Task.detached(priority: .utility) {
                (try? Self.migrateContentDatabase(from: source, to: destination)) != nil
            }.value
            guard migrated, let self else { return }
            self.indexDatabaseActor = try? SQLiteDatabaseActor(url: destination)
        }
    }

    private nonisolated static func contentRowCount(at url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(connection); return 0 }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "SELECT count(*) FROM file_content", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { sqlite3_finalize(statement); return 0 }
        defer { sqlite3_finalize(statement) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private nonisolated static func prepareContentDatabase(at url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else { throw StoreError.sqlite(message: "Index DB open failed") }
        defer { sqlite3_close(connection) }
        let sql = """
        PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS file_content (file_identity TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', path TEXT NOT NULL DEFAULT '', extracted_text TEXT, ocr_used INTEGER NOT NULL DEFAULT 0, content_hash TEXT, extracted_at REAL, index_state TEXT NOT NULL DEFAULT 'pending');
        CREATE VIRTUAL TABLE IF NOT EXISTS content_fts USING fts5(file_identity UNINDEXED, name, body, tokenize='unicode61 remove_diacritics 2');
        CREATE TABLE IF NOT EXISTS content_chunks (id INTEGER PRIMARY KEY AUTOINCREMENT, file_identity TEXT NOT NULL, ordinal INTEGER NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_chunks_file ON content_chunks(file_identity);
        CREATE TABLE IF NOT EXISTS chunk_vectors (chunk_id INTEGER PRIMARY KEY, provider_id TEXT NOT NULL, dimension INTEGER NOT NULL, vector BLOB NOT NULL, norm REAL NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS idx_chunk_vectors_provider ON chunk_vectors(provider_id);
        CREATE INDEX IF NOT EXISTS idx_chunk_vectors_provider_dim ON chunk_vectors(provider_id,dimension);
        """
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(message: String(cString: sqlite3_errmsg(connection))) }
    }

    private nonisolated static func migrateContentDatabase(from source: URL, to destination: URL) throws {
        try prepareContentDatabase(at: destination)
        var connection: OpaquePointer?
        guard sqlite3_open(source.path, &connection) == SQLITE_OK, let connection else { throw StoreError.sqlite(message: "Legacy index open failed") }
        defer { sqlite3_close(connection) }
        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "ATTACH DATABASE ? AS separated_index", -1, &attach, nil) == SQLITE_OK else { throw StoreError.sqlite(message: "Index attach failed") }
        sqlite3_bind_text(attach, 1, destination.path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(attach) == SQLITE_DONE else { sqlite3_finalize(attach); throw StoreError.sqlite(message: "Index attach failed") }
        sqlite3_finalize(attach)
        let sql = """
        BEGIN;
        INSERT OR REPLACE INTO separated_index.file_content(file_identity,name,path,extracted_text,ocr_used,content_hash,extracted_at,index_state)
        SELECT c.file_identity,COALESCE(f.name,''),COALESCE(f.last_known_path,''),c.extracted_text,c.ocr_used,c.content_hash,c.extracted_at,c.index_state FROM file_content c LEFT JOIN files f ON f.identity=c.file_identity;
        DELETE FROM separated_index.content_fts;
        INSERT INTO separated_index.content_fts(file_identity,name,body) SELECT file_identity,name,body FROM content_fts;
        INSERT OR REPLACE INTO separated_index.content_chunks(id,file_identity,ordinal,text) SELECT id,file_identity,ordinal,text FROM content_chunks;
        INSERT OR REPLACE INTO separated_index.chunk_vectors(chunk_id,provider_id,dimension,vector,norm) SELECT chunk_id,provider_id,dimension,vector,norm FROM chunk_vectors;
        COMMIT;
        DETACH DATABASE separated_index;
        """
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(message: String(cString: sqlite3_errmsg(connection))) }
    }

    private var contentDatabaseActor: SQLiteDatabaseActor? { indexDatabaseActor ?? databaseActor }

    /// Calcola l'identità stabile di un file SENZA toccare il database.
    /// Usata nei percorsi di sola lettura (es. `fields(for:)`), con cache per path.
    func identity(for fileURL: URL) -> String? {
        let path = fileURL.path
        if let cached = identityCacheByPath[path] { return cached }

        guard let values = try? fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]) else {
            return nil
        }
        let identity = Self.fileIdentity(
            fileIdentifier: Self.stableDescription(values.fileResourceIdentifier),
            volumeIdentifier: Self.stableDescription(values.volumeIdentifier),
            path: path
        )
        identityCacheByPath[path] = identity
        return identity
    }

    @discardableResult
    func registerFile(at fileURL: URL, resourceValues: URLResourceValues? = nil) throws -> String {
        let values = try resourceValues ?? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileResourceIdentifierKey, .volumeIdentifierKey])
        let fileIdentifier = Self.stableDescription(values.fileResourceIdentifier)
        let volumeIdentifier = Self.stableDescription(values.volumeIdentifier)
        let identity = Self.fileIdentity(fileIdentifier: fileIdentifier, volumeIdentifier: volumeIdentifier, path: fileURL.path)
        identityCacheByPath[fileURL.path] = identity

        // Bookmark + dimensione: salvati solo qui (cartelle, file con metadata, elementi
        // spostati) — non nel percorso caldo di navigazione — quindi il costo è trascurabile.
        // Il bookmark è l'àncora autorevole per ritrovare il file dopo spostamenti/rinomini
        // (anche tra volumi) e per distinguere una cancellazione dal riuso di un inode.
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let bookmark = try? fileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

        try execute(
            """
            INSERT INTO files (identity, file_resource_identifier, volume_identifier, bookmark_data, last_known_path, name, is_directory, size, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(identity) DO UPDATE SET
                file_resource_identifier = excluded.file_resource_identifier,
                volume_identifier = excluded.volume_identifier,
                bookmark_data = excluded.bookmark_data,
                last_known_path = excluded.last_known_path,
                name = excluded.name,
                is_directory = excluded.is_directory,
                size = excluded.size,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(identity),
                .text(fileIdentifier),
                .text(volumeIdentifier),
                .blob(bookmark),
                .text(fileURL.path),
                .text(fileURL.lastPathComponent),
                .int((values.isDirectory ?? false) ? 1 : 0),
                .intOptional(size),
                .real(Date().timeIntervalSince1970)
            ]
        )

        if !registeredIdentities.contains(identity) {
            registeredIdentities.insert(identity)
            invalidateManagedDirectoriesCache()
        }
        return identity
    }

    /// Garantisce che il file esista nella tabella `files` prima di scriverne i metadata.
    /// Per i file già noti non fa nulla (evita scritture inutili durante la digitazione).
    private func ensureRegistered(_ item: FileItem) {
        guard !registeredIdentities.contains(item.identity) else { return }
        _ = try? registerFile(at: item.url)
    }

    /// Lettura pura: nessuna scrittura su disco. La cartella viene registrata in fase di
    /// caricamento da `FileBrowserService`, quindi qui basta risolvere l'identità dalla cache.
    func fields(for folderURL: URL?, configurationRootURL: URL? = nil) -> [MetadataField] {
        guard let folderURL else { return [] }
        let rootPath = configurationRootURL?.standardizedFileURL.path ?? folderURL.standardizedFileURL.path
        let cacheKey = rootPath + "\u{1F}" + folderURL.standardizedFileURL.path
        if let cached = effectiveFieldsCache[cacheKey] { return cached }
        var groups: [[MetadataField]] = []
        for url in Self.ancestorURLs(from: configurationRootURL, through: folderURL) {
            guard let folderIdentity = identity(for: url) else { continue }
            groups.append(fieldsByFolder[folderIdentity] ?? [])
        }
        let result = Self.mergeInheritedFields(groups)
        effectiveFieldsCache[cacheKey] = result
        return result
    }

    /// Verifica lo schema effettivamente visibile nella cartella, non soltanto l'esistenza di
    /// campi sulla radice. Serve all'apertura di ogni sottocartella perché confini locali o una
    /// radice appena aggiunta possono interrompere l'ereditarietà del template globale.
    func isTemplateApplied(
        _ template: MetadataTemplate,
        to folderURL: URL,
        configurationRootURL: URL?
    ) -> Bool {
        let effectiveFields = fields(for: folderURL, configurationRootURL: configurationRootURL)
        return template.fields.allSatisfy { expected in
            guard let actual = effectiveFields.first(where: {
                Self.normalizedFieldName($0.name) == Self.normalizedFieldName(expected.name)
                    && $0.kind == expected.kind
            }) else { return false }
            guard expected.kind.usesOptions else { return true }
            let actualLabels = Set(actual.options.map { Self.normalizedFieldName($0.label) })
            return expected.options.allSatisfy { actualLabels.contains(Self.normalizedFieldName($0.label)) }
        }
    }

    static func mergeInheritedFields(_ groups: [[MetadataField]]) -> [MetadataField] {
        var result: [MetadataField] = []
        var claimedNames: Set<String> = []
        for fields in groups {
            let existingByName = Dictionary(uniqueKeysWithValues: result.map { (normalizedFieldName($0.name), $0) })
            let hasIncompatibleCollision = fields.contains { field in
                guard let inherited = existingByName[normalizedFieldName(field.name)] else { return false }
                return !fieldsAreCompatible(inherited: inherited, local: field)
            }
            // Una cartella già organizzata con uno schema incompatibile è un confine: non le
            // imponiamo il template dell'antenato e preserviamo integralmente colonne e valori.
            if hasIncompatibleCollision {
                result = []
                claimedNames = []
            }
            for field in fields {
                let key = normalizedFieldName(field.name)
                guard claimedNames.insert(key).inserted else { continue }
                result.append(field)
            }
        }
        return result
    }

    private nonisolated static func normalizedFieldName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private nonisolated static func fieldsAreCompatible(
        inherited: MetadataField,
        local: MetadataField
    ) -> Bool {
        guard inherited.kind == local.kind else { return false }
        guard inherited.kind.usesOptions else { return true }
        let inheritedLabels = Set(inherited.options.map { normalizedFieldName($0.label) })
        return local.options.allSatisfy { inheritedLabels.contains(normalizedFieldName($0.label)) }
    }

    func ownerURL(of field: MetadataField, folderURL: URL, configurationRootURL: URL?) -> URL {
        for url in Self.ancestorURLs(from: configurationRootURL, through: folderURL) {
            guard let folderIdentity = identity(for: url) else { continue }
            if fieldsByFolder[folderIdentity]?.contains(where: { $0.id == field.id }) == true { return url }
        }
        return folderURL
    }

    private static func ancestorURLs(from rootURL: URL?, through folderURL: URL) -> [URL] {
        let folder = folderURL.standardizedFileURL
        let candidate = rootURL?.standardizedFileURL
        let root = candidate.flatMap {
            folder.path == $0.path || folder.path.hasPrefix($0.path + "/") ? $0 : nil
        } ?? folder
        var urls: [URL] = []
        var current = folder
        while true {
            urls.append(current)
            if current.path == root.path { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path, parent.path.hasPrefix(root.path) else { break }
            current = parent
        }
        return urls.reversed()
    }

    func metadata(for item: FileItem) -> FileMetadata {
        metadataByFileIdentity[item.identity] ?? .empty
    }

    func loadMetadata(for items: [FileItem]) {
        let identities = Set(items.map(\.identity))
        guard identities != activeMetadataIdentities else { return }
        activeMetadataIdentities = identities
        guard let databaseActor else { return }
        Task { [weak self] in
            let loaded = (try? await databaseActor.loadMetadata(identities: identities)) ?? [:]
            guard let self, self.activeMetadataIdentities == identities else { return }
            self.metadataByFileIdentity = loaded
            self.pendingChangedIdentities.formUnion(identities)
            self.notifyMetadataChanged(immediate: true)
        }
    }

    func value(for item: FileItem, field: MetadataField) -> String {
        metadata(for: item).values[field.id] ?? ""
    }

    /// Aggiorna subito lo stato in memoria e posticipa sia la scrittura su disco sia la
    /// notifica a SwiftUI: durante la digitazione la cella attiva resta reattiva (usa il
    /// proprio stato locale) mentre il resto della tabella si aggiorna una sola volta.
    func update(item: FileItem, field: MetadataField, value: String) {
        ensureRegistered(item)
        setInMemoryValue(identity: item.identity, fieldID: field.id, value: value)
        pendingChangedIdentities.insert(item.identity)
        scheduleWrite(identity: item.identity, fieldID: field.id, value: value)
        notifyMetadataChanged()
    }

    /// Notifica SwiftUI che i metadata sono cambiati. Debounced nei percorsi "per tasto"
    /// (una sola invalidazione per pausa di digitazione invece di una per carattere);
    /// immediata per i cambi strutturali (bulk, reload dal DB, riconciliazioni).
    private func notifyMetadataChanged(immediate: Bool = false) {
        pendingChangeNotification?.cancel()
        pendingChangeNotification = nil

        if immediate {
            let changed = pendingChangedIdentities
            pendingChangedIdentities.removeAll()
            if !changed.isEmpty { metadataChanges.send(changed) }
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChangeNotification = nil
            let changed = self.pendingChangedIdentities
            self.pendingChangedIdentities.removeAll()
            if !changed.isEmpty { self.metadataChanges.send(changed) }
        }
        pendingChangeNotification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + notifyDebounce, execute: work)
    }

    /// Assegna lo stesso valore a più elementi in un'unica transazione (modifica in blocco).
    func updateBulk(items: [FileItem], field: MetadataField, value: String) {
        guard !items.isEmpty else { return }
        let changedIdentities = Set(items.map(\.identity))
        // SwiftUI deve sapere che la mutazione sta per avvenire; l'indice della tabella, invece,
        // va aggiornato solo dopo che tutti i nuovi valori sono leggibili in memoria.
        for item in items {
            ensureRegistered(item)
            setInMemoryValue(identity: item.identity, fieldID: field.id, value: value)
            cancelPendingWrite(identity: item.identity, fieldID: field.id)
        }
        metadataChanges.send(changedIdentities)

        let writes = items.map { (identity: $0.identity, fieldID: field.id, value: value) }
        if let databaseActor {
            Task {
                do { try await databaseActor.upsertMetadata(writes) }
                catch { assertionFailure("Failed bulk metadata update: \(error)") }
            }
        }
    }

    private func setInMemoryValue(identity: String, fieldID: String, value: String) {
        var metadata = metadataByFileIdentity[identity] ?? .empty
        metadata.values[fieldID] = value
        metadataByFileIdentity[identity] = metadata
    }

    private func scheduleWrite(identity: String, fieldID: String, value: String) {
        let key = "\(identity)|\(fieldID)"
        pendingWrites[key]?.cancel()
        pendingValues[key] = (identity, fieldID, value)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flushWrite(forKey: key)
        }
        pendingWrites[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDebounce, execute: work)
    }

    private func flushWrite(forKey key: String) {
        pendingWrites[key] = nil
        guard let pending = pendingValues.removeValue(forKey: key) else { return }
        persistValue(identity: pending.identity, fieldID: pending.fieldID, value: pending.value)
    }

    private func cancelPendingWrite(identity: String, fieldID: String) {
        let key = "\(identity)|\(fieldID)"
        pendingWrites[key]?.cancel()
        pendingWrites[key] = nil
        pendingValues[key] = nil
    }

    private func persistValue(identity: String, fieldID: String, value: String) {
        do {
            try executeCached(
                """
                INSERT INTO metadata_values (file_identity, field_id, value)
                VALUES (?, ?, ?)
                ON CONFLICT(file_identity, field_id) DO UPDATE SET value = excluded.value
                """,
                bindings: [.text(identity), .text(fieldID), .text(value)]
            )
        } catch {
            assertionFailure("Failed to persist metadata: \(error)")
        }
    }

    /// Esegue immediatamente tutte le scritture posticipate (es. prima della chiusura).
    func flushPendingWrites() {
        for (_, work) in pendingWrites { work.cancel() }
        pendingWrites.removeAll()

        let values = pendingValues
        pendingValues.removeAll()
        for (_, pending) in values {
            persistValue(identity: pending.identity, fieldID: pending.fieldID, value: pending.value)
        }
    }

    func addField(folderURL: URL, name: String, kind: MetadataFieldKind, options: [MetadataSelectOption]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        do {
            let folderIdentity = try registerFile(at: folderURL)
            let field = MetadataField(
                id: UUID().uuidString,
                name: trimmedName,
                kind: kind,
                options: normalizedOptions(for: kind, options: options)
            )
            let optionsData = try JSONEncoder().encode(field.options)
            let optionsJSON = String(data: optionsData, encoding: .utf8) ?? "[]"

            try execute(
                """
                INSERT INTO metadata_fields (id, folder_identity, name, kind, options_json, position)
                VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(position) + 1 FROM metadata_fields WHERE folder_identity = ?), 0))
                """,
                bindings: [.text(field.id), .text(folderIdentity), .text(field.name), .text(field.kind.rawValue), .text(optionsJSON), .text(folderIdentity)]
            )
            // Aggiornamento incrementale: niente ricarica completa del DB per un solo campo.
            fieldsByFolder[folderIdentity, default: []].append(field)
        } catch {
            assertionFailure("Failed to add metadata field: \(error)")
        }
    }

    /// Applica un template a una cartella creando una colonna per ogni campo definito.
    /// Un'unica transazione e un solo aggiornamento dello stato pubblicato: prima ogni
    /// campo faceva registerFile + INSERT + ricarica completa del DB.
    func applyTemplate(_ template: MetadataTemplate, to folderURL: URL) {
        guard !template.fields.isEmpty else { return }

        do {
            let folderIdentity = try registerFile(at: folderURL)
            var appended: [MetadataField] = []
            var appliedFields: [MetadataField] = []
            var updatedExisting: [MetadataField] = []
            let existingFields = fieldsByFolder[folderIdentity] ?? []

            try execute("BEGIN IMMEDIATE TRANSACTION")
            for templateField in template.fields {
                let trimmedName = templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { continue }
                let propagatedOptions = try mergedPropagatedOptions(
                    for: templateField,
                    below: folderURL
                )

                if let existing = existingFields.first(where: {
                    Self.normalizedFieldName($0.name) == Self.normalizedFieldName(trimmedName)
                }) {
                    // Non duplica una struttura già presente. Un conflitto di tipo rende questa
                    // cartella un confine di propagazione ed è lasciato completamente intatto.
                    if existing.kind == templateField.kind {
                        var adapted = existing
                        adapted.options = propagatedOptions
                        let optionsData = try JSONEncoder().encode(adapted.options)
                        let optionsJSON = String(data: optionsData, encoding: .utf8) ?? "[]"
                        try execute(
                            "UPDATE metadata_fields SET options_json = ? WHERE id = ?",
                            bindings: [.text(optionsJSON), .text(adapted.id)]
                        )
                        appliedFields.append(adapted)
                        updatedExisting.append(adapted)
                    }
                    continue
                }

                let field = MetadataField(
                    id: UUID().uuidString,
                    name: trimmedName,
                    kind: templateField.kind,
                    options: propagatedOptions
                )
                let optionsData = try JSONEncoder().encode(field.options)
                let optionsJSON = String(data: optionsData, encoding: .utf8) ?? "[]"

                try execute(
                    """
                    INSERT INTO metadata_fields (id, folder_identity, name, kind, options_json, position)
                    VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(position) + 1 FROM metadata_fields WHERE folder_identity = ?), 0))
                    """,
                    bindings: [.text(field.id), .text(folderIdentity), .text(field.name), .text(field.kind.rawValue), .text(optionsJSON), .text(folderIdentity)]
                )
                appended.append(field)
                appliedFields.append(field)
            }
            try execute("COMMIT")

            fieldsByFolder[folderIdentity, default: []].append(contentsOf: appended)
            for updated in updatedExisting {
                if let index = fieldsByFolder[folderIdentity]?.firstIndex(where: { $0.id == updated.id }) {
                    fieldsByFolder[folderIdentity]?[index] = updated
                }
            }
            try reconcileCompatibleDescendantFields(
                with: appliedFields,
                below: folderURL,
                excluding: folderIdentity
            )
            metadataStructureChanges.send()
        } catch {
            try? execute("ROLLBACK")
            assertionFailure("Failed to apply template: \(error)")
        }
    }

    /// Rimappa i valori del file/cartella spostato e di tutte le righe registrate nel suo
    /// sottoalbero dagli ID delle colonne di origine agli ID equivalenti della destinazione.
    /// È necessario quando due radici usano lo stesso template ma hanno `metadata_fields.id`
    /// diversi: senza questa migrazione i valori esistono ancora in SQLite ma le nuove colonne
    /// non riescono a vederli.
    func remapMetadataForMove(
        subtreeAt sourceURL: URL,
        from sourceFields: [MetadataField],
        to destinationFields: [MetadataField]
    ) throws {
        flushPendingWrites()
        let pairs: [(MetadataField, MetadataField, [String: String])] = try sourceFields.compactMap { source in
            guard let destination = destinationFields.first(where: {
                Self.normalizedFieldName($0.name) == Self.normalizedFieldName(source.name)
                    && $0.kind == source.kind
            }), source.id != destination.id,
            let valueMapping = try compatibleValueMapping(from: source, to: destination) else { return nil }
            return (source, destination, valueMapping)
        }
        guard !pairs.isEmpty else { return }

        let sourcePath = sourceURL.standardizedFileURL.path
        let descendantPrefix = sourcePath + "/"
        do {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            for (source, destination, valueMapping) in pairs {
                for (oldValue, newValue) in valueMapping where oldValue != newValue {
                    try execute(
                        """
                        UPDATE metadata_values SET value = ?
                        WHERE field_id = ? AND value = ? AND file_identity IN (
                            SELECT identity FROM files WHERE last_known_path = ? OR instr(last_known_path, ?) = 1
                        )
                        """,
                        bindings: [.text(newValue), .text(source.id), .text(oldValue), .text(sourcePath), .text(descendantPrefix)]
                    )
                }
                try execute(
                    """
                    INSERT OR IGNORE INTO metadata_values (file_identity, field_id, value)
                    SELECT mv.file_identity, ?, mv.value
                    FROM metadata_values mv JOIN files f ON f.identity = mv.file_identity
                    WHERE mv.field_id = ? AND (f.last_known_path = ? OR instr(f.last_known_path, ?) = 1)
                    """,
                    bindings: [.text(destination.id), .text(source.id), .text(sourcePath), .text(descendantPrefix)]
                )
                try execute(
                    """
                    DELETE FROM metadata_values
                    WHERE field_id = ? AND file_identity IN (
                        SELECT identity FROM files WHERE last_known_path = ? OR instr(last_known_path, ?) = 1
                    )
                    """,
                    bindings: [.text(source.id), .text(sourcePath), .text(descendantPrefix)]
                )
            }
            try execute("COMMIT")
            // Non usare refreshPublishedState(): quello ricarica solo l'active working set e
            // può svuotare dalla cache proprio gli elementi trascinati da un altro ramo. È la
            // causa per cui le colonne sembravano ricomparire solo selezionando la radice.
            let cachedIdentities = Set(metadataByFileIdentity.keys)
            metadataByFileIdentity = (try? loadMetadata(identities: cachedIdentities)) ?? [:]
            pendingChangedIdentities.formUnion(cachedIdentities)
            notifyMetadataChanged(immediate: true)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Unisce alle opzioni del template tutte le opzioni già configurate nelle Select/Kanban
    /// omonime del sottoalbero. L'ordine del template resta prioritario; le opzioni locali nuove
    /// vengono accodate conservando ID, etichetta e colore, così anche i valori esistenti sono
    /// migrabili senza perdita.
    private func mergedPropagatedOptions(
        for templateField: FieldTemplate,
        below rootURL: URL
    ) throws -> [MetadataSelectOption] {
        guard templateField.kind.usesOptions else { return [] }
        var result = normalizedOptions(for: templateField.kind, options: templateField.options)
        var labels = Set(result.map { Self.normalizedFieldName($0.label) })

        for (folderIdentity, fields) in fieldsByFolder {
            guard try isFolderIdentity(folderIdentity, atOrBelow: rootURL) else { continue }
            for field in fields where field.kind == templateField.kind
                && Self.normalizedFieldName(field.name) == Self.normalizedFieldName(templateField.name) {
                for option in field.options {
                    let key = Self.normalizedFieldName(option.label)
                    if labels.insert(key).inserted { result.append(option) }
                }
            }
        }
        return result
    }

    /// Trasferisce i valori dai campi locali omonimi e compatibili al campo ereditato del
    /// template. I campi non convertibili non vengono toccati: `mergeInheritedFields` farà di
    /// quella cartella un confine, evitando qualunque perdita di organizzazione preesistente.
    private func reconcileCompatibleDescendantFields(
        with inheritedFields: [MetadataField],
        below rootURL: URL,
        excluding rootIdentity: String
    ) throws {
        for (folderIdentity, localFields) in fieldsByFolder where folderIdentity != rootIdentity {
            guard try isFolderIdentity(folderIdentity, below: rootURL) else { continue }
            for local in localFields {
                guard let inherited = inheritedFields.first(where: {
                    Self.normalizedFieldName($0.name) == Self.normalizedFieldName(local.name)
                }), inherited.kind == local.kind,
                let valueMapping = try compatibleValueMapping(from: local, to: inherited) else { continue }

                try execute("BEGIN IMMEDIATE TRANSACTION")
                for (oldValue, newValue) in valueMapping where oldValue != newValue {
                    try execute(
                        "UPDATE metadata_values SET value = ? WHERE field_id = ? AND value = ?",
                        bindings: [.text(newValue), .text(local.id), .text(oldValue)]
                    )
                }
                try execute(
                    """
                    INSERT OR IGNORE INTO metadata_values (file_identity, field_id, value)
                    SELECT file_identity, ?, value FROM metadata_values WHERE field_id = ?
                    """,
                    bindings: [.text(inherited.id), .text(local.id)]
                )
                try execute("DELETE FROM metadata_fields WHERE id = ?", bindings: [.text(local.id)])
                try execute("COMMIT")
                fieldsByFolder[folderIdentity]?.removeAll { $0.id == local.id }

                for (identity, var metadata) in metadataByFileIdentity {
                    guard let oldValue = metadata.values.removeValue(forKey: local.id) else { continue }
                    metadata.values[inherited.id] = valueMapping[oldValue] ?? oldValue
                    metadataByFileIdentity[identity] = metadata
                }
            }
        }
    }

    private func isFolderIdentity(_ identity: String, below rootURL: URL) throws -> Bool {
        try isFolderIdentity(identity, atOrBelow: rootURL, includeRoot: false)
    }

    private func isFolderIdentity(
        _ identity: String,
        atOrBelow rootURL: URL,
        includeRoot: Bool = true
    ) throws -> Bool {
        var statement: OpaquePointer?
        try prepare("SELECT last_known_path FROM files WHERE identity = ?", statement: &statement)
        defer { sqlite3_finalize(statement) }
        try bind([.text(identity)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        let path = columnText(statement, 0)
        let rootPath = rootURL.standardizedFileURL.path
        return (includeRoot && path == rootPath) || path.hasPrefix(rootPath + "/")
    }

    private func compatibleValueMapping(
        from local: MetadataField,
        to inherited: MetadataField
    ) throws -> [String: String]? {
        guard local.kind == inherited.kind else { return nil }
        guard local.kind.usesOptions else { return [:] }

        let targetByLabel = Dictionary(uniqueKeysWithValues: inherited.options.map {
            (Self.normalizedFieldName($0.label), $0.label)
        })
        var mapping: [String: String] = [:]
        for option in local.options {
            if let targetLabel = targetByLabel[Self.normalizedFieldName(option.label)] {
                mapping[option.label] = targetLabel
            } else if try metadataValueExists(fieldID: local.id, value: option.label) {
                return nil
            }
        }
        return mapping
    }

    private func metadataValueExists(fieldID: String, value: String) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(
            "SELECT 1 FROM metadata_values WHERE field_id = ? AND value = ? LIMIT 1",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(fieldID), .text(value)], to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func removeField(folderURL: URL, field: MetadataField) {
        do {
            let folderIdentity = try registerFile(at: folderURL)
            try execute(
                "DELETE FROM metadata_fields WHERE id = ? AND folder_identity = ?",
                bindings: [.text(field.id), .text(folderIdentity)]
            )
            try execute("DELETE FROM metadata_values WHERE field_id = ?", bindings: [.text(field.id)])

            // Aggiornamento incrementale dello stato in memoria.
            fieldsByFolder[folderIdentity]?.removeAll { $0.id == field.id }
            for (identity, var metadata) in metadataByFileIdentity where metadata.values[field.id] != nil {
                metadata.values.removeValue(forKey: field.id)
                metadataByFileIdentity[identity] = metadata
            }
            notifyMetadataChanged(immediate: true)
        } catch {
            assertionFailure("Failed to remove metadata field: \(error)")
        }
    }

    func updateField(folderURL: URL, field: MetadataField, name: String, kind: MetadataFieldKind, options: [MetadataSelectOption]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        do {
            let folderIdentity = try registerFile(at: folderURL)
            let normalized = normalizedOptions(for: kind, options: options)
            let optionsData = try JSONEncoder().encode(normalized)
            let optionsJSON = String(data: optionsData, encoding: .utf8) ?? "[]"

            let renamedOptions = Dictionary(uniqueKeysWithValues: normalized.map { ($0.id, $0.label) })
            for oldOption in field.options {
                guard let newLabel = renamedOptions[oldOption.id],
                      oldOption.label != newLabel else { continue }
                try execute(
                    "UPDATE metadata_values SET value = ? WHERE field_id = ? AND value = ?",
                    bindings: [.text(newLabel), .text(field.id), .text(oldOption.label)]
                )
            }

            try execute(
                """
                UPDATE metadata_fields
                SET name = ?, kind = ?, options_json = ?
                WHERE id = ? AND folder_identity = ?
                """,
                bindings: [.text(trimmedName), .text(kind.rawValue), .text(optionsJSON), .text(field.id), .text(folderIdentity)]
            )

            // Cambiando il tipo del campo, i vecchi valori potrebbero non essere più validi.
            if kind != field.kind {
                try execute("DELETE FROM metadata_values WHERE field_id = ?", bindings: [.text(field.id)])
            } else if kind.usesOptions {
                let allowedLabels = Set(normalized.map(\.label))
                try deleteValuesNotInOptions(fieldID: field.id, allowedLabels: allowedLabels)
            }

            refreshPublishedState()
        } catch {
            assertionFailure("Failed to update metadata field: \(error)")
        }
    }

    @discardableResult
    func reconcileMovedItem(previousIdentity: String, newURL: URL, refreshingState: Bool = true) throws -> String {
        // Le cache possono contenere voci stale dopo uno spostamento/rinomina.
        identityCacheByPath.removeAll()
        invalidateManagedDirectoriesCache()
        let newIdentity = try registerFile(at: newURL)
        guard previousIdentity != newIdentity else {
            if refreshingState { refreshPublishedState() }
            return newIdentity
        }

        try execute(
            """
            UPDATE metadata_values
            SET file_identity = ?
            WHERE file_identity = ?
              AND NOT EXISTS (
                  SELECT 1
                  FROM metadata_values existing
                  WHERE existing.file_identity = ?
                    AND existing.field_id = metadata_values.field_id
              )
            """,
            bindings: [.text(newIdentity), .text(previousIdentity), .text(newIdentity)]
        )
        try execute("DELETE FROM metadata_values WHERE file_identity = ?", bindings: [.text(previousIdentity)])

        try execute(
            """
            UPDATE metadata_fields
            SET folder_identity = ?
            WHERE folder_identity = ?
              AND NOT EXISTS (
                  SELECT 1
                  FROM metadata_fields existing
                  WHERE existing.folder_identity = ?
                    AND existing.id = metadata_fields.id
              )
            """,
            bindings: [.text(newIdentity), .text(previousIdentity), .text(newIdentity)]
        )
        try execute("DELETE FROM metadata_fields WHERE folder_identity = ?", bindings: [.text(previousIdentity)])
        try execute("DELETE FROM files WHERE identity = ?", bindings: [.text(previousIdentity)])
        registeredIdentities.remove(previousIdentity)

        if refreshingState { refreshPublishedState() }
        return newIdentity
    }

    // MARK: - Sincronizzazione con il filesystem

    /// Riga della tabella `files` usata per la riconciliazione.
    private struct FileRow {
        var identity: String
        var bookmark: Data?
        var lastKnownPath: String
        var name: String
        var isDirectory: Bool
        var size: Int64?
    }

    private enum RowResolution {
        case present(URL)    // stesso file (eventuale rinomina/spostamento sullo stesso volume)
        case relocated(URL)  // file ritrovato ma con identità cambiata → serve ri-aggancio
        case missing         // non più trovabile → orfano
        case volumeUnavailable // volume esterno/NAS non montato: non è un orfano
    }

    /// Ritrova la posizione attuale del file di una riga, con salvaguardia anti riuso-inode.
    nonisolated private static func resolve(_ row: FileRow) -> RowResolution {
        let fm = FileManager.default

        // 1) Bookmark: àncora autorevole (segue spostamenti/rinomini, anche tra volumi).
        if let data = row.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                let newIdentity = computeIdentity(for: url)
                if let newIdentity, newIdentity != row.identity {
                    return .relocated(url)
                }
                return .present(url)
            }
        }

        // 2) Fallback sull'ultimo percorso noto.
        if fm.fileExists(atPath: row.lastKnownPath) {
            let url = URL(fileURLWithPath: row.lastKnownPath)
            let newIdentity = computeIdentity(for: url)
            if let newIdentity, newIdentity != row.identity {
                // Stesso percorso ma inode diverso: potrebbe essere un altro file (inode riusato).
                // Riaggancio solo se nome E dimensione coincidono con quanto memorizzato.
                let current = nameAndSize(for: url)
                if current.name == row.name, current.size == row.size {
                    return .relocated(url)
                }
                return .missing
            }
            return .present(url)
        }

        if !Self.isContainingVolumeAvailable(path: row.lastKnownPath) {
            return .volumeUnavailable
        }

        return .missing
    }

    /// Per i percorsi sotto /Volumes distingue un file cancellato da un volume non montato.
    /// I percorsi sul disco di avvio sono sempre considerati disponibili.
    nonisolated private static func isContainingVolumeAvailable(path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return true }
        let mount = URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2]).path
        return FileManager.default.fileExists(atPath: mount)
    }

    /// Evita riconciliazioni sovrapposte (es. raffiche di eventi FSEvents).
    private var isReconciling = false
    private var reconcileRequestedWhileRunning = false

    /// Riallinea il DB al filesystem: aggiorna percorsi/nomi/bookmark dei file spostati o
    /// rinominati altrove, e raccoglie quelli non più trovabili (orfani). Non cancella nulla.
    ///
    /// La parte costosa (risoluzione bookmark + stat sul filesystem per ogni file gestito)
    /// gira su un thread di background: prima bloccava il main thread all'avvio e a ogni
    /// evento FSEvents. Le letture/scritture del DB restano sul main thread.
    ///
    /// - Parameter changedPaths: percorsi segnalati da FSEvents. Se valorizzato, la
    ///   riconciliazione è MIRATA: risolve (bookmark + stat) solo le righe il cui percorso
    ///   ricade sotto uno dei percorsi cambiati — evitando la scansione O(N) dell'intero
    ///   archivio ad ogni singolo evento. Passare `nil` (default) forza il full reconcile,
    ///   usato all'avvio quando non si sa cosa sia cambiato mentre l'app era chiusa.
    func reconcileManagedFiles(changedPaths: [String]? = nil, completion: @escaping (_ relocated: Int, _ missingIdentities: [String]) -> Void) {
        guard !isReconciling else {
            reconcileRequestedWhileRunning = true
            completion(0, [])
            return
        }

        var rows = (try? loadFileRows()) ?? []
        guard !rows.isEmpty else {
            completion(0, [])
            return
        }

        // Reconcile mirato: limita il lavoro pesante alle sole righe coinvolte dagli eventi.
        if let changedPaths, !changedPaths.isEmpty {
            let changed = changedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            rows = rows.filter { row in
                let rowPath = URL(fileURLWithPath: row.lastKnownPath).standardizedFileURL.path
                return changed.contains { candidate in
                    rowPath == candidate
                        || rowPath.hasPrefix(candidate + "/")   // riga sotto una cartella cambiata
                        || candidate.hasPrefix(rowPath + "/")   // riga è una cartella che contiene il cambiamento
                }
            }
            guard !rows.isEmpty else {
                completion(0, [])
                return
            }
        }

        isReconciling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // `resolve` è puro filesystem (bookmark, stat): nessuno stato del DB toccato.
            let resolutions = rows.map { row in (row, Self.resolve(row)) }
            let trackingUpdates: [FileTrackingUpdate] = resolutions.compactMap { row, resolution in
                guard case .present(let url) = resolution else { return nil }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                let bookmark = row.bookmark ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
                return FileTrackingUpdate(identity: row.identity, path: url.path, name: url.lastPathComponent, size: size, bookmark: bookmark)
            }
            let relocations: [FileRelocationUpdate] = resolutions.compactMap { row, resolution in
                guard case .relocated(let url) = resolution,
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .fileResourceIdentifierKey, .volumeIdentifierKey]) else { return nil }
                let fileID = Self.stableDescription(values.fileResourceIdentifier)
                let volumeID = Self.stableDescription(values.volumeIdentifier)
                let identity = Self.fileIdentity(fileIdentifier: fileID, volumeIdentifier: volumeID, path: url.path)
                let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                return FileRelocationUpdate(previousIdentity: row.identity, newIdentity: identity,
                    fileIdentifier: fileID, volumeIdentifier: volumeID, path: url.path,
                    name: url.lastPathComponent, isDirectory: values.isDirectory ?? false,
                    size: values.fileSize.map(Int64.init), bookmark: bookmark)
            }

            DispatchQueue.main.async {
                Task { @MainActor in
                var relocated = 0
                var missingIdentities: [String] = []
                var requiresMetadataReload = false

                do {
                    if let databaseActor = self.databaseActor {
                        try await databaseActor.applyReconciliation(tracking: trackingUpdates, relocations: relocations)
                    }
                    for (row, resolution) in resolutions {
                        switch resolution {
                        case .present(let url):
                            if url.path != row.lastKnownPath { relocated += 1 }
                        case .relocated(let url):
                            _ = url
                            relocated += 1
                            requiresMetadataReload = true
                        case .missing:
                            missingIdentities.append(row.identity)
                        case .volumeUnavailable:
                            break
                        }
                    }
                } catch {
                    assertionFailure("Failed reconciliation: \(error)")
                }

                self.identityCacheByPath.removeAll()
                // I semplici aggiornamenti di path/bookmark non cambiano campi o valori in
                // memoria. Ricarica l'intero metadata store solo quando è cambiata un'identità.
                if requiresMetadataReload { self.refreshPublishedState() }
                self.isReconciling = false
                completion(relocated, missingIdentities)
                if self.reconcileRequestedWhileRunning {
                    self.reconcileRequestedWhileRunning = false
                    self.reconcileManagedFiles(completion: completion)
                }
                }
            }
        }
    }

    /// Identità delle righe il cui file non è più trovabile (metadata orfani).
    func orphanedIdentities() -> [String] {
        let rows = (try? loadFileRows()) ?? []
        return rows.compactMap { row in
            if case .missing = Self.resolve(row) { return row.identity }
            return nil
        }
    }

    /// Numero di metadata orfani (file cancellati o non più raggiungibili).
    func orphanCount() -> Int {
        orphanedIdentities().count
    }

    /// Rimuove le righe orfane (cancellazione a cascata di campi/valori collegati).
    @discardableResult
    func purgeOrphans() -> Int {
        purge(identities: orphanedIdentities())
    }

    /// Rimuove le righe indicate. Usata anche dopo la riconciliazione async, che conosce
    /// già gli orfani: evita di ri-risolvere tutti i file una seconda volta.
    @discardableResult
    func purge(identities: [String]) -> Int {
        guard !identities.isEmpty else { return 0 }

        do {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            for identity in identities {
                try execute("DELETE FROM files WHERE identity = ?", bindings: [.text(identity)])
                registeredIdentities.remove(identity)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            assertionFailure("Failed to purge orphans: \(error)")
        }

        invalidateManagedDirectoriesCache()
        refreshPublishedState()
        return identities.count
    }

    /// Cartelle da osservare con FSEvents: per ogni elemento gestito la sua cartella
    /// (se cartella, sé stessa; se file, la cartella che lo contiene). Il risultato è
    /// cachato: senza cache ogni navigazione rifarebbe una scansione completa del DB.
    func managedDirectories() -> [String] {
        if let cached = managedDirectoriesCache { return cached }

        let rows = (try? loadFileRows()) ?? []
        var dirs: Set<String> = []
        for row in rows {
            let url = URL(fileURLWithPath: row.lastKnownPath)
            dirs.insert(row.isDirectory ? url.path : url.deletingLastPathComponent().path)
        }

        let result = Array(dirs)
        managedDirectoriesCache = result
        return result
    }

    private func invalidateManagedDirectoriesCache() {
        managedDirectoriesCache = nil
    }

    private func updateTracking(_ row: FileRow, to url: URL) {
        if url.path != row.lastKnownPath {
            invalidateManagedDirectoriesCache()
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let bookmark = row.bookmark ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        try? execute(
            "UPDATE files SET last_known_path = ?, name = ?, size = ?, bookmark_data = ?, updated_at = ? WHERE identity = ?",
            bindings: [
                .text(url.path),
                .text(url.lastPathComponent),
                .intOptional(size),
                .blob(bookmark),
                .real(Date().timeIntervalSince1970),
                .text(row.identity)
            ]
        )
    }

    /// Ritrova la posizione ATTUALE di un file dato il suo `identity` stabile, usando il bookmark
    /// memorizzato (segue spostamenti/rinomini, anche tra volumi) con fallback sull'ultimo percorso
    /// noto. Usato dai deep link `folderbase://open?id=…` per aprire il file anche dopo che è stato
    /// spostato. Ritorna nil se il file non è più trovabile o il volume non è montato.
    func resolveURL(forIdentity identity: String) -> URL? {
        guard let row = try? loadFileRow(identity: identity) else { return nil }
        switch Self.resolve(row) {
        case .present(let url), .relocated(let url):
            return url
        case .missing, .volumeUnavailable:
            return nil
        }
    }

    private func loadFileRow(identity: String) throws -> FileRow? {
        var statement: OpaquePointer?
        try prepare("SELECT identity, bookmark_data, last_known_path, name, is_directory, size FROM files WHERE identity = ? LIMIT 1", statement: &statement)
        defer { sqlite3_finalize(statement) }
        try bind([.text(identity)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return FileRow(
            identity: columnText(statement, 0),
            bookmark: columnBlob(statement, 1),
            lastKnownPath: columnText(statement, 2),
            name: columnText(statement, 3),
            isDirectory: sqlite3_column_int(statement, 4) != 0,
            size: columnInt64Optional(statement, 5)
        )
    }

    private func loadFileRows() throws -> [FileRow] {
        var rows: [FileRow] = []
        var statement: OpaquePointer?
        try prepare("SELECT identity, bookmark_data, last_known_path, name, is_directory, size FROM files", statement: &statement)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                FileRow(
                    identity: columnText(statement, 0),
                    bookmark: columnBlob(statement, 1),
                    lastKnownPath: columnText(statement, 2),
                    name: columnText(statement, 3),
                    isDirectory: sqlite3_column_int(statement, 4) != 0,
                    size: columnInt64Optional(statement, 5)
                )
            )
        }

        return rows
    }

    nonisolated private static func computeIdentity(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]) else {
            return nil
        }
        return identity(for: url, resourceValues: values)
    }

    nonisolated private static func nameAndSize(for url: URL) -> (name: String, size: Int64?) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return (url.lastPathComponent, size)
    }

    // MARK: - Backup / Restore

    /// Percorso del file SQLite gestito (usato dalla UI di backup e per la copia di sicurezza).
    var databaseURL: URL { dbURL }

    /// Copia coerente del database verso `destinationURL` usando l'Online Backup API di
    /// SQLite: cattura anche il contenuto del WAL non ancora messo in checkpoint, quindi
    /// produce un file autonomo e valido anche mentre l'app è in uso. Prima svuota le
    /// scritture posticipate così il backup include l'ultimo stato in memoria.
    func backup(to destinationURL: URL) async throws {
        flushPendingWrites()

        let fm = FileManager.default
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporaryURL) }

        guard let databaseActor else { throw StoreError.sqlite(message: "Database non disponibile") }
        try await databaseActor.backup(to: temporaryURL)
        try await Task.detached(priority: .utility) {
            try SQLiteDatabaseActor.validateBackup(at: temporaryURL, thorough: false)
        }.value

        // Pubblicazione atomica: un crash durante la copia non può lasciare al posto del backup
        // precedente un file troncato. Il rename sullo stesso volume è atomico.
        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fm.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    /// Sostituisce il database gestito con quello contenuto in `sourceURL`.
    /// Il file di origine viene prima validato (integrità + presenza dello schema
    /// FolderBase); solo se è valido il database corrente viene chiuso e rimpiazzato,
    /// poi riaperto e lo stato pubblicato ricaricato. In caso di file non valido lancia
    /// un errore SENZA toccare il database attuale.
    func restore(from sourceURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try SQLiteDatabaseActor.validateBackup(at: sourceURL, thorough: true)
        }.value

        // Le scritture posticipate riguardano il DB che stiamo per sostituire: annullale.
        for (_, work) in pendingWrites { work.cancel() }
        pendingWrites.removeAll()
        pendingValues.removeAll()
        pendingChangeNotification?.cancel()
        pendingChangeNotification = nil

        if let databaseActor { await databaseActor.close() }
        databaseActor = nil
        for statement in statementCache.values { sqlite3_finalize(statement) }
        statementCache.removeAll()
        sqlite3_close(db)
        db = nil

        let fm = FileManager.default
        let stagedURL = dbURL.deletingLastPathComponent()
            .appendingPathComponent(".folderbase-restore-\(UUID().uuidString).sqlite")
        defer { try? fm.removeItem(at: stagedURL) }
        try fm.copyItem(at: sourceURL, to: stagedURL)
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
        try? fm.removeItem(at: walURL)
        try? fm.removeItem(at: shmURL)
        if fm.fileExists(atPath: dbURL.path) {
            _ = try fm.replaceItemAt(dbURL, withItemAt: stagedURL)
        } else {
            try fm.moveItem(at: stagedURL, to: dbURL)
        }

        try openDatabase()
        try migrateSchema()
        databaseActor = try SQLiteDatabaseActor(url: dbURL)
        registeredIdentities = (try? loadRegisteredIdentities()) ?? []
        identityCacheByPath.removeAll()
        invalidateManagedDirectoriesCache()
        refreshPublishedState()
    }

    /// Verifica che `url` sia un database SQLite integro e con lo schema di FolderBase.
    private func validateBackup(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.sqlite(message: "File di backup non trovato")
        }

        var testDB: OpaquePointer?
        guard sqlite3_open_v2(url.path, &testDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(testDB)
            throw StoreError.sqlite(message: "Il file non è un database valido")
        }
        defer { sqlite3_close(testDB) }

        var integrityStatement: OpaquePointer?
        var integrityOK = false
        if sqlite3_prepare_v2(testDB, "PRAGMA integrity_check", -1, &integrityStatement, nil) == SQLITE_OK,
           sqlite3_step(integrityStatement) == SQLITE_ROW,
           let result = sqlite3_column_text(integrityStatement, 0) {
            integrityOK = String(cString: result) == "ok"
        }
        sqlite3_finalize(integrityStatement)
        guard integrityOK else {
            throw StoreError.sqlite(message: "Controllo di integrità non superato")
        }

        var schemaStatement: OpaquePointer?
        var hasFilesTable = false
        if sqlite3_prepare_v2(testDB, "SELECT name FROM sqlite_master WHERE type='table' AND name='files'", -1, &schemaStatement, nil) == SQLITE_OK {
            hasFilesTable = sqlite3_step(schemaStatement) == SQLITE_ROW
        }
        sqlite3_finalize(schemaStatement)
        guard hasFilesTable else {
            throw StoreError.sqlite(message: "Il file non è un backup di FolderBase")
        }
    }

    private func openDatabase() throws {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            throw StoreError.sqlite(message: lastErrorMessage)
        }

        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        // Con WAL, NORMAL è lo standard consigliato: dimezza il costo dei commit
        // mantenendo la durabilità a livello di checkpoint.
        try execute("PRAGMA synchronous = NORMAL")
        // Perf letture/ordinamenti (sicuri, solo memoria). NB: `PRAGMA mmap_size` NON viene usato
        // di proposito: la causa dei crash durante l'indicizzazione era il file descriptor stdin
        // in TextExtractor.runProcess, non i pragma, ma il memory-map resta un rischio inutile qui.
        try? execute("PRAGMA temp_store = MEMORY")
        try? execute("PRAGMA cache_size = -16000")
    }

    private func migrateSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS files (
                identity TEXT PRIMARY KEY,
                file_resource_identifier TEXT NOT NULL,
                volume_identifier TEXT NOT NULL,
                bookmark_data BLOB,
                last_known_path TEXT NOT NULL,
                name TEXT NOT NULL,
                is_directory INTEGER NOT NULL,
                size INTEGER,
                updated_at REAL NOT NULL
            )
            """
        )

        // Migrazione incrementale per DB creati prima dell'aggiunta della colonna size.
        try addColumnIfMissing(table: "files", column: "size", definition: "INTEGER")

        try execute(
            """
            CREATE TABLE IF NOT EXISTS metadata_fields (
                id TEXT PRIMARY KEY,
                folder_identity TEXT NOT NULL,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                options_json TEXT NOT NULL DEFAULT '[]',
                position INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY(folder_identity) REFERENCES files(identity) ON DELETE CASCADE
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS metadata_values (
                file_identity TEXT NOT NULL,
                field_id TEXT NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY(file_identity, field_id),
                FOREIGN KEY(file_identity) REFERENCES files(identity) ON DELETE CASCADE,
                FOREIGN KEY(field_id) REFERENCES metadata_fields(id) ON DELETE CASCADE
            )
            """
        )

        // Indici per le query che filtrano su colonne non coperte dalle chiavi primarie:
        // DELETE/UPDATE metadata_values WHERE field_id = ? e il caricamento dei campi
        // per cartella farebbero altrimenti una scansione completa della tabella.
        try execute("CREATE INDEX IF NOT EXISTS idx_metadata_values_field ON metadata_values(field_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_metadata_fields_folder ON metadata_fields(folder_identity)")

        try migrateContentSchema()
    }

    /// Schema per l'indicizzazione del CONTENUTO dei file (Fase 0: estrazione testo/OCR +
    /// full-text search). Additivo: nessuna modifica alle tabelle esistenti.
    /// - `file_content`: una riga per file indicizzato, con testo estratto, stato e hash
    ///   di change-detection (evita di ri-estrarre file immutati).
    /// - `content_fts`: indice FTS5 (unicode61, diacritici rimossi) per la ricerca testuale;
    ///   `file_identity` non è indicizzato, serve solo a ricondurre i match al file.
    private func migrateContentSchema() throws {
        // Dalla separazione dell'indice, le tabelle pesanti vivono esclusivamente in
        // folderbase-index.sqlite. Il DB operativo conserva solo lo stato per-cartella.
        if FileManager.default.fileExists(atPath: indexDBURL.path) {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS folder_index_status (
                    folder_path TEXT PRIMARY KEY,
                    state TEXT NOT NULL,
                    indexed_count INTEGER NOT NULL,
                    total_count INTEGER NOT NULL,
                    checked_at REAL NOT NULL
                )
                """
            )
            return
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS file_content (
                file_identity TEXT PRIMARY KEY,
                name TEXT NOT NULL DEFAULT '',
                path TEXT NOT NULL DEFAULT '',
                extracted_text TEXT,
                ocr_used INTEGER NOT NULL DEFAULT 0,
                content_hash TEXT,
                extracted_at REAL,
                index_state TEXT NOT NULL DEFAULT 'pending',
                FOREIGN KEY(file_identity) REFERENCES files(identity) ON DELETE CASCADE
            )
            """
        )
        try addColumnIfMissing(table: "file_content", column: "name", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "file_content", column: "path", definition: "TEXT NOT NULL DEFAULT ''")
        try? execute("UPDATE file_content SET name=COALESCE((SELECT name FROM files WHERE files.identity=file_content.file_identity),name), path=COALESCE((SELECT last_known_path FROM files WHERE files.identity=file_content.file_identity),path) WHERE name='' OR path=''")

        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS content_fts USING fts5(
                file_identity UNINDEXED,
                name,
                body,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """
        )

        // Fase 1 — ricerca semantica: chunk di testo + relativi embedding.
        // - `content_chunks`: porzioni di testo di un file (per snippet/RAG futuri).
        // - `chunk_vectors`: embedding per chunk, taggato col provider (lingua/modello) e la
        //   dimensione; vettore serializzato come BLOB di Float32.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS content_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_identity TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                text TEXT NOT NULL,
                FOREIGN KEY(file_identity) REFERENCES files(identity) ON DELETE CASCADE
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_chunks_file ON content_chunks(file_identity)")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chunk_vectors (
                chunk_id INTEGER PRIMARY KEY,
                provider_id TEXT NOT NULL,
                dimension INTEGER NOT NULL,
                vector BLOB NOT NULL,
                FOREIGN KEY(chunk_id) REFERENCES content_chunks(id) ON DELETE CASCADE
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_chunk_vectors_provider ON chunk_vectors(provider_id)")
        // Perf ricerca semantica (Fase 4): norma L2 precalcolata (evita di ricalcolarla a ogni
        // query) e indice composito a supporto del prefiltro provider_id+dimension. L'ALTER è
        // idempotente: fallisce silenziosamente se la colonna esiste già (DB aggiornati).
        _ = try? execute("ALTER TABLE chunk_vectors ADD COLUMN norm REAL NOT NULL DEFAULT 0")
        try execute("CREATE INDEX IF NOT EXISTS idx_chunk_vectors_provider_dim ON chunk_vectors(provider_id, dimension)")

        // Esito memorizzato dell'ultimo calcolo di stato di indicizzazione per cartella
        // (evita di ri-enumerare il sottoalbero a ogni apertura della Configurazione).
        try execute(
            """
            CREATE TABLE IF NOT EXISTS folder_index_status (
                folder_path TEXT PRIMARY KEY,
                state TEXT NOT NULL,
                indexed_count INTEGER NOT NULL,
                total_count INTEGER NOT NULL,
                checked_at REAL NOT NULL
            )
            """
        )
    }

    private func migrateLegacyJSONIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: legacyMetadataURL.path),
              try intValue("SELECT COUNT(*) FROM metadata_fields") == 0,
              try intValue("SELECT COUNT(*) FROM metadata_values") == 0 else { return }

        let data = try Data(contentsOf: legacyMetadataURL)
        guard let document = try? JSONDecoder().decode(LegacyMetadataDocument.self, from: data) else { return }

        for (folderPath, fields) in document.fieldsByFolder {
            let folderURL = URL(fileURLWithPath: folderPath)
            guard FileManager.default.fileExists(atPath: folderPath),
                  let folderIdentity = try? registerFile(at: folderURL) else { continue }

            for (index, field) in fields.enumerated() {
                let optionsData = try JSONEncoder().encode(field.options)
                let optionsJSON = String(data: optionsData, encoding: .utf8) ?? "[]"
                try execute(
                    """
                    INSERT OR IGNORE INTO metadata_fields (id, folder_identity, name, kind, options_json, position)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [.text(field.id), .text(folderIdentity), .text(field.name), .text(field.kind.rawValue), .text(optionsJSON), .int(index)]
                )
            }
        }

        for (filePath, metadata) in document.metadataByPath {
            let fileURL = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: filePath),
                  let fileIdentity = try? registerFile(at: fileURL) else { continue }

            for (fieldID, value) in metadata.values {
                try execute(
                    "INSERT OR IGNORE INTO metadata_values (file_identity, field_id, value) VALUES (?, ?, ?)",
                    bindings: [.text(fileIdentity), .text(fieldID), .text(value)]
                )
            }
        }
    }

    private func refreshPublishedState() {
        notifyMetadataChanged(immediate: true)
        fieldsByFolder = (try? loadFields()) ?? [:]
        metadataByFileIdentity = (try? loadMetadata(identities: activeMetadataIdentities)) ?? [:]
        metadataStructureChanges.send()
    }

    private func loadFields() throws -> [String: [MetadataField]] {
        var result: [String: [MetadataField]] = [:]
        var statement: OpaquePointer?
        let sql = "SELECT folder_identity, id, name, kind, options_json FROM metadata_fields ORDER BY folder_identity, position, name"
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let folderIdentity = columnText(statement, 0)
            let id = columnText(statement, 1)
            let name = columnText(statement, 2)
            let kind = MetadataFieldKind(rawValue: columnText(statement, 3)) ?? .text
            let options = decodeOptions(from: columnText(statement, 4))
            result[folderIdentity, default: []].append(MetadataField(id: id, name: name, kind: kind, options: options))
        }

        return result
    }

    private func loadRegisteredIdentities() throws -> Set<String> {
        var result: Set<String> = []
        var statement: OpaquePointer?
        try prepare("SELECT identity FROM files", statement: &statement)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            result.insert(columnText(statement, 0))
        }

        return result
    }

    private func loadMetadata(identities: Set<String>) throws -> [String: FileMetadata] {
        guard !identities.isEmpty else { return [:] }
        try prepareIdentityTable(name: "active_metadata_identities", identities: identities)
        var result: [String: FileMetadata] = [:]
        var statement: OpaquePointer?
        let sql = """
            SELECT mv.file_identity, mv.field_id, mv.value
            FROM metadata_values mv
            JOIN temp.active_metadata_identities active ON active.identity = mv.file_identity
            """
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let fileIdentity = columnText(statement, 0)
            let fieldID = columnText(statement, 1)
            let value = columnText(statement, 2)
            var metadata = result[fileIdentity] ?? .empty
            metadata.values[fieldID] = value
            result[fileIdentity] = metadata
        }

        return result
    }

    private func normalizedOptions(for kind: MetadataFieldKind, options: [MetadataSelectOption]) -> [MetadataSelectOption] {
        guard kind.usesOptions else { return [] }

        var seenLabels: Set<String> = []
        return options.compactMap { option in
            let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !seenLabels.contains(label.lowercased()) else { return nil }
            seenLabels.insert(label.lowercased())
            return MetadataSelectOption(id: option.id, label: label, color: option.color)
        }
    }

    private func decodeOptions(from json: String) -> [MetadataSelectOption] {
        let data = json.data(using: .utf8) ?? Data()
        if let options = try? JSONDecoder().decode([MetadataSelectOption].self, from: data) {
            return options
        }

        let legacyOptions = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return legacyOptions.map { MetadataSelectOption(label: $0, color: .gray) }
    }

    /// Funzioni pure (statiche, thread-safe) per calcolare l'identità: usabili anche
    /// fuori dal main thread da `FileBrowserService` senza toccare lo stato del DB.
    nonisolated static func fileIdentity(fileIdentifier: String, volumeIdentifier: String, path: String) -> String {
        if !fileIdentifier.isEmpty, !volumeIdentifier.isEmpty {
            return "\(volumeIdentifier):\(fileIdentifier)"
        }

        return "path:\(path)"
    }

    nonisolated static func stableDescription(_ value: Any?) -> String {
        guard let value else { return "" }
        return String(describing: value)
    }

    nonisolated static func identity(for fileURL: URL, resourceValues: URLResourceValues) -> String {
        fileIdentity(
            fileIdentifier: stableDescription(resourceValues.fileResourceIdentifier),
            volumeIdentifier: stableDescription(resourceValues.volumeIdentifier),
            path: fileURL.path
        )
    }

    /// Costruisce la registrazione della riga `files` per un file da indicizzare, LEGGENDO da disco
    /// (resourceValues + bookmark). È `nonisolated` così può girare fuori dal main thread durante
    /// l'indicizzazione. L'`identity` è quella già calcolata per l'item (coerente con la foreign key
    /// di file_content). Se resourceValues fallisce, produce comunque una registrazione minima con
    /// path/nome, così il contenuto non resta orfano.
    nonisolated static func fileRegistration(url: URL, identity: String) -> FileRegistration {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileResourceIdentifierKey, .volumeIdentifierKey, .fileSizeKey]) else {
            return FileRegistration(identity: identity, fileIdentifier: "", volumeIdentifier: "", bookmark: nil, path: url.path, name: url.lastPathComponent, isDirectory: false, size: nil)
        }
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FileRegistration(
            identity: identity,
            fileIdentifier: stableDescription(values.fileResourceIdentifier),
            volumeIdentifier: stableDescription(values.volumeIdentifier),
            bookmark: bookmark,
            path: url.path,
            name: url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            size: values.fileSize.map(Int64.init)
        )
    }

    /// Aggiorna lo stato in memoria dopo una registrazione file avvenuta sull'actor (senza passare
    /// da `registerFile` sul main): cache identità e insieme dei file registrati.
    private func noteRegistered(identity: String, path: String) {
        identityCacheByPath[path] = identity
        if !registeredIdentities.contains(identity) {
            registeredIdentities.insert(identity)
            invalidateManagedDirectoriesCache()
        }
    }

    // MARK: - Indicizzazione contenuti (Fase 0: estrazione + full-text search)

    /// Hash di change-detection dei soli file già **indicizzati** con successo (nil altrimenti).
    /// Usato dall'`IndexingService` per saltare i file immutati; i file marcati "unsupported"
    /// ritornano nil di proposito, così vengono riprovati (utile quando l'estrattore impara
    /// nuovi formati) senza doverli modificare.
    func contentHash(for identity: String) async -> String? {
        if let contentDatabaseActor { return await contentDatabaseActor.contentHash(identity: identity) }
        var statement: OpaquePointer?
        guard (try? prepare("SELECT content_hash FROM file_content WHERE file_identity = ? AND index_state = 'indexed'", statement: &statement)) != nil else { return nil }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(identity)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let value = columnText(statement, 0)
        return value.isEmpty ? nil : value
    }

    /// Numero di file con contenuto effettivamente indicizzato (stato "indexed").
    func indexedContentCount() -> Int {
        (try? intValue("SELECT COUNT(*) FROM file_content WHERE index_state = 'indexed'")) ?? 0
    }

    /// Salva l'esito del calcolo di stato di una cartella (memorizzato, ricalcolato su richiesta).
    func saveFolderIndexStatus(path: String, state: String, indexed: Int, total: Int) {
        try? execute(
            """
            INSERT INTO folder_index_status (folder_path, state, indexed_count, total_count, checked_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(folder_path) DO UPDATE SET
                state = excluded.state,
                indexed_count = excluded.indexed_count,
                total_count = excluded.total_count,
                checked_at = excluded.checked_at
            """,
            bindings: [.text(path), .text(state), .int(indexed), .int(total), .real(Date().timeIntervalSince1970)]
        )
    }

    /// Esito memorizzato dell'ultimo calcolo di stato per una cartella (nil se mai calcolato).
    func folderIndexStatus(path: String) -> (state: String, indexed: Int, total: Int, checkedAt: Date)? {
        var statement: OpaquePointer?
        guard (try? prepare("SELECT state, indexed_count, total_count, checked_at FROM folder_index_status WHERE folder_path = ?", statement: &statement)) != nil else { return nil }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(path)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let state = columnText(statement, 0)
        let indexed = Int(sqlite3_column_int(statement, 1))
        let total = Int(sqlite3_column_int(statement, 2))
        let checkedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        return (state, indexed, total, checkedAt)
    }

    /// Identità dei file che hanno almeno un embedding con provider che inizia per `providerPrefix`
    /// (es. "apple-nl-", "ollama-<model>", "openai-<model>"). Serve a legare lo stato al motore AI.
    func identitiesWithVectors(providerPrefix: String) async -> Set<String> {
        if let contentDatabaseActor { return await contentDatabaseActor.identitiesWithVectors(providerPrefix: providerPrefix) }
        var result: Set<String> = []
        var statement: OpaquePointer?
        let sql = "SELECT DISTINCT c.file_identity FROM chunk_vectors v JOIN content_chunks c ON c.id = v.chunk_id WHERE v.provider_id LIKE ?"
        guard (try? prepare(sql, statement: &statement)) != nil else { return [] }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(providerPrefix + "%")], to: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            result.insert(columnText(statement, 0))
        }
        return result
    }

    /// Recupero dei chunk più pertinenti per la CHAT (RAG): oltre a identità e punteggio ritorna il
    /// testo del chunk e nome/percorso del file per costruire il prompt e citare le fonti.
    /// Se `candidates` è vuoto, cerca su tutto l'indice.
    ///
    /// Retrieval IBRIDO: fonde il ranking semantico (coseno) con un ranking lessicale via
    /// Reciprocal Rank Fusion. Il segnale lessicale è pesato per rarità (IDF): i termini rari della
    /// domanda (nomi propri, sigle, codici) contano molto più delle parole comuni, i match nel NOME
    /// del file ricevono un bonus e la copertura dei termini (quanti termini distinti della domanda
    /// il chunk soddisfa) amplifica il punteggio. Così i chunk che parlano davvero degli argomenti
    /// chiesti salgono sopra i semplici "vicini vettoriali".
    /// `queries` = uno o più vettori della domanda, uno per SPAZIO (provider/lingua) presente
    /// nell'indice. Un chunk riceve un punteggio semantico solo se esiste un vettore-query dello
    /// stesso spazio (stessa lingua/motore), mentre il punteggio lessicale vale su TUTTI gli spazi.
    /// Così una domanda in italiano può recuperare anche documenti in inglese: per via semantica se
    /// è disponibile un vettore-query inglese (o con un motore multilingue), e comunque per parole
    /// chiave condivise (nomi, sigle, numeri, termini tecnici uguali nelle due lingue).
    ///
    /// Ritorna un POOL ordinato per punteggio fuso (`fused`), con un tetto di chunk per file che
    /// preserva la varietà di documenti: la selezione finale (diversità, recency, conflitti tra
    /// versioni) è compito del `SourceSelector`.
    /// Percorso RAG asincrono: la scansione dei vettori + decodifica BLOB avviene sull'actor di
    /// background e il calcolo dei punteggi in un task detached, così il main thread non si blocca
    /// mai durante una domanda. Ricade sul percorso sincrono solo se l'actor non è disponibile.
    func semanticChunksAsync(query: String, queries: [EmbeddingResult], candidates: Set<String>, limit: Int) async -> [RetrievedChunk] {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            Self.performanceLog.debug("semanticChunksAsync candidati=\(candidates.count) durata_ms=\((CFAbsoluteTimeGetCurrent() - startedAt) * 1000, format: .fixed(precision: 1))")
        }
        guard let contentDatabaseActor else {
            return semanticChunks(query: query, queries: queries, candidates: candidates, limit: limit)
        }
        let querySpaces = Set(queries.filter { !$0.vector.isEmpty }.map(\.providerID))
        let rows = await contentDatabaseActor.semanticRows(candidates: candidates, querySpaces: querySpaces)
        guard !rows.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            Self.rankSemanticChunks(query: query, queries: queries, rows: rows, limit: limit)
        }.value
    }

    func semanticChunks(query: String, queries: [EmbeddingResult], candidates: Set<String>, limit: Int) -> [RetrievedChunk] {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            Self.performanceLog.debug("semanticChunks candidati=\(candidates.count) durata_ms=\((CFAbsoluteTimeGetCurrent() - startedAt) * 1000, format: .fixed(precision: 1))")
        }
        let querySpaces = Set(queries.filter { !$0.vector.isEmpty }.map(\.providerID))
        if !candidates.isEmpty, !prepareSemanticCandidates(candidates) { return [] }
        var statement: OpaquePointer?
        let sql = """
            SELECT c.file_identity, f.last_known_path, f.name, c.text, v.provider_id, v.vector, v.norm
            FROM chunk_vectors v
            JOIN content_chunks c ON c.id = v.chunk_id
            JOIN files f ON f.identity = c.file_identity
            \(candidates.isEmpty ? "" : "JOIN temp.semantic_candidates sc ON sc.identity = c.file_identity")
            """
        guard (try? prepare(sql, statement: &statement)) != nil else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [SemanticRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let providerID = columnText(statement, 4)
            var vector: [Float] = []
            if querySpaces.contains(providerID), let blob = columnBlob(statement, 5) {
                vector = Self.floats(from: blob)
            }
            rows.append(SemanticRow(
                identity: columnText(statement, 0),
                path: columnText(statement, 1),
                name: columnText(statement, 2),
                text: columnText(statement, 3),
                providerID: providerID,
                vector: vector,
                storedNorm: Float(sqlite3_column_double(statement, 6))
            ))
        }
        return Self.rankSemanticChunks(query: query, queries: queries, rows: rows, limit: limit)
    }

    /// Punteggio + fusione dei chunk recuperati. Puro calcolo (nessun accesso al DB o allo stato),
    /// quindi `nonisolated`: può girare fuori dal main thread. `rows` arriva già con i vettori
    /// decodificati (solo per gli spazi-query) dalla connessione di background.
    nonisolated static func rankSemanticChunks(query: String, queries: [EmbeddingResult], rows: [SemanticRow], limit: Int) -> [RetrievedChunk] {
        // Vettori della query indicizzati per spazio (provider_id → vettore + norma).
        var queryBySpace: [String: (vector: [Float], norm: Float)] = [:]
        for q in queries where !q.vector.isEmpty {
            let norm = Self.norm(q.vector)
            if norm > 0 { queryBySpace[q.providerID] = (q.vector, norm) }
        }
        let terms = Self.meaningfulTerms(from: query)
        // Senza né vettori-query né parole chiave non c'è nulla da recuperare.
        guard !queryBySpace.isEmpty || !terms.isEmpty else { return [] }

        // Prima passata: scansione dei chunk. Per ogni termine si registra il PESO del match
        // (esatto nel testo 1.0, prefisso 0.7, con bonus se compare anche nel nome del file) e la
        // document frequency (in quanti chunk compare), che serve poi per l'IDF.
        struct ScannedChunk {
            let identity: String; let path: String; let name: String; let text: String
            let semantic: Float?; let termWeights: [Float]
        }
        var scanned: [ScannedChunk] = []
        var documentFrequency = [Int](repeating: 0, count: terms.count)
        var totalChunks = 0
        for row in rows {
            let name = row.name
            let text = row.text
            totalChunks += 1

            // Semantico: solo se abbiamo un vettore-query per QUESTO spazio (stessa lingua/motore).
            var semantic: Float? = nil
            if let queryVec = queryBySpace[row.providerID], !row.vector.isEmpty, row.vector.count == queryVec.vector.count {
                let vectorNorm = row.storedNorm > 0 ? row.storedNorm : Self.norm(row.vector)
                semantic = Self.cosine(queryVec.vector, row.vector, aNorm: queryVec.norm, bNorm: vectorNorm)
            }

            // Lessicale: peso del match per ciascun termine della domanda. Il match nel nome del
            // file è un segnale forte ("contratto" nella domanda + "Contratto_2026.pdf") e si somma.
            var termWeights = [Float](repeating: 0, count: terms.count)
            if !terms.isEmpty {
                let textTokens = Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
                let nameTokens = Set(name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
                for (index, term) in terms.enumerated() {
                    var weight: Float = 0
                    if textTokens.contains(term) {
                        weight = 1.0
                    } else if textTokens.contains(where: { $0.hasPrefix(term) }) {
                        weight = 0.7
                    }
                    if weight > 0 { documentFrequency[index] += 1 }
                    if nameTokens.contains(term) {
                        weight += 0.8
                    } else if nameTokens.contains(where: { $0.hasPrefix(term) }) {
                        weight += 0.5
                    }
                    termWeights[index] = weight
                }
            }

            if semantic != nil || termWeights.contains(where: { $0 > 0 }) {
                scanned.append(ScannedChunk(identity: row.identity, path: row.path, name: name, text: text, semantic: semantic, termWeights: termWeights))
            }
        }
        guard !scanned.isEmpty else { return [] }

        // Seconda passata: punteggio lessicale = Σ peso(termine) × IDF(termine), amplificato dalla
        // copertura (quanti termini distinti della domanda sono soddisfatti). L'IDF fa contare i
        // termini rari (che discriminano i documenti) più delle parole presenti ovunque.
        let corpusSize = Float(max(totalChunks, 1))
        let idf: [Float] = documentFrequency.map { Foundation.log(1 + corpusSize / Float($0 + 1)) }
        var lexicalScores = [Float](repeating: 0, count: scanned.count)
        for (index, chunk) in scanned.enumerated() {
            var score: Float = 0
            var matched = 0
            for term in terms.indices where chunk.termWeights[term] > 0 {
                score += chunk.termWeights[term] * idf[term]
                matched += 1
            }
            if matched > 0, !terms.isEmpty {
                score *= 1 + Float(matched) / Float(terms.count)
            }
            lexicalScores[index] = score
        }

        // Ranking semantico (solo i chunk con un punteggio) e lessicale (solo quelli con riscontri),
        // fusi via RRF: pertinenza per parole chiave e vicinanza semantica si rinforzano. Il
        // punteggio fuso viene ESPOSTO nel risultato, così il chiamante può ragionare su distacchi
        // e pareggi tra documenti (ambiguità, conflitti di versione).
        let semanticOrder = scanned.indices
            .filter { scanned[$0].semantic != nil }
            .sorted { (scanned[$0].semantic ?? 0) > (scanned[$1].semantic ?? 0) }
        let lexicalOrder = scanned.indices
            .filter { lexicalScores[$0] > 0 }
            .sorted { lhs, rhs in
                lexicalScores[lhs] != lexicalScores[rhs]
                    ? lexicalScores[lhs] > lexicalScores[rhs]
                    : (scanned[lhs].semantic ?? 0) > (scanned[rhs].semantic ?? 0)
            }
        var fusedScores: [Int: Float] = [:]
        for list in [semanticOrder, lexicalOrder] where !list.isEmpty {
            for (position, index) in list.enumerated() {
                fusedScores[index, default: 0] += 1.0 / Float(60 + position + 1)
            }
        }
        let orderedIndices = fusedScores
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)

        // Pool con tetto di chunk per file: evita che un solo documento lungo saturi il pool
        // rendendo invisibili le alternative (necessarie per rilevare ambiguità e versioni).
        let maxPerFileInPool = 4
        var perFile: [String: Int] = [:]
        var result: [RetrievedChunk] = []
        for index in orderedIndices {
            let chunk = scanned[index]
            let count = perFile[chunk.identity, default: 0]
            guard count < maxPerFileInPool else { continue }
            perFile[chunk.identity] = count + 1
            result.append(RetrievedChunk(
                identity: chunk.identity,
                path: chunk.path,
                name: chunk.name,
                text: chunk.text,
                semantic: chunk.semantic,
                lexical: lexicalScores[index],
                fused: fusedScores[index] ?? 0
            ))
            if result.count >= limit { break }
        }
        return result
    }

    /// Insieme dei `provider_id` (spazi/lingue di embedding) presenti nell'indice. Serve alla chat per
    /// generare un vettore-query per ciascuno spazio e abilitare il retrieval cross-lingua.
    func indexedProviderIDs() -> [String] {
        var statement: OpaquePointer?
        guard (try? prepare("SELECT DISTINCT provider_id FROM chunk_vectors", statement: &statement)) != nil else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(columnText(statement, 0))
        }
        return result
    }

    /// Variante async: legge gli spazi sulla connessione di background, senza toccare il main.
    func indexedProviderIDsAsync() async -> [String] {
        if let contentDatabaseActor { return await contentDatabaseActor.distinctProviderIDs() }
        return indexedProviderIDs()
    }

    /// Mappa identità→hash di TUTTI i file indicizzati con successo. Usata per calcolare la
    /// copertura di indicizzazione di una cartella (stato verde/arancione).
    func indexedHashes() async -> [String: String] {
        if let contentDatabaseActor { return await contentDatabaseActor.indexedHashes(state: "indexed") }
        var result: [String: String] = [:]
        var statement: OpaquePointer?
        let sql = "SELECT file_identity, content_hash FROM file_content WHERE index_state = 'indexed' AND content_hash IS NOT NULL"
        guard (try? prepare(sql, statement: &statement)) != nil else { return [:] }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            result[columnText(statement, 0)] = columnText(statement, 1)
        }
        return result
    }

    /// Mappa identità→hash dei file processati ma SENZA contenuto indicizzabile (index_state
    /// = 'unsupported': testo non estraibile). Usata dallo stato per contarli come "coperti".
    func unsupportedHashes() async -> [String: String] {
        if let contentDatabaseActor { return await contentDatabaseActor.indexedHashes(state: "unsupported") }
        var result: [String: String] = [:]
        var statement: OpaquePointer?
        let sql = "SELECT file_identity, content_hash FROM file_content WHERE index_state = 'unsupported' AND content_hash IS NOT NULL"
        guard (try? prepare(sql, statement: &statement)) != nil else { return [:] }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            result[columnText(statement, 0)] = columnText(statement, 1)
        }
        return result
    }

    /// Salva il testo estratto da un file e aggiorna l'indice full-text. Registra prima il
    /// file nella tabella `files` (necessario per la foreign key) senza toccare il percorso
    /// caldo di navigazione.
    func storeExtractedText(for item: FileItem, text: String, ocrUsed: Bool, hash: String) async {
        if let contentDatabaseActor {
            let url = item.url
            let identity = item.identity
            let registration = await Task.detached(priority: .utility) {
                MetadataStore.fileRegistration(url: url, identity: identity)
            }.value
            try? await contentDatabaseActor.storeContent(identity: item.identity, name: item.name, path: item.url.path, text: text, ocrUsed: ocrUsed, hash: hash, state: "indexed", chunks: nil, registration: registration)
            noteRegistered(identity: item.identity, path: item.url.path)
            return
        }
        do {
            _ = try registerFile(at: item.url)
            try execute("BEGIN IMMEDIATE TRANSACTION")
            try execute(
            """
            INSERT INTO file_content (file_identity, extracted_text, ocr_used, content_hash, extracted_at, index_state)
            VALUES (?, ?, ?, ?, ?, 'indexed')
            ON CONFLICT(file_identity) DO UPDATE SET
                extracted_text = excluded.extracted_text,
                ocr_used = excluded.ocr_used,
                content_hash = excluded.content_hash,
                extracted_at = excluded.extracted_at,
                index_state = 'indexed'
            """,
            bindings: [
                .text(item.identity),
                .text(text),
                .int(ocrUsed ? 1 : 0),
                .text(hash),
                .real(Date().timeIntervalSince1970)
            ]
        )
            try execute("DELETE FROM content_fts WHERE file_identity = ?", bindings: [.text(item.identity)])
            try execute(
                "INSERT INTO content_fts (file_identity, name, body) VALUES (?, ?, ?)",
                bindings: [.text(item.identity), .text(item.name), .text(text)]
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
        }
    }

    /// Commit atomico dell'intero risultato di indicizzazione. Testo, FTS, chunk e vettori
    /// diventano visibili insieme; un errore non lascia un indice misto tra vecchia e nuova versione.
    func storeIndexedContent(
        for item: FileItem,
        text: String,
        ocrUsed: Bool,
        hash: String,
        chunks: [(ordinal: Int, text: String, providerID: String, vector: [Float])]
    ) async {
        if let contentDatabaseActor {
            let url = item.url
            let identity = item.identity
            let registration = await Task.detached(priority: .utility) {
                MetadataStore.fileRegistration(url: url, identity: identity)
            }.value
            try? await contentDatabaseActor.storeContent(identity: item.identity, name: item.name, path: item.url.path, text: text, ocrUsed: ocrUsed, hash: hash, state: "indexed", chunks: chunks, registration: registration)
            noteRegistered(identity: item.identity, path: item.url.path)
            return
        }
        do {
            _ = try registerFile(at: item.url)
            try execute("BEGIN IMMEDIATE TRANSACTION")
            try execute(
                """
                INSERT INTO file_content (file_identity, extracted_text, ocr_used, content_hash, extracted_at, index_state)
                VALUES (?, ?, ?, ?, ?, 'indexed')
                ON CONFLICT(file_identity) DO UPDATE SET
                    extracted_text = excluded.extracted_text,
                    ocr_used = excluded.ocr_used,
                    content_hash = excluded.content_hash,
                    extracted_at = excluded.extracted_at,
                    index_state = 'indexed'
                """,
                bindings: [.text(item.identity), .text(text), .int(ocrUsed ? 1 : 0), .text(hash), .real(Date().timeIntervalSince1970)]
            )
            try execute("DELETE FROM content_fts WHERE file_identity = ?", bindings: [.text(item.identity)])
            try execute("INSERT INTO content_fts (file_identity, name, body) VALUES (?, ?, ?)", bindings: [.text(item.identity), .text(item.name), .text(text)])
            try execute("DELETE FROM content_chunks WHERE file_identity = ?", bindings: [.text(item.identity)])
            for chunk in chunks {
                try execute(
                    "INSERT INTO content_chunks (file_identity, ordinal, text) VALUES (?, ?, ?)",
                    bindings: [.text(item.identity), .int(chunk.ordinal), .text(chunk.text)]
                )
                let chunkID = sqlite3_last_insert_rowid(db)
                try execute(
                    "INSERT INTO chunk_vectors (chunk_id, provider_id, dimension, vector, norm) VALUES (?, ?, ?, ?, ?)",
                    bindings: [.int(Int(chunkID)), .text(chunk.providerID), .int(chunk.vector.count), .blob(Self.data(from: chunk.vector)), .real(Double(Self.norm(chunk.vector)))]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
        }
    }

    /// Marca un file come non supportato (nessun testo estraibile) salvando comunque l'hash,
    /// così l'indicizzazione non lo riprova finché il file non cambia.
    func markContentUnsupported(for item: FileItem, hash: String) async {
        if let contentDatabaseActor {
            let url = item.url
            let identity = item.identity
            let registration = await Task.detached(priority: .utility) {
                MetadataStore.fileRegistration(url: url, identity: identity)
            }.value
            try? await contentDatabaseActor.storeContent(identity: item.identity, name: item.name, path: item.url.path, text: nil, ocrUsed: false, hash: hash, state: "unsupported", chunks: nil, registration: registration)
            noteRegistered(identity: item.identity, path: item.url.path)
            return
        }
        _ = try? registerFile(at: item.url)
        try? execute(
            """
            INSERT INTO file_content (file_identity, extracted_text, ocr_used, content_hash, extracted_at, index_state)
            VALUES (?, NULL, 0, ?, ?, 'unsupported')
            ON CONFLICT(file_identity) DO UPDATE SET
                extracted_text = NULL,
                content_hash = excluded.content_hash,
                extracted_at = excluded.extracted_at,
                index_state = 'unsupported'
            """,
            bindings: [.text(item.identity), .text(hash), .real(Date().timeIntervalSince1970)]
        )
        try? execute("DELETE FROM content_fts WHERE file_identity = ?", bindings: [.text(item.identity)])
    }

    /// Ricerca full-text: ritorna le identità dei file il cui nome o contenuto corrisponde
    /// alla query. Ogni termine diventa un match di prefisso (`termine*`), combinati in AND.
    func searchFileContent(_ rawQuery: String) -> Set<String> {
        guard let matchQuery = Self.ftsMatchQuery(from: rawQuery) else { return [] }
        var statement: OpaquePointer?
        guard (try? prepare("SELECT file_identity FROM content_fts WHERE content_fts MATCH ?", statement: &statement)) != nil else { return [] }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(matchQuery)], to: statement)

        var result: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.insert(columnText(statement, 0))
        }
        return result
    }

    /// Come `searchFileContent`, ma ritorna le identità ORDINATE per rilevanza testuale (bm25:
    /// più rilevante prima). Serve alla ricerca ibrida per costruire il ranking FTS da fondere
    /// con quello semantico via Reciprocal Rank Fusion.
    func searchFileContentRanked(_ rawQuery: String) async -> [String] {
        guard let matchQuery = Self.ftsMatchQuery(from: rawQuery) else { return [] }
        guard let contentDatabaseActor else { return [] }
        return (try? await contentDatabaseActor.searchFileContentRanked(matchQuery: matchQuery)) ?? []
    }

    /// Costruisce una query MATCH FTS5 sicura: estrae solo token alfanumerici (così eventuali
    /// caratteri speciali non rompono la sintassi) e li trasforma in prefissi in AND.
    static func ftsMatchQuery(from raw: String) -> String? {
        let terms = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\($0)*" }.joined(separator: " ")
    }

    // MARK: - Comprensione della domanda (query understanding)

    /// Parole "vuote" (articoli, preposizioni, congiunzioni, ausiliari e parole interrogative) in
    /// italiano e inglese: vengono scartate dai termini significativi così la domanda in linguaggio
    /// naturale non pesa il retrieval su parole senza contenuto ("quali sono i…", "what is the…").
    nonisolated private static let queryStopwords: Set<String> = [
        // Italiano — articoli, preposizioni (semplici e articolate), congiunzioni
        "il", "lo", "la", "gli", "le", "un", "uno", "una", "di", "del", "dello", "della", "dei",
        "degli", "delle", "al", "allo", "alla", "ai", "agli", "alle", "da", "dal", "dallo", "dalla",
        "dai", "dagli", "dalle", "in", "nel", "nello", "nella", "nei", "negli", "nelle", "con", "col",
        "coi", "su", "sul", "sullo", "sulla", "sui", "sugli", "sulle", "per", "tra", "fra", "ed", "od",
        "ma", "se", "che", "chi", "cui", "non", "come", "dove", "quando", "quanto", "quanti", "quante",
        "quanta", "quale", "quali", "cosa", "cos", "perche", "perché", "sono", "sia", "siano", "essere",
        "hai", "hanno", "abbiamo", "avere", "questo", "questa", "questi", "queste", "quello", "quella",
        "quelli", "quelle", "più", "meno", "molto", "poco", "tutto", "tutti", "tutte", "tutta", "anche",
        "ancora", "già", "solo", "mio", "mia", "miei", "mie", "tuo", "tua", "suo", "sua", "ci", "vi",
        "ne", "mi", "ti", "si", "lei", "lui", "loro", "noi", "voi", "dammi", "dimmi", "elenca", "mostra",
        // Inglese — articoli, preposizioni, ausiliari, parole interrogative
        "the", "an", "of", "to", "on", "for", "and", "or", "but", "if", "is", "are", "was", "were",
        "be", "been", "being", "what", "which", "who", "whom", "whose", "where", "when", "why", "how",
        "that", "this", "these", "those", "with", "as", "by", "at", "from", "about", "into", "does",
        "did", "can", "could", "would", "should", "you", "your", "his", "her", "its", "our", "their",
        "all", "any", "some", "more", "most", "list", "show", "tell", "give", "there", "here", "will"
    ]

    /// Estrae i termini "significativi" da una domanda: token alfanumerici, minuscoli, distinti,
    /// lunghi almeno 2 caratteri e non presenti tra le stopword. Serve a capire di cosa parla la
    /// domanda per pesare la pertinenza lessicale del retrieval (non solo la vicinanza vettoriale).
    nonisolated static func meaningfulTerms(from raw: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for token in raw.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard token.count >= 2, !queryStopwords.contains(token), !seen.contains(token) else { continue }
            seen.insert(token)
            terms.append(token)
        }
        return terms
    }

    /// Reciprocal Rank Fusion tra più elenchi ordinati (per posizione): il punteggio di un elemento
    /// è la somma di 1/(k + posizione) su tutti gli elenchi in cui compare. Ritorna gli elementi
    /// riordinati (migliori prima). Con un solo elenco lo restituisce invariato.
    private static func fuseRanks(_ lists: [[Int]], k: Double = 60) -> [Int] {
        if lists.count <= 1 { return lists.first ?? [] }
        var scores: [Int: Double] = [:]
        for list in lists {
            for (position, index) in list.enumerated() {
                scores[index, default: 0] += 1.0 / (k + Double(position + 1))
            }
        }
        return scores.sorted { $0.value > $1.value }.map { $0.key }
    }

    // MARK: - Ricerca semantica (Fase 1: embedding vettoriali)

    /// Testo estratto già salvato per un file (usato per rigenerare i vettori senza ri-estrarre).
    func extractedText(for identity: String) async -> String? {
        if let contentDatabaseActor { return await contentDatabaseActor.extractedText(identity: identity) }
        var statement: OpaquePointer?
        guard (try? prepare("SELECT extracted_text FROM file_content WHERE file_identity = ?", statement: &statement)) != nil else { return nil }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(identity)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let text = columnText(statement, 0)
        return text.isEmpty ? nil : text
    }

    /// Vero se il file ha già almeno un embedding calcolato (qualsiasi motore).
    func hasVectors(for identity: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM content_chunks c JOIN chunk_vectors v ON v.chunk_id = c.id WHERE c.file_identity = ? LIMIT 1"
        guard (try? prepare(sql, statement: &statement)) != nil else { return false }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(identity)], to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Vero se tutti i chunk del file hanno embedding del MOTORE indicato.
    /// Serve a evitare di saltare file che hanno vettori di un altro motore quando si cambia provider.
    func hasVectors(for identity: String, providerPrefix: String) async -> Bool {
        if let contentDatabaseActor { return await contentDatabaseActor.hasVectors(identity: identity, providerPrefix: providerPrefix) }
        var statement: OpaquePointer?
        let sql = """
            SELECT 1 FROM content_chunks c
            LEFT JOIN chunk_vectors v ON v.chunk_id = c.id AND v.provider_id LIKE ?
            WHERE c.file_identity = ?
            GROUP BY c.file_identity
            HAVING COUNT(c.id) > 0 AND COUNT(v.chunk_id) = COUNT(c.id)
            """
        guard (try? prepare(sql, statement: &statement)) != nil else { return false }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(providerPrefix + "%"), .text(identity)], to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Sostituisce i chunk e i vettori di un file (elimina i precedenti in cascata, poi inserisce).
    func replaceChunks(for identity: String, chunks: [(ordinal: Int, text: String, providerID: String, vector: [Float])]) async {
        if let contentDatabaseActor {
            try? await contentDatabaseActor.replaceChunks(identity: identity, chunks: chunks)
            return
        }
        do {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            try execute("DELETE FROM content_chunks WHERE file_identity = ?", bindings: [.text(identity)])
            for chunk in chunks {
                try execute(
                "INSERT INTO content_chunks (file_identity, ordinal, text) VALUES (?, ?, ?)",
                bindings: [.text(identity), .int(chunk.ordinal), .text(chunk.text)]
                )
                let chunkID = sqlite3_last_insert_rowid(db)
                try execute(
                "INSERT INTO chunk_vectors (chunk_id, provider_id, dimension, vector, norm) VALUES (?, ?, ?, ?, ?)",
                bindings: [.int(Int(chunkID)), .text(chunk.providerID), .int(chunk.vector.count), .blob(Self.data(from: chunk.vector)), .real(Double(Self.norm(chunk.vector)))]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
        }
    }

    /// Ricerca semantica: confronta il vettore della query (coseno) con i vettori dei chunk dello
    /// stesso `providerID`, limitando ai file candidati. Ritorna un punteggio per file (il migliore
    /// tra i suoi chunk), ordinato dal più simile, con `limit` risultati.
    func semanticSearch(queryVector: [Float], providerID: String, candidates: Set<String>, limit: Int) -> [(identity: String, score: Float)] {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            Self.performanceLog.debug("semanticSearch candidati=\(candidates.count) durata_ms=\((CFAbsoluteTimeGetCurrent() - startedAt) * 1000, format: .fixed(precision: 1))")
        }
        guard !queryVector.isEmpty, !candidates.isEmpty else { return [] }

        var statement: OpaquePointer?
        guard prepareSemanticCandidates(candidates) else { return [] }
        let sql = """
            SELECT c.file_identity, v.vector, v.norm
            FROM chunk_vectors v
            JOIN content_chunks c ON c.id = v.chunk_id
            JOIN temp.semantic_candidates sc ON sc.identity = c.file_identity
            WHERE v.provider_id = ? AND v.dimension = ?
            """
        guard (try? prepare(sql, statement: &statement)) != nil else { return [] }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(providerID), .int(queryVector.count)], to: statement)

        let queryNorm = Self.norm(queryVector)
        guard queryNorm > 0 else { return [] }

        var bestByFile: [String: Float] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let identity = columnText(statement, 0)
            guard let blob = columnBlob(statement, 1) else { continue }
            let vector = Self.floats(from: blob)
            guard vector.count == queryVector.count else { continue }
            let storedNorm = Float(sqlite3_column_double(statement, 2))
            let vectorNorm = storedNorm > 0 ? storedNorm : Self.norm(vector)
            let score = Self.cosine(queryVector, vector, aNorm: queryNorm, bNorm: vectorNorm)
            if let existing = bestByFile[identity] {
                if score > existing { bestByFile[identity] = score }
            } else {
                bestByFile[identity] = score
            }
        }

        return bestByFile
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (identity: $0.key, score: $0.value) }
    }

    func semanticSearchAsync(queryVector: [Float], providerID: String, candidates: Set<String>, limit: Int) async -> [(identity: String, score: Float)] {
        guard let contentDatabaseActor, !queryVector.isEmpty, !candidates.isEmpty else { return [] }
        let rows = await contentDatabaseActor.semanticRows(candidates: candidates, querySpaces: [providerID])
            .filter { $0.providerID == providerID && $0.vector.count == queryVector.count }
        return await Task.detached(priority: .userInitiated) {
            let queryNorm = Self.norm(queryVector)
            guard queryNorm > 0 else { return [] }
            var best: [String: Float] = [:]
            for row in rows {
                let score = Self.cosine(queryVector, row.vector, aNorm: queryNorm, bNorm: row.storedNorm)
                best[row.identity] = max(best[row.identity] ?? -.greatestFiniteMagnitude, score)
            }
            return best.sorted { $0.value > $1.value }.prefix(limit).map { (identity: $0.key, score: $0.value) }
        }.value
    }

    /// "Trova simili a questo": usa i vettori del file dato come query. Prende il centroide dei
    /// chunk del provider DOMINANTE del file (coerente per dimensione), poi riusa `semanticSearch`
    /// per trovare i file più simili tra i candidati, escluso il file stesso.
    func similarFiles(to identity: String, providerPrefix: String, candidates: Set<String>, limit: Int) -> [(identity: String, score: Float)] {
        guard !candidates.isEmpty else { return [] }

        // Carica i vettori del file raggruppati per provider_id (solo quelli del motore attivo).
        var byProvider: [String: [[Float]]] = [:]
        var statement: OpaquePointer?
        let sql = """
            SELECT v.provider_id, v.vector
            FROM chunk_vectors v
            JOIN content_chunks c ON c.id = v.chunk_id
            WHERE c.file_identity = ? AND v.provider_id LIKE ?
            """
        if (try? prepare(sql, statement: &statement)) != nil {
            try? bind([.text(identity), .text(providerPrefix + "%")], to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let blob = columnBlob(statement, 1) else { continue }
                byProvider[columnText(statement, 0), default: []].append(Self.floats(from: blob))
            }
        }
        sqlite3_finalize(statement)

        // Provider dominante (più chunk) → tutti i suoi vettori hanno la stessa dimensione.
        guard let (providerID, vectors) = byProvider.max(by: { $0.value.count < $1.value.count }),
              let dimension = vectors.first?.count, dimension > 0 else { return [] }

        // Centroide dei chunk del file.
        var centroid = [Float](repeating: 0, count: dimension)
        var used: Float = 0
        for vector in vectors where vector.count == dimension {
            for i in 0..<dimension { centroid[i] += vector[i] }
            used += 1
        }
        guard used > 0 else { return [] }
        for i in 0..<dimension { centroid[i] /= used }

        return semanticSearch(queryVector: centroid, providerID: providerID,
                              candidates: candidates.subtracting([identity]), limit: limit)
    }

    func similarFilesAsync(to identity: String, providerPrefix: String, candidates: Set<String>, limit: Int) async -> [(identity: String, score: Float)] {
        guard let contentDatabaseActor else { return [] }
        let providers = await contentDatabaseActor.distinctProviderIDs().filter { $0.hasPrefix(providerPrefix) }
        guard !providers.isEmpty else { return [] }
        let rows = await contentDatabaseActor.semanticRows(candidates: candidates.union([identity]), querySpaces: Set(providers))
        let grouped = Dictionary(grouping: rows.filter { $0.identity == identity && !$0.vector.isEmpty }, by: \.providerID)
        guard let (providerID, ownRows) = grouped.max(by: { $0.value.count < $1.value.count }),
              let dimension = ownRows.first?.vector.count, dimension > 0 else { return [] }
        var centroid = [Float](repeating: 0, count: dimension)
        var count: Float = 0
        for row in ownRows where row.vector.count == dimension {
            for index in centroid.indices { centroid[index] += row.vector[index] }
            count += 1
        }
        guard count > 0 else { return [] }
        for index in centroid.indices { centroid[index] /= count }
        return await semanticSearchAsync(
            queryVector: centroid, providerID: providerID,
            candidates: candidates.subtracting([identity]), limit: limit
        )
    }

    // MARK: - Utility vettori

    /// Serializza [Float] in Data (Float32) e viceversa; coseno via Accelerate.
    private static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated private static func floats(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    nonisolated private static func norm(_ v: [Float]) -> Float {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        return sqrt(sumSquares)
    }

    /// Coseno tra due vettori della stessa dimensione. Le norme di `a` e `b` possono essere passate
    /// precalcolate (query e vettore memorizzato) per non ricalcolarle a ogni confronto: rimane
    /// solo il prodotto scalare.
    nonisolated private static func cosine(_ a: [Float], _ b: [Float], aNorm: Float? = nil, bNorm: Float? = nil) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        let denom = (aNorm ?? norm(a)) * (bNorm ?? norm(b))
        return denom > 0 ? dot / denom : 0
    }
}

private enum SQLiteBinding {
    case text(String)
    case int(Int)
    case intOptional(Int?)
    case real(Double)
    case blob(Data?)
}

private enum StoreError: Error {
    case sqlite(message: String)
}

private extension MetadataStore {
    /// Popola una tabella temporanea indicizzata per spostare il filtro dei candidati dentro
    /// SQLite. Evita di leggere e deserializzare vettori appartenenti ad altre cartelle.
    func prepareSemanticCandidates(_ identities: Set<String>) -> Bool {
        do {
            try prepareIdentityTable(name: "semantic_candidates", identities: identities)
            return true
        } catch {
            try? execute("ROLLBACK")
            return false
        }
    }

    func prepareIdentityTable(name: String, identities: Set<String>) throws {
        // `name` proviene esclusivamente da costanti interne, mai da input utente.
        try execute("CREATE TEMP TABLE IF NOT EXISTS \(name) (identity TEXT PRIMARY KEY) WITHOUT ROWID")
        try execute("DELETE FROM temp.\(name)")
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for identity in identities {
                try execute("INSERT INTO temp.\(name)(identity) VALUES (?)", bindings: [.text(identity)])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastErrorMessage: String {
        if let db, let message = sqlite3_errmsg(db) {
            return String(cString: message)
        }

        return "Unknown SQLite error"
    }

    func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return
            }
            if result == SQLITE_ROW {
                continue
            }

            throw StoreError.sqlite(message: lastErrorMessage)
        }
    }

    /// Variante di `execute` che riusa uno statement preparato dalla cache. Da usare SOLO per
    /// SQL fisso ad alta frequenza (nessun placeholder di conteggio variabile), così da non far
    /// crescere illimitatamente la cache. Lo statement viene resettato dopo l'uso.
    func executeCached(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        let statement = try cachedStatement(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(bindings, to: statement)

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result == SQLITE_ROW { continue }
            throw StoreError.sqlite(message: lastErrorMessage)
        }
    }

    private func cachedStatement(_ sql: String) throws -> OpaquePointer? {
        if let existing = statementCache[sql] {
            sqlite3_reset(existing)
            sqlite3_clear_bindings(existing)
            return existing
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(message: lastErrorMessage)
        }
        statementCache[sql] = statement
        return statement
    }

    func intValue(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(message: lastErrorMessage)
        }
    }

    func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32

            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case .int(let value):
                result = sqlite3_bind_int(statement, position, Int32(value))
            case .intOptional(let value):
                if let value {
                    result = sqlite3_bind_int64(statement, position, Int64(value))
                } else {
                    result = sqlite3_bind_null(statement, position)
                }
            case .real(let value):
                result = sqlite3_bind_double(statement, position, value)
            case .blob(let data):
                if let data {
                    result = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                    }
                } else {
                    result = sqlite3_bind_null(statement, position)
                }
            }

            guard result == SQLITE_OK else {
                throw StoreError.sqlite(message: lastErrorMessage)
            }
        }
    }

    func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let length = sqlite3_column_bytes(statement, index)
        guard length > 0 else { return nil }
        return Data(bytes: pointer, count: Int(length))
    }

    func columnInt64Optional(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    /// Aggiunge una colonna se non già presente (migrazione incrementale dello schema).
    func addColumnIfMissing(table: String, column: String, definition: String) throws {
        var statement: OpaquePointer?
        try prepare("PRAGMA table_info(\(table))", statement: &statement)
        defer { sqlite3_finalize(statement) }

        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, 1) == column {
                exists = true
                break
            }
        }

        if !exists {
            try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
        }
    }

    func deleteValuesNotInOptions(fieldID: String, allowedLabels: Set<String>) throws {
        guard !allowedLabels.isEmpty else {
            try execute("DELETE FROM metadata_values WHERE field_id = ?", bindings: [.text(fieldID)])
            return
        }

        let placeholders = Array(repeating: "?", count: allowedLabels.count).joined(separator: ",")
        let sql = "DELETE FROM metadata_values WHERE field_id = ? AND value NOT IN (\(placeholders))"
        let bindings = [.text(fieldID)] + allowedLabels.sorted().map { SQLiteBinding.text($0) }
        try execute(sql, bindings: bindings)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
