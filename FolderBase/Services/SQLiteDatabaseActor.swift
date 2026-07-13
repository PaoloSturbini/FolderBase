import Foundation
import SQLite3

private let SQLITE_ACTOR_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct FileTrackingUpdate: Sendable {
    let identity: String
    let path: String
    let name: String
    let size: Int64?
    let bookmark: Data?
}

/// Riga grezza per la ricerca semantica, prodotta dalla connessione di background. Contiene già il
/// vettore decodificato: il costoso passaggio BLOB→[Float] avviene fuori dal main thread.
struct SemanticRow: Sendable {
    let identity: String
    let path: String
    let name: String
    let text: String
    let providerID: String
    let vector: [Float]
    let storedNorm: Float
}

/// Connessione SQLite dedicata al lavoro potenzialmente costoso. L'actor garantisce che
/// statement e connessione non attraversino mai thread concorrenti e tiene il lavoro fuori dal
/// MainActor. La connessione principale resta temporaneamente responsabile delle migrazioni e
/// delle scritture; WAL rende le due connessioni cooperanti senza bloccare il rendering SwiftUI.
actor SQLiteDatabaseActor {
    enum DatabaseError: Error { case open(String), prepare(String), busy, invalidBackup(String) }

    private var db: OpaquePointer?
    /// Cache di prepared statement (chiave = SQL). Evita `sqlite3_prepare_v2`/`sqlite3_finalize`
    /// ad ogni chiamata sui percorsi caldi (upsert, insert chunk/vettori, tracking updates):
    /// gli statement vengono riusati con `sqlite3_reset` + `sqlite3_clear_bindings`.
    private var statementCache: [String: OpaquePointer] = [:]

    init(url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            sqlite3_close(connection)
            throw DatabaseError.open(message)
        }
        db = connection
        sqlite3_busy_timeout(connection, 5_000)
        sqlite3_exec(connection, "PRAGMA foreign_keys = ON", nil, nil, nil)
        sqlite3_exec(connection, "PRAGMA journal_mode = WAL", nil, nil, nil)
        // Sicuro sotto WAL: dimezza il costo dei COMMIT evitando l'fsync completo di ogni
        // transazione. Questa connessione esegue le scritture più pesanti (testo estratto,
        // chunk, vettori embedding) durante l'indicizzazione.
        sqlite3_exec(connection, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(connection, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        sqlite3_exec(connection, "PRAGMA cache_size = -16000", nil, nil, nil)
    }

    deinit {
        for statement in statementCache.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    func close() {
        for statement in statementCache.values { sqlite3_finalize(statement) }
        statementCache.removeAll()
        sqlite3_close(db)
        db = nil
    }

    func upsertMetadata(_ writes: [(identity: String, fieldID: String, value: String)]) throws {
        guard !writes.isEmpty else { return }
        try transaction {
            for write in writes {
                try execute(
                    """
                    INSERT INTO metadata_values (file_identity, field_id, value)
                    VALUES (?, ?, ?)
                    ON CONFLICT(file_identity, field_id) DO UPDATE SET value = excluded.value
                    """,
                    texts: [write.identity, write.fieldID, write.value]
                )
            }
        }
    }

    func purgeFiles(identities: [String]) throws {
        guard !identities.isEmpty else { return }
        try transaction {
            for identity in identities {
                try execute("DELETE FROM files WHERE identity = ?", texts: [identity])
            }
        }
    }

    func applyTrackingUpdates(_ updates: [FileTrackingUpdate]) throws {
        guard !updates.isEmpty else { return }
        try transaction {
            let sql = "UPDATE files SET last_known_path=?, name=?, size=?, bookmark_data=?, updated_at=? WHERE identity=?"
            for update in updates {
                let statement = try cachedStatement(sql)
                defer { sqlite3_reset(statement) }
                bindText(statement, 1, update.path)
                bindText(statement, 2, update.name)
                if let size = update.size { sqlite3_bind_int64(statement, 3, size) } else { sqlite3_bind_null(statement, 3) }
                if let bookmark = update.bookmark {
                    _ = bookmark.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(bookmark.count), SQLITE_ACTOR_TRANSIENT) }
                } else { sqlite3_bind_null(statement, 4) }
                sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
                bindText(statement, 6, update.identity)
                try stepDone(statement)
            }
        }
    }

    func backup(to destinationURL: URL, maxBusyRetries: Int = 100) async throws {
        var destination: OpaquePointer?
        guard sqlite3_open(destinationURL.path, &destination) == SQLITE_OK else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite backup open failed"
            sqlite3_close(destination)
            throw DatabaseError.open(message)
        }
        defer { sqlite3_close(destination) }
        guard let handle = sqlite3_backup_init(destination, "main", db, "main") else { throw prepareError() }
        var retries = 0
        var result: Int32 = SQLITE_OK
        repeat {
            result = sqlite3_backup_step(handle, 128)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                retries += 1
                guard retries <= maxBusyRetries else {
                    _ = sqlite3_backup_finish(handle)
                    throw DatabaseError.busy
                }
                try await Task.sleep(for: .milliseconds(20))
            } else if result == SQLITE_OK {
                retries = 0
                await Task.yield()
            }
        } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED
        let finish = sqlite3_backup_finish(handle)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw prepareError() }
    }

    nonisolated static func validateBackup(at url: URL, thorough: Bool) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw DatabaseError.invalidBackup("Il file non è un database SQLite valido")
        }
        defer { sqlite3_close(connection) }
        let check = thorough ? "PRAGMA integrity_check" : "PRAGMA quick_check"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, check, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_text(statement, 0).map({ String(cString: $0) }) == "ok" else {
            sqlite3_finalize(statement)
            throw DatabaseError.invalidBackup("Controllo di integrità non superato")
        }
        sqlite3_finalize(statement)
        let required = ["files", "metadata_fields", "metadata_values"]
        for table in required {
            guard sqlite3_prepare_v2(connection, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.invalidBackup("Schema non leggibile")
            }
            sqlite3_bind_text(statement, 1, table, -1, SQLITE_ACTOR_TRANSIENT)
            let exists = sqlite3_step(statement) == SQLITE_ROW
            sqlite3_finalize(statement)
            guard exists else { throw DatabaseError.invalidBackup("Schema FolderBase incompleto") }
        }
    }

    func loadMetadata(identities: Set<String>) throws -> [String: FileMetadata] {
        guard !identities.isEmpty else { return [:] }
        var result: [String: FileMetadata] = [:]
        let ids = Array(identities)
        for start in stride(from: 0, to: ids.count, by: 400) {
            let batch = Array(ids[start..<min(start + 400, ids.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let sql = "SELECT file_identity, field_id, value FROM metadata_values WHERE file_identity IN (\(placeholders))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw prepareError() }
            defer { sqlite3_finalize(statement) }
            for (offset, identity) in batch.enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 1), identity, -1, SQLITE_ACTOR_TRANSIENT)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let identity = text(statement, 0)
                var metadata = result[identity] ?? .empty
                metadata.values[text(statement, 1)] = text(statement, 2)
                result[identity] = metadata
            }
        }
        return result
    }

    func searchFileContentRanked(matchQuery: String) throws -> [String] {
        let sql = "SELECT file_identity FROM content_fts WHERE content_fts MATCH ? ORDER BY bm25(content_fts) ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw prepareError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, matchQuery, -1, SQLITE_ACTOR_TRANSIENT)
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 0)) }
        return result
    }

    func contentHash(identity: String) -> String? {
        scalarText("SELECT content_hash FROM file_content WHERE file_identity = ? AND index_state = 'indexed'", values: [identity])
    }

    func extractedText(identity: String) -> String? {
        scalarText("SELECT extracted_text FROM file_content WHERE file_identity = ?", values: [identity])
    }

    func hasVectors(identity: String, providerPrefix: String) -> Bool {
        let sql = """
            SELECT 1 FROM content_chunks c
            LEFT JOIN chunk_vectors v ON v.chunk_id = c.id AND v.provider_id LIKE ?
            WHERE c.file_identity = ?
            GROUP BY c.file_identity
            HAVING COUNT(c.id) > 0 AND COUNT(v.chunk_id) = COUNT(c.id)
            """
        return scalarText(sql, values: [providerPrefix + "%", identity]) != nil
    }

    func indexedHashes(state: String) -> [String: String] {
        var statement: OpaquePointer?
        let sql = "SELECT file_identity, content_hash FROM file_content WHERE index_state = ? AND content_hash IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, state, -1, SQLITE_ACTOR_TRANSIENT)
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0)] = text(statement, 1) }
        return result
    }

    func identitiesWithVectors(providerPrefix: String) -> Set<String> {
        let sql = """
            SELECT c.file_identity FROM content_chunks c
            LEFT JOIN chunk_vectors v ON v.chunk_id = c.id AND v.provider_id LIKE ?
            GROUP BY c.file_identity
            HAVING COUNT(c.id) > 0 AND COUNT(v.chunk_id) = COUNT(c.id)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, providerPrefix + "%", -1, SQLITE_ACTOR_TRANSIENT)
        var result: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW { result.insert(text(statement, 0)) }
        return result
    }

    /// Spazi (provider_id) presenti nell'indice. Eseguito sulla connessione di background.
    func distinctProviderIDs() -> [String] {
        guard let statement = try? cachedStatement("SELECT DISTINCT provider_id FROM chunk_vectors") else { return [] }
        defer { sqlite3_reset(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 0)) }
        return result
    }

    /// Legge e decodifica i chunk (con vettori) per la ricerca semantica, filtrando per candidati
    /// tramite una tabella temporanea indicizzata. Tutto il lavoro pesante (scansione, copia BLOB,
    /// decodifica in `[Float]`) resta sulla connessione di background, fuori dal main thread.
    /// Il vettore viene decodificato solo per gli spazi presenti in `querySpaces` (gli altri chunk
    /// servono comunque al punteggio lessicale su testo/nome): evita di deserializzare BLOB inutili.
    func semanticRows(candidates: Set<String>, querySpaces: Set<String>) -> [SemanticRow] {
        if !candidates.isEmpty, !prepareCandidateTable(candidates) { return [] }
        let sql = """
            SELECT c.file_identity, f.last_known_path, f.name, c.text, v.provider_id, v.vector, v.norm
            FROM chunk_vectors v
            JOIN content_chunks c ON c.id = v.chunk_id
            JOIN files f ON f.identity = c.file_identity
            \(candidates.isEmpty ? "" : "JOIN temp.semantic_candidates sc ON sc.identity = c.file_identity")
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [SemanticRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let providerID = text(statement, 4)
            var vector: [Float] = []
            if querySpaces.contains(providerID), let pointer = sqlite3_column_blob(statement, 5) {
                let length = Int(sqlite3_column_bytes(statement, 5))
                let count = length / MemoryLayout<Float>.stride
                if count > 0 {
                    vector = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                        memcpy(buffer.baseAddress, pointer, count * MemoryLayout<Float>.stride)
                        initialized = count
                    }
                }
            }
            rows.append(SemanticRow(
                identity: text(statement, 0),
                path: text(statement, 1),
                name: text(statement, 2),
                text: text(statement, 3),
                providerID: providerID,
                vector: vector,
                storedNorm: Float(sqlite3_column_double(statement, 6))
            ))
        }
        return rows
    }

    private func prepareCandidateTable(_ identities: Set<String>) -> Bool {
        do {
            try execute("CREATE TEMP TABLE IF NOT EXISTS semantic_candidates (identity TEXT PRIMARY KEY) WITHOUT ROWID", texts: [])
            try execute("DELETE FROM temp.semantic_candidates", texts: [])
            try transaction {
                for identity in identities {
                    try execute("INSERT INTO temp.semantic_candidates(identity) VALUES (?)", texts: [identity])
                }
            }
            return true
        } catch {
            return false
        }
    }

    func storeContent(identity: String, name: String, text body: String?, ocrUsed: Bool, hash: String, state: String, chunks: [ChunkVector]?) throws {
        try transaction {
            let contentSQL = """
                INSERT INTO file_content (file_identity, extracted_text, ocr_used, content_hash, extracted_at, index_state)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_identity) DO UPDATE SET extracted_text=excluded.extracted_text,
                ocr_used=excluded.ocr_used, content_hash=excluded.content_hash,
                extracted_at=excluded.extracted_at, index_state=excluded.index_state
                """
            let statement = try cachedStatement(contentSQL)
            bindText(statement, 1, identity)
            if let body { bindText(statement, 2, body) } else { sqlite3_bind_null(statement, 2) }
            sqlite3_bind_int(statement, 3, ocrUsed ? 1 : 0)
            bindText(statement, 4, hash)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            bindText(statement, 6, state)
            try stepDone(statement)
            sqlite3_reset(statement)

            try execute("DELETE FROM content_fts WHERE file_identity = ?", texts: [identity])
            if let body {
                try execute("INSERT INTO content_fts (file_identity, name, body) VALUES (?, ?, ?)", texts: [identity, name, body])
            }
            if let chunks {
                try replaceChunksInsideTransaction(identity: identity, chunks: chunks)
            }
        }
    }

    func replaceChunks(identity: String, chunks: [ChunkVector]) throws {
        try transaction { try replaceChunksInsideTransaction(identity: identity, chunks: chunks) }
    }

    private func replaceChunksInsideTransaction(identity: String, chunks: [ChunkVector]) throws {
        try execute("DELETE FROM content_chunks WHERE file_identity = ?", texts: [identity])
        let chunkSQL = "INSERT INTO content_chunks (file_identity, ordinal, text) VALUES (?, ?, ?)"
        let vectorSQL = "INSERT INTO chunk_vectors (chunk_id, provider_id, dimension, vector, norm) VALUES (?, ?, ?, ?, ?)"
        for chunk in chunks {
            let chunkStatement = try cachedStatement(chunkSQL)
            bindText(chunkStatement, 1, identity)
            sqlite3_bind_int(chunkStatement, 2, Int32(chunk.ordinal))
            bindText(chunkStatement, 3, chunk.text)
            try stepDone(chunkStatement)
            sqlite3_reset(chunkStatement)
            let chunkID = sqlite3_last_insert_rowid(db)

            let vectorStatement = try cachedStatement(vectorSQL)
            sqlite3_bind_int64(vectorStatement, 1, chunkID)
            bindText(vectorStatement, 2, chunk.providerID)
            sqlite3_bind_int(vectorStatement, 3, Int32(chunk.vector.count))
            let data = chunk.vector.withUnsafeBufferPointer { Data(buffer: $0) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(vectorStatement, 4, $0.baseAddress, Int32(data.count), SQLITE_ACTOR_TRANSIENT) }
            let norm = sqrt(chunk.vector.reduce(Float(0)) { $0 + $1 * $1 })
            sqlite3_bind_double(vectorStatement, 5, Double(norm))
            try stepDone(vectorStatement)
            sqlite3_reset(vectorStatement)
        }
    }

    private func transaction(_ work: () throws -> Void) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw prepareError() }
        do {
            try work()
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw prepareError() }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func execute(_ sql: String, texts: [String]) throws {
        let statement = try cachedStatement(sql)
        defer { sqlite3_reset(statement) }
        for (offset, value) in texts.enumerated() { bindText(statement, Int32(offset + 1), value) }
        try stepDone(statement)
    }

    /// Restituisce uno statement preparato riusabile per l'SQL dato, resettandolo e
    /// azzerandone i binding. Gli statement restano vivi fino a `close()`/`deinit`.
    private func cachedStatement(_ sql: String) throws -> OpaquePointer? {
        if let existing = statementCache[sql] {
            sqlite3_reset(existing)
            sqlite3_clear_bindings(existing)
            return existing
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw prepareError() }
        statementCache[sql] = statement
        return statement
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_ACTOR_TRANSIENT)
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw prepareError() }
    }

    private func scalarText(_ sql: String, values: [String]) -> String? {
        guard let statement = try? cachedStatement(sql) else { return nil }
        defer { sqlite3_reset(statement) }
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, SQLITE_ACTOR_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func prepareError() -> DatabaseError {
        .prepare(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite prepare failed")
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
