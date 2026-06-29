import Foundation
import SQLite3

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
    @Published private(set) var metadataByFileIdentity: [String: FileMetadata] = [:]

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

    /// Identità già presenti nella tabella `files`: evita di registrare di nuovo file noti.
    private var registeredIdentities: Set<String> = []

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

        // Nota: niente più `bookmarkData` qui — era una syscall costosa fatta per ogni file
        // ad ogni navigazione e non veniva mai riletta. Si può reintrodurre lazy se servirà.
        try execute(
            """
            INSERT INTO files (identity, file_resource_identifier, volume_identifier, bookmark_data, last_known_path, name, is_directory, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(identity) DO UPDATE SET
                file_resource_identifier = excluded.file_resource_identifier,
                volume_identifier = excluded.volume_identifier,
                last_known_path = excluded.last_known_path,
                name = excluded.name,
                is_directory = excluded.is_directory,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(identity),
                .text(fileIdentifier),
                .text(volumeIdentifier),
                .blob(nil),
                .text(fileURL.path),
                .text(fileURL.lastPathComponent),
                .int((values.isDirectory ?? false) ? 1 : 0),
                .real(Date().timeIntervalSince1970)
            ]
        )

        registeredIdentities.insert(identity)
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

    /// Aggiorna subito lo stato in memoria (UI reattiva) e posticipa la scrittura su disco.
    func update(item: FileItem, field: MetadataField, value: String) {
        ensureRegistered(item)
        setInMemoryValue(identity: item.identity, fieldID: field.id, value: value)
        scheduleWrite(identity: item.identity, fieldID: field.id, value: value)
    }

    /// Assegna lo stesso valore a più elementi in un'unica transazione (modifica in blocco).
    func updateBulk(items: [FileItem], field: MetadataField, value: String) {
        guard !items.isEmpty else { return }

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
            refreshPublishedState()
        } catch {
            assertionFailure("Failed to add metadata field: \(error)")
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
            refreshPublishedState()
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
    func reconcileMovedItem(previousIdentity: String, newURL: URL) throws -> String {
        // La cache path→identity può contenere voci stale dopo uno spostamento/rinomina.
        identityCacheByPath.removeAll()
        let newIdentity = try registerFile(at: newURL)
        guard previousIdentity != newIdentity else {
            refreshPublishedState()
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

        refreshPublishedState()
        return newIdentity
    }

    private func openDatabase() throws {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            throw StoreError.sqlite(message: lastErrorMessage)
        }

        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
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
                updated_at REAL NOT NULL
            )
            """
        )

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
}

private enum SQLiteBinding {
    case text(String)
    case int(Int)
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
