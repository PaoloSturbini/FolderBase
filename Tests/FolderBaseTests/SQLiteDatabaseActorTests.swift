import XCTest
import SQLite3
@testable import FolderBase

final class SQLiteDatabaseActorTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        databaseURL = temporaryDirectory.appendingPathComponent("test.sqlite")
        try createSchema(at: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testLoadMetadataReturnsOnlyRequestedIdentitiesAcrossBatches() async throws {
        try withDatabase(at: databaseURL) { db in
            for index in 0..<405 {
                try execute(db, "INSERT INTO metadata_values(file_identity, field_id, value) VALUES ('id-\(index)', 'status', 'value-\(index)')")
            }
        }

        let actor = try SQLiteDatabaseActor(url: databaseURL)
        let requested = Set((0..<405).map { "id-\($0)" })
        let loaded = try await actor.loadMetadata(identities: requested)

        XCTAssertEqual(loaded.count, 405)
        XCTAssertEqual(loaded["id-0"]?.values["status"], "value-0")
        XCTAssertEqual(loaded["id-404"]?.values["status"], "value-404")
        let empty = try await actor.loadMetadata(identities: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testStoreContentAtomicallyReplacesFTSAndChunks() async throws {
        let actor = try SQLiteDatabaseActor(url: databaseURL)
        let first = ChunkVector(ordinal: 0, text: "old chunk", providerID: "test-v1", vector: [1, 0])
        try await actor.storeContent(identity: "file-1", name: "Old", text: "old body", ocrUsed: false, hash: "h1", state: "indexed", chunks: [first])

        let replacement = ChunkVector(ordinal: 0, text: "new chunk", providerID: "test-v1", vector: [0, 1])
        try await actor.storeContent(identity: "file-1", name: "New", text: "new body", ocrUsed: true, hash: "h2", state: "indexed", chunks: [replacement])

        try withDatabase(at: databaseURL) { db in
            XCTAssertEqual(try scalarInt(db, "SELECT count(*) FROM content_fts WHERE file_identity = 'file-1'"), 1)
            XCTAssertEqual(try scalarText(db, "SELECT body FROM content_fts WHERE file_identity = 'file-1'"), "new body")
            XCTAssertEqual(try scalarInt(db, "SELECT count(*) FROM content_chunks WHERE file_identity = 'file-1'"), 1)
            XCTAssertEqual(try scalarText(db, "SELECT text FROM content_chunks WHERE file_identity = 'file-1'"), "new chunk")
            XCTAssertEqual(try scalarText(db, "SELECT content_hash FROM file_content WHERE file_identity = 'file-1'"), "h2")
        }
    }

    func testStoreContentRollsBackWhenVectorWriteFails() async throws {
        let actor = try SQLiteDatabaseActor(url: databaseURL)
        let invalid = ChunkVector(ordinal: 0, text: "chunk", providerID: "", vector: [1])

        do {
            try await actor.storeContent(identity: "file-rollback", name: "Name", text: "body", ocrUsed: false, hash: "hash", state: "indexed", chunks: [invalid])
            XCTFail("Expected the invalid provider constraint to fail")
        } catch { }

        try withDatabase(at: databaseURL) { db in
            XCTAssertEqual(try scalarInt(db, "SELECT count(*) FROM file_content WHERE file_identity = 'file-rollback'"), 0)
            XCTAssertEqual(try scalarInt(db, "SELECT count(*) FROM content_fts WHERE file_identity = 'file-rollback'"), 0)
            XCTAssertEqual(try scalarInt(db, "SELECT count(*) FROM content_chunks WHERE file_identity = 'file-rollback'"), 0)
        }
    }

    func testUpsertMetadataUpdatesExistingValuesAndCommitsBatchAtomically() async throws {
        let actor = try SQLiteDatabaseActor(url: databaseURL)
        try await actor.upsertMetadata([
            (identity: "file-1", fieldID: "status", value: "new"),
            (identity: "file-2", fieldID: "priority", value: "high")
        ])
        try await actor.upsertMetadata([
            (identity: "file-1", fieldID: "status", value: "updated")
        ])

        let loaded = try await actor.loadMetadata(identities: ["file-1", "file-2"])
        XCTAssertEqual(loaded["file-1"]?.values["status"], "updated")
        XCTAssertEqual(loaded["file-2"]?.values["priority"], "high")

        do {
            try await actor.upsertMetadata([
                (identity: "file-3", fieldID: "status", value: "must-roll-back"),
                (identity: "file-4", fieldID: "status", value: "__INVALID__")
            ])
            XCTFail("Expected the second write to violate the test schema constraint")
        } catch { }

        let rolledBack = try await actor.loadMetadata(identities: ["file-3", "file-4"])
        XCTAssertTrue(rolledBack.isEmpty)
    }

    func testBackupPassesQuickAndThoroughValidationAndRejectsIncompleteSchema() async throws {
        let actor = try SQLiteDatabaseActor(url: databaseURL)
        try await actor.upsertMetadata([(identity: "file-1", fieldID: "status", value: "ready")])
        let backupURL = temporaryDirectory.appendingPathComponent("backup.sqlite")

        try await actor.backup(to: backupURL)
        try withDatabase(at: backupURL) { db in
            XCTAssertEqual(try scalarText(db, "PRAGMA quick_check"), "ok")
            XCTAssertEqual(try scalarText(db, "PRAGMA integrity_check"), "ok")
        }
        XCTAssertNoThrow(try SQLiteDatabaseActor.validateBackup(at: backupURL, thorough: false))
        XCTAssertNoThrow(try SQLiteDatabaseActor.validateBackup(at: backupURL, thorough: true))
        try withDatabase(at: backupURL) { db in
            XCTAssertEqual(try scalarText(db, "SELECT value FROM metadata_values WHERE file_identity='file-1' AND field_id='status'"), "ready")
        }

        let incompleteURL = temporaryDirectory.appendingPathComponent("incomplete.sqlite")
        try withDatabase(at: incompleteURL) { db in
            try execute(db, "CREATE TABLE files(identity TEXT PRIMARY KEY)")
        }
        XCTAssertThrowsError(try SQLiteDatabaseActor.validateBackup(at: incompleteURL, thorough: false))
        XCTAssertThrowsError(try SQLiteDatabaseActor.validateBackup(at: incompleteURL, thorough: true))
    }

    func testTrackingUpdatesAreAppliedAsOneBatch() async throws {
        try withDatabase(at: databaseURL) { db in
            try execute(db, "INSERT INTO files(identity) VALUES ('file-1'), ('file-2')")
        }
        let actor = try SQLiteDatabaseActor(url: databaseURL)
        try await actor.applyTrackingUpdates([
            FileTrackingUpdate(identity: "file-1", path: "/tmp/one", name: "one", size: 11, bookmark: Data([1, 2])),
            FileTrackingUpdate(identity: "file-2", path: "/tmp/two", name: "two", size: nil, bookmark: nil)
        ])
        try withDatabase(at: databaseURL) { db in
            XCTAssertEqual(try scalarText(db, "SELECT last_known_path FROM files WHERE identity='file-1'"), "/tmp/one")
            XCTAssertEqual(try scalarInt(db, "SELECT size FROM files WHERE identity='file-1'"), 11)
            XCTAssertEqual(try scalarText(db, "SELECT name FROM files WHERE identity='file-2'"), "two")
        }
    }

    private func createSchema(at url: URL) throws {
        try withDatabase(at: url) { db in
            try execute(db, "CREATE TABLE files (identity TEXT PRIMARY KEY, last_known_path TEXT, name TEXT, size INTEGER, bookmark_data BLOB, updated_at REAL)")
            try execute(db, "CREATE TABLE metadata_fields (id TEXT PRIMARY KEY)")
            try execute(db, "CREATE TABLE metadata_values (file_identity TEXT NOT NULL, field_id TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(file_identity, field_id))")
            try execute(db, "CREATE TRIGGER reject_invalid_metadata BEFORE INSERT ON metadata_values WHEN NEW.value = '__INVALID__' BEGIN SELECT RAISE(ABORT, 'invalid test value'); END")
            try execute(db, "CREATE TABLE file_content (file_identity TEXT PRIMARY KEY, extracted_text TEXT, ocr_used INTEGER NOT NULL, content_hash TEXT, extracted_at REAL, index_state TEXT NOT NULL)")
            try execute(db, "CREATE VIRTUAL TABLE content_fts USING fts5(file_identity UNINDEXED, name, body)")
            try execute(db, "CREATE TABLE content_chunks (id INTEGER PRIMARY KEY AUTOINCREMENT, file_identity TEXT NOT NULL, ordinal INTEGER NOT NULL, text TEXT NOT NULL)")
            try execute(db, "CREATE TABLE chunk_vectors (chunk_id INTEGER PRIMARY KEY, provider_id TEXT NOT NULL CHECK(length(provider_id) > 0), dimension INTEGER NOT NULL, vector BLOB NOT NULL, norm REAL NOT NULL)")
        }
    }

    private func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            defer { sqlite3_close(db) }
            throw TestDatabaseError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(error)
            throw TestDatabaseError.sqlite(message)
        }
    }

    private func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TestDatabaseError.sqlite("prepare failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TestDatabaseError.sqlite("no row") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TestDatabaseError.sqlite("prepare failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw TestDatabaseError.sqlite("no row") }
        return String(cString: value)
    }
}

private enum TestDatabaseError: Error {
    case sqlite(String)
}
