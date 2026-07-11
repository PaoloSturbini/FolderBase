import Foundation
import SQLite3

private let SQLITE_ACTOR_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Connessione SQLite dedicata alle letture potenzialmente costose. L'actor garantisce che
/// statement e connessione non attraversino mai thread concorrenti e tiene il lavoro fuori dal
/// MainActor. La connessione principale resta temporaneamente responsabile delle migrazioni e
/// delle scritture; WAL rende le due connessioni cooperanti senza bloccare il rendering SwiftUI.
actor SQLiteDatabaseActor {
    enum DatabaseError: Error { case open(String), prepare(String) }

    private var db: OpaquePointer?

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
        sqlite3_exec(connection, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        sqlite3_exec(connection, "PRAGMA cache_size = -16000", nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

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
        let sql = "SELECT 1 FROM content_chunks c JOIN chunk_vectors v ON v.chunk_id = c.id WHERE c.file_identity = ? AND v.provider_id LIKE ? LIMIT 1"
        return scalarText(sql, values: [identity, providerPrefix + "%"]) != nil
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
        let sql = "SELECT DISTINCT c.file_identity FROM chunk_vectors v JOIN content_chunks c ON c.id = v.chunk_id WHERE v.provider_id LIKE ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, providerPrefix + "%", -1, SQLITE_ACTOR_TRANSIENT)
        var result: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW { result.insert(text(statement, 0)) }
        return result
    }

    func storeContent(identity: String, name: String, text body: String?, ocrUsed: Bool, hash: String, state: String, chunks: [ChunkVector]?) throws {
        try transaction {
            var statement: OpaquePointer?
            let contentSQL = """
                INSERT INTO file_content (file_identity, extracted_text, ocr_used, content_hash, extracted_at, index_state)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_identity) DO UPDATE SET extracted_text=excluded.extracted_text,
                ocr_used=excluded.ocr_used, content_hash=excluded.content_hash,
                extracted_at=excluded.extracted_at, index_state=excluded.index_state
                """
            try prepare(contentSQL, &statement)
            bindText(statement, 1, identity)
            if let body { bindText(statement, 2, body) } else { sqlite3_bind_null(statement, 2) }
            sqlite3_bind_int(statement, 3, ocrUsed ? 1 : 0)
            bindText(statement, 4, hash)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            bindText(statement, 6, state)
            try stepDone(statement)
            sqlite3_finalize(statement)

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
        for chunk in chunks {
            var statement: OpaquePointer?
            try prepare("INSERT INTO content_chunks (file_identity, ordinal, text) VALUES (?, ?, ?)", &statement)
            bindText(statement, 1, identity)
            sqlite3_bind_int(statement, 2, Int32(chunk.ordinal))
            bindText(statement, 3, chunk.text)
            try stepDone(statement)
            sqlite3_finalize(statement)
            let chunkID = sqlite3_last_insert_rowid(db)

            try prepare("INSERT INTO chunk_vectors (chunk_id, provider_id, dimension, vector, norm) VALUES (?, ?, ?, ?, ?)", &statement)
            sqlite3_bind_int64(statement, 1, chunkID)
            bindText(statement, 2, chunk.providerID)
            sqlite3_bind_int(statement, 3, Int32(chunk.vector.count))
            let data = chunk.vector.withUnsafeBufferPointer { Data(buffer: $0) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), SQLITE_ACTOR_TRANSIENT) }
            let norm = sqrt(chunk.vector.reduce(Float(0)) { $0 + $1 * $1 })
            sqlite3_bind_double(statement, 5, Double(norm))
            try stepDone(statement)
            sqlite3_finalize(statement)
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
        var statement: OpaquePointer?
        try prepare(sql, &statement)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in texts.enumerated() { bindText(statement, Int32(offset + 1), value) }
        try stepDone(statement)
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw prepareError() }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_ACTOR_TRANSIENT)
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw prepareError() }
    }

    private func scalarText(_ sql: String, values: [String]) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
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
