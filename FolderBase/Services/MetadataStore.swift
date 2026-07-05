import Foundation
import SQLite3
import Accelerate

struct FileMetadata: Codable, Equatable {
    var values: [String: String]

    static let empty = FileMetadata(values: [:])
}

private struct LegacyMetadataDocument: Codable {
    var fieldsByFolder: [String: [MetadataField]]
    var metadataByPath: [String: FileMetadata]
}

final class MetadataStore: ObservableObject {
    @Published private(set) var fieldsByFolder: [String: [MetadataField]] = [:]

    /// Non-@Published: la notifica a SwiftUI è gestita manualmente (vedi
    /// `notifyMetadataChanged`) così le modifiche "per tasto" vengono coalizzate invece
    /// di invalidare l'intera tabella a ogni carattere digitato.
    private(set) var metadataByFileIdentity: [String: FileMetadata] = [:]

    private let dbURL: URL
    private let legacyMetadataURL: URL
    private var db: OpaquePointer?

    /// Cache path → identity per evitare di calcolare/registrare l'identità sul disco
    /// nei percorsi di sola lettura (chiamati ad ogni render di SwiftUI).
    private var identityCacheByPath: [String: String] = [:]

    /// Scritture su disco posticipate (debounce), indicizzate per chiave file+campo.
    private var pendingWrites: [String: DispatchWorkItem] = [:]
    private var pendingValues: [String: (identity: String, fieldID: String, value: String)] = [:]
    private let writeDebounce: TimeInterval = 0.4

    /// Notifica posticipata a SwiftUI per i cambi metadata (vedi `notifyMetadataChanged`).
    private var pendingChangeNotification: DispatchWorkItem?
    private let notifyDebounce: TimeInterval = 0.2

    /// Identità già presenti nella tabella `files`: evita di registrare di nuovo file noti.
    private var registeredIdentities: Set<String> = []

    /// Cache di `managedDirectories()`: viene chiamata a ogni navigazione (per
    /// riconfigurare FSEvents) ma il suo contenuto cambia solo quando si registrano,
    /// spostano o eliminano file gestiti.
    private var managedDirectoriesCache: [String]?

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderBase", isDirectory: true)

        self.dbURL = supportURL.appendingPathComponent("folderbase.sqlite")
        self.legacyMetadataURL = supportURL.appendingPathComponent("metadata.json")

        do {
            try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try openDatabase()
            try migrateSchema()
            try migrateLegacyJSONIfNeeded()
            registeredIdentities = (try? loadRegisteredIdentities()) ?? []
            refreshPublishedState()
        } catch {
            assertionFailure("Failed to initialize metadata store: \(error)")
            fieldsByFolder = [:]
            metadataByFileIdentity = [:]
        }
    }

    deinit {
        flushPendingWrites()
        sqlite3_close(db)
    }

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
    func fields(for folderURL: URL?) -> [MetadataField] {
        guard let folderURL, let identity = identity(for: folderURL) else { return [] }
        return fieldsByFolder[identity] ?? []
    }

    func metadata(for item: FileItem) -> FileMetadata {
        metadataByFileIdentity[item.identity] ?? .empty
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
            objectWillChange.send()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChangeNotification = nil
            self.objectWillChange.send()
        }
        pendingChangeNotification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + notifyDebounce, execute: work)
    }

    /// Assegna lo stesso valore a più elementi in un'unica transazione (modifica in blocco).
    func updateBulk(items: [FileItem], field: MetadataField, value: String) {
        guard !items.isEmpty else { return }

        notifyMetadataChanged(immediate: true)
        for item in items {
            ensureRegistered(item)
            setInMemoryValue(identity: item.identity, fieldID: field.id, value: value)
            cancelPendingWrite(identity: item.identity, fieldID: field.id)
        }

        do {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            for item in items {
                try execute(
                    """
                    INSERT INTO metadata_values (file_identity, field_id, value)
                    VALUES (?, ?, ?)
                    ON CONFLICT(file_identity, field_id) DO UPDATE SET value = excluded.value
                    """,
                    bindings: [.text(item.identity), .text(field.id), .text(value)]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            assertionFailure("Failed bulk metadata update: \(error)")
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
            try execute(
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

            try execute("BEGIN IMMEDIATE TRANSACTION")
            for templateField in template.fields {
                let trimmedName = templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { continue }

                let field = MetadataField(
                    id: UUID().uuidString,
                    name: trimmedName,
                    kind: templateField.kind,
                    options: normalizedOptions(for: templateField.kind, options: templateField.options)
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
            }
            try execute("COMMIT")

            fieldsByFolder[folderIdentity, default: []].append(contentsOf: appended)
        } catch {
            try? execute("ROLLBACK")
            assertionFailure("Failed to apply template: \(error)")
        }
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
    }

    /// Ritrova la posizione attuale del file di una riga, con salvaguardia anti riuso-inode.
    private func resolve(_ row: FileRow) -> RowResolution {
        let fm = FileManager.default

        // 1) Bookmark: àncora autorevole (segue spostamenti/rinomini, anche tra volumi).
        if let data = row.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                let newIdentity = Self.computeIdentity(for: url)
                if let newIdentity, newIdentity != row.identity {
                    return .relocated(url)
                }
                return .present(url)
            }
        }

        // 2) Fallback sull'ultimo percorso noto.
        if fm.fileExists(atPath: row.lastKnownPath) {
            let url = URL(fileURLWithPath: row.lastKnownPath)
            let newIdentity = Self.computeIdentity(for: url)
            if let newIdentity, newIdentity != row.identity {
                // Stesso percorso ma inode diverso: potrebbe essere un altro file (inode riusato).
                // Riaggancio solo se nome E dimensione coincidono con quanto memorizzato.
                let current = Self.nameAndSize(for: url)
                if current.name == row.name, current.size == row.size {
                    return .relocated(url)
                }
                return .missing
            }
            return .present(url)
        }

        return .missing
    }

    /// Evita riconciliazioni sovrapposte (es. raffiche di eventi FSEvents).
    private var isReconciling = false

    /// Riallinea il DB al filesystem: aggiorna percorsi/nomi/bookmark dei file spostati o
    /// rinominati altrove, e raccoglie quelli non più trovabili (orfani). Non cancella nulla.
    ///
    /// La parte costosa (risoluzione bookmark + stat sul filesystem per ogni file gestito)
    /// gira su un thread di background: prima bloccava il main thread all'avvio e a ogni
    /// evento FSEvents. Le letture/scritture del DB restano sul main thread.
    func reconcileManagedFiles(completion: @escaping (_ relocated: Int, _ missingIdentities: [String]) -> Void) {
        guard !isReconciling else {
            completion(0, [])
            return
        }

        let rows = (try? loadFileRows()) ?? []
        guard !rows.isEmpty else {
            completion(0, [])
            return
        }

        isReconciling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // `resolve` è puro filesystem (bookmark, stat): nessuno stato del DB toccato.
            let resolutions = rows.map { row in (row, self.resolve(row)) }

            DispatchQueue.main.async {
                var relocated = 0
                var missingIdentities: [String] = []

                for (row, resolution) in resolutions {
                    switch resolution {
                    case .present(let url):
                        if url.path != row.lastKnownPath {
                            relocated += 1
                        }
                        self.updateTracking(row, to: url)
                    case .relocated(let url):
                        // La refresh completa avviene una sola volta a fine ciclo.
                        _ = try? self.reconcileMovedItem(previousIdentity: row.identity, newURL: url, refreshingState: false)
                        relocated += 1
                    case .missing:
                        missingIdentities.append(row.identity)
                    }
                }

                self.identityCacheByPath.removeAll()
                self.refreshPublishedState()
                self.isReconciling = false
                completion(relocated, missingIdentities)
            }
        }
    }

    /// Identità delle righe il cui file non è più trovabile (metadata orfani).
    func orphanedIdentities() -> [String] {
        let rows = (try? loadFileRows()) ?? []
        return rows.compactMap { row in
            if case .missing = resolve(row) { return row.identity }
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

    private static func computeIdentity(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]) else {
            return nil
        }
        return identity(for: url, resourceValues: values)
    }

    private static func nameAndSize(for url: URL) -> (name: String, size: Int64?) {
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
    func backup(to destinationURL: URL) throws {
        flushPendingWrites()

        // Un file preesistente verrebbe aperto e "unito": lo rimuoviamo per ripartire pulito
        // (rimuovo anche eventuali sidecar WAL/SHM di un backup interrotto in passato).
        let fm = FileManager.default
        try? fm.removeItem(at: destinationURL)
        try? fm.removeItem(at: URL(fileURLWithPath: destinationURL.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: destinationURL.path + "-shm"))

        var destDB: OpaquePointer?
        guard sqlite3_open(destinationURL.path, &destDB) == SQLITE_OK else {
            let message = destDB.map { String(cString: sqlite3_errmsg($0)) } ?? "Impossibile aprire il file di destinazione"
            sqlite3_close(destDB)
            throw StoreError.sqlite(message: message)
        }
        defer { sqlite3_close(destDB) }

        guard let backup = sqlite3_backup_init(destDB, "main", db, "main") else {
            throw StoreError.sqlite(message: String(cString: sqlite3_errmsg(destDB)))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)

        guard stepResult == SQLITE_DONE else {
            throw StoreError.sqlite(message: String(cString: sqlite3_errmsg(destDB)))
        }
    }

    /// Sostituisce il database gestito con quello contenuto in `sourceURL`.
    /// Il file di origine viene prima validato (integrità + presenza dello schema
    /// FolderBase); solo se è valido il database corrente viene chiuso e rimpiazzato,
    /// poi riaperto e lo stato pubblicato ricaricato. In caso di file non valido lancia
    /// un errore SENZA toccare il database attuale.
    func restore(from sourceURL: URL) throws {
        try validateBackup(at: sourceURL)

        // Le scritture posticipate riguardano il DB che stiamo per sostituire: annullale.
        for (_, work) in pendingWrites { work.cancel() }
        pendingWrites.removeAll()
        pendingValues.removeAll()
        pendingChangeNotification?.cancel()
        pendingChangeNotification = nil

        sqlite3_close(db)
        db = nil

        let fm = FileManager.default
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
        try? fm.removeItem(at: walURL)
        try? fm.removeItem(at: shmURL)
        if fm.fileExists(atPath: dbURL.path) {
            try fm.removeItem(at: dbURL)
        }
        try fm.copyItem(at: sourceURL, to: dbURL)

        try openDatabase()
        try migrateSchema()
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
        try execute(
            """
            CREATE TABLE IF NOT EXISTS file_content (
                file_identity TEXT PRIMARY KEY,
                extracted_text TEXT,
                ocr_used INTEGER NOT NULL DEFAULT 0,
                content_hash TEXT,
                extracted_at REAL,
                index_state TEXT NOT NULL DEFAULT 'pending',
                FOREIGN KEY(file_identity) REFERENCES files(identity) ON DELETE CASCADE
            )
            """
        )

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
        metadataByFileIdentity = (try? loadMetadata()) ?? [:]
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

    private func loadMetadata() throws -> [String: FileMetadata] {
        var result: [String: FileMetadata] = [:]
        var statement: OpaquePointer?
        let sql = "SELECT file_identity, field_id, value FROM metadata_values"
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
    static func fileIdentity(fileIdentifier: String, volumeIdentifier: String, path: String) -> String {
        if !fileIdentifier.isEmpty, !volumeIdentifier.isEmpty {
            return "\(volumeIdentifier):\(fileIdentifier)"
        }

        return "path:\(path)"
    }

    static func stableDescription(_ value: Any?) -> String {
        guard let value else { return "" }
        return String(describing: value)
    }

    static func identity(for fileURL: URL, resourceValues: URLResourceValues) -> String {
        fileIdentity(
            fileIdentifier: stableDescription(resourceValues.fileResourceIdentifier),
            volumeIdentifier: stableDescription(resourceValues.volumeIdentifier),
            path: fileURL.path
        )
    }

    // MARK: - Indicizzazione contenuti (Fase 0: estrazione + full-text search)

    /// Hash di change-detection dei soli file già **indicizzati** con successo (nil altrimenti).
    /// Usato dall'`IndexingService` per saltare i file immutati; i file marcati "unsupported"
    /// ritornano nil di proposito, così vengono riprovati (utile quando l'estrattore impara
    /// nuovi formati) senza doverli modificare.
    func contentHash(for identity: String) -> String? {
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
    func identitiesWithVectors(providerPrefix: String) -> Set<String> {
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

    /// Recupero dei chunk più simili per la CHAT (RAG): oltre a identità e punteggio ritorna il
    /// testo del chunk e nome/percorso del file per costruire il prompt e citare le fonti.
    /// Se `candidates` è vuoto, cerca su tutto l'indice.
    func semanticChunks(queryVector: [Float], providerID: String, candidates: Set<String>, limit: Int) -> [(identity: String, path: String, name: String, text: String, score: Float)] {
        guard !queryVector.isEmpty else { return [] }
        var statement: OpaquePointer?
        let sql = """
            SELECT c.file_identity, f.last_known_path, f.name, c.text, v.vector
            FROM chunk_vectors v
            JOIN content_chunks c ON c.id = v.chunk_id
            JOIN files f ON f.identity = c.file_identity
            WHERE v.provider_id = ?
            """
        guard (try? prepare(sql, statement: &statement)) != nil else { return [] }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(providerID)], to: statement)

        let queryNorm = Self.norm(queryVector)
        guard queryNorm > 0 else { return [] }

        var scored: [(identity: String, path: String, name: String, text: String, score: Float)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let identity = columnText(statement, 0)
            if !candidates.isEmpty, !candidates.contains(identity) { continue }
            guard let blob = columnBlob(statement, 4) else { continue }
            let vector = Self.floats(from: blob)
            guard vector.count == queryVector.count else { continue }
            let score = Self.cosine(queryVector, vector, aNorm: queryNorm)
            scored.append((identity, columnText(statement, 1), columnText(statement, 2), columnText(statement, 3), score))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Mappa identità→hash di TUTTI i file indicizzati con successo. Usata per calcolare la
    /// copertura di indicizzazione di una cartella (stato verde/arancione).
    func indexedHashes() -> [String: String] {
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

    /// Salva il testo estratto da un file e aggiorna l'indice full-text. Registra prima il
    /// file nella tabella `files` (necessario per la foreign key) senza toccare il percorso
    /// caldo di navigazione.
    func storeExtractedText(for item: FileItem, text: String, ocrUsed: Bool, hash: String) {
        _ = try? registerFile(at: item.url)
        try? execute(
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
        try? execute("DELETE FROM content_fts WHERE file_identity = ?", bindings: [.text(item.identity)])
        try? execute(
            "INSERT INTO content_fts (file_identity, name, body) VALUES (?, ?, ?)",
            bindings: [.text(item.identity), .text(item.name), .text(text)]
        )
    }

    /// Marca un file come non supportato (nessun testo estraibile) salvando comunque l'hash,
    /// così l'indicizzazione non lo riprova finché il file non cambia.
    func markContentUnsupported(for item: FileItem, hash: String) {
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

    /// Costruisce una query MATCH FTS5 sicura: estrae solo token alfanumerici (così eventuali
    /// caratteri speciali non rompono la sintassi) e li trasforma in prefissi in AND.
    static func ftsMatchQuery(from raw: String) -> String? {
        let terms = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\($0)*" }.joined(separator: " ")
    }

    // MARK: - Ricerca semantica (Fase 1: embedding vettoriali)

    /// Testo estratto già salvato per un file (usato per rigenerare i vettori senza ri-estrarre).
    func extractedText(for identity: String) -> String? {
        var statement: OpaquePointer?
        guard (try? prepare("SELECT extracted_text FROM file_content WHERE file_identity = ?", statement: &statement)) != nil else { return nil }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(identity)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let text = columnText(statement, 0)
        return text.isEmpty ? nil : text
    }

    /// Vero se il file ha già almeno un embedding calcolato.
    func hasVectors(for identity: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM content_chunks c JOIN chunk_vectors v ON v.chunk_id = c.id WHERE c.file_identity = ? LIMIT 1"
        guard (try? prepare(sql, statement: &statement)) != nil else { return false }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(identity)], to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Sostituisce i chunk e i vettori di un file (elimina i precedenti in cascata, poi inserisce).
    func replaceChunks(for identity: String, chunks: [(ordinal: Int, text: String, providerID: String, vector: [Float])]) {
        try? execute("DELETE FROM content_chunks WHERE file_identity = ?", bindings: [.text(identity)])
        for chunk in chunks {
            try? execute(
                "INSERT INTO content_chunks (file_identity, ordinal, text) VALUES (?, ?, ?)",
                bindings: [.text(identity), .int(chunk.ordinal), .text(chunk.text)]
            )
            let chunkID = sqlite3_last_insert_rowid(db)
            try? execute(
                "INSERT INTO chunk_vectors (chunk_id, provider_id, dimension, vector) VALUES (?, ?, ?, ?)",
                bindings: [.int(Int(chunkID)), .text(chunk.providerID), .int(chunk.vector.count), .blob(Self.data(from: chunk.vector))]
            )
        }
    }

    /// Ricerca semantica: confronta il vettore della query (coseno) con i vettori dei chunk dello
    /// stesso `providerID`, limitando ai file candidati. Ritorna un punteggio per file (il migliore
    /// tra i suoi chunk), ordinato dal più simile, con `limit` risultati.
    func semanticSearch(queryVector: [Float], providerID: String, candidates: Set<String>, limit: Int) -> [(identity: String, score: Float)] {
        guard !queryVector.isEmpty, !candidates.isEmpty else { return [] }

        var statement: OpaquePointer?
        let sql = """
            SELECT c.file_identity, v.vector
            FROM chunk_vectors v
            JOIN content_chunks c ON c.id = v.chunk_id
            WHERE v.provider_id = ?
            """
        guard (try? prepare(sql, statement: &statement)) != nil else { return [] }
        defer { sqlite3_finalize(statement) }
        try? bind([.text(providerID)], to: statement)

        let queryNorm = Self.norm(queryVector)
        guard queryNorm > 0 else { return [] }

        var bestByFile: [String: Float] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let identity = columnText(statement, 0)
            guard candidates.contains(identity), let blob = columnBlob(statement, 1) else { continue }
            let vector = Self.floats(from: blob)
            guard vector.count == queryVector.count else { continue }
            let score = Self.cosine(queryVector, vector, aNorm: queryNorm)
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

    // MARK: - Utility vettori

    /// Serializza [Float] in Data (Float32) e viceversa; coseno via Accelerate.
    private static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func floats(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    private static func norm(_ v: [Float]) -> Float {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        return sqrt(sumSquares)
    }

    /// Coseno tra due vettori della stessa dimensione. `aNorm` (norma di `a`) può essere passata
    /// precalcolata per non ricalcolarla a ogni confronto con la stessa query.
    private static func cosine(_ a: [Float], _ b: [Float], aNorm: Float? = nil) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        let denom = (aNorm ?? norm(a)) * norm(b)
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
