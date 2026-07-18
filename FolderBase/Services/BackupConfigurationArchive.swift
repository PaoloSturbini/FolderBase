import Foundation
import SQLite3

private let SQLITE_BACKUP_ARCHIVE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct FolderBaseConfigurationSnapshot: Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let createdAt: Date
    let appVersion: String
    let preferencesPlist: Data
    let templatesJSON: Data
}

/// Inserisce la configurazione applicativa dentro la copia SQLite del database. Il backup resta
/// quindi un singolo file, leggibile anche dalle versioni precedenti (che ignorano la tabella
/// aggiuntiva), ma le versioni nuove possono ripristinare database, template e preferenze insieme.
enum BackupConfigurationArchive {
    static let manifestTable = "folderbase_backup_manifest"
    static let launchAtLoginSnapshotKey = "folderbaseLaunchAtLoginEnabled"

    /// Preferenze di proprietà di FolderBase. Sono escluse destinazione e data dell'ultimo backup:
    /// sono informazioni operative legate al Mac corrente e ripristinarle potrebbe puntare a un
    /// volume non disponibile. I segreti non sono in UserDefaults e restano nel Portachiavi.
    static let preferenceKeys: Set<String> = [
        "activeMetadataTemplateID",
        "aiChatContextChunks",
        "aiChatProvider",
        "aiEmbeddingProvider",
        "aiEnabled",
        "aiExcludedSourcePaths",
        "aiOllamaBaseURL",
        "aiOllamaChatModel",
        "aiOllamaModel",
        "aiOpenAIChatModel",
        "aiOpenAIModel",
        "appAccentColor",
        "appAccentCustomHex",
        "appLanguage",
        "appearanceMode",
        "autoBackupEnabled",
        "autoBackupIntervalHours",
        "autoBackupKeepCount",
        "autoCheckUpdates",
        "autoPurgeOrphans",
        "columnCustomization",
        "columnCustomizationByFolder",
        "contentFontSize",
        "globallyHiddenTemplateFieldIDs",
        "hiddenColumns",
        "hiddenColumnsByFolder",
        "notesPanelHeight",
        "recentFolderPaths",
        "showFileExtensions",
        "showHiddenFiles",
        "showMenuBarIcon",
        "sidebarFontSize"
    ]

    enum ArchiveError: LocalizedError {
        case invalidConfiguration
        case unsupportedVersion(Int)
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return L("backup.error.invalidConfiguration")
            case .unsupportedVersion:
                return L("backup.error.unsupportedVersion")
            case .sqlite(let detail):
                return "\(L("backup.error.archive")) \(detail)"
            }
        }
    }

    static func capture(
        defaults: UserDefaults,
        supportDirectory: URL,
        launchAtLoginEnabled: Bool,
        bundle: Bundle = .main
    ) throws -> FolderBaseConfigurationSnapshot {
        var preferences: [String: Any] = [:]
        for key in preferenceKeys {
            if let value = defaults.object(forKey: key) {
                preferences[key] = value
            }
        }
        preferences[launchAtLoginSnapshotKey] = launchAtLoginEnabled

        guard PropertyListSerialization.propertyList(preferences, isValidFor: .binary) else {
            throw ArchiveError.invalidConfiguration
        }
        let preferencesPlist = try PropertyListSerialization.data(
            fromPropertyList: preferences,
            format: .binary,
            options: 0
        )

        let templatesURL = supportDirectory.appendingPathComponent("templates.json")
        let templatesJSON: Data
        if FileManager.default.fileExists(atPath: templatesURL.path) {
            templatesJSON = try Data(contentsOf: templatesURL)
        } else {
            templatesJSON = try JSONEncoder().encode([MetadataTemplate]())
        }
        guard (try? JSONDecoder().decode([MetadataTemplate].self, from: templatesJSON)) != nil else {
            throw ArchiveError.invalidConfiguration
        }

        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return FolderBaseConfigurationSnapshot(
            formatVersion: FolderBaseConfigurationSnapshot.currentFormatVersion,
            createdAt: Date(),
            appVersion: version,
            preferencesPlist: preferencesPlist,
            templatesJSON: templatesJSON
        )
    }

    nonisolated static func embed(_ snapshot: FolderBaseConfigurationSnapshot, in databaseURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            sqlite3_close(db)
            throw ArchiveError.sqlite(message)
        }
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE IF NOT EXISTS \(manifestTable) (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            format_version INTEGER NOT NULL,
            created_at REAL NOT NULL,
            app_version TEXT NOT NULL,
            preferences_plist BLOB NOT NULL,
            templates_json BLOB NOT NULL
        )
        """
        try execute(createSQL, db: db)
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            try execute("DELETE FROM \(manifestTable)", db: db)
            var statement: OpaquePointer?
            let insertSQL = """
            INSERT INTO \(manifestTable)
            (id, format_version, created_at, app_version, preferences_plist, templates_json)
            VALUES (1, ?, ?, ?, ?, ?)
            """
            guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
                throw ArchiveError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(snapshot.formatVersion))
            sqlite3_bind_double(statement, 2, snapshot.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, snapshot.appVersion, -1, SQLITE_BACKUP_ARCHIVE_TRANSIENT)
            bind(snapshot.preferencesPlist, to: statement, index: 4)
            bind(snapshot.templatesJSON, to: statement, index: 5)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ArchiveError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    /// `nil` identifica un backup storico contenente soltanto il database.
    nonisolated static func read(from databaseURL: URL) throws -> FolderBaseConfigurationSnapshot? {
        var db: OpaquePointer?
        let readOnlyURI = databaseURL.absoluteString + (databaseURL.query == nil ? "?immutable=1" : "&immutable=1")
        guard sqlite3_open_v2(readOnlyURI, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            sqlite3_close(db)
            throw ArchiveError.sqlite(message)
        }
        defer { sqlite3_close(db) }

        var tableStatement: OpaquePointer?
        let tableSQL = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
        guard sqlite3_prepare_v2(db, tableSQL, -1, &tableStatement, nil) == SQLITE_OK else {
            throw ArchiveError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(tableStatement, 1, manifestTable, -1, SQLITE_BACKUP_ARCHIVE_TRANSIENT)
        let hasManifest = sqlite3_step(tableStatement) == SQLITE_ROW
        sqlite3_finalize(tableStatement)
        guard hasManifest else { return nil }

        var statement: OpaquePointer?
        let selectSQL = """
        SELECT format_version, created_at, app_version, preferences_plist, templates_json
        FROM \(manifestTable) WHERE id = 1
        """
        guard sqlite3_prepare_v2(db, selectSQL, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            throw ArchiveError.invalidConfiguration
        }
        defer { sqlite3_finalize(statement) }

        let formatVersion = Int(sqlite3_column_int(statement, 0))
        guard formatVersion >= 1 else { throw ArchiveError.invalidConfiguration }
        guard formatVersion <= FolderBaseConfigurationSnapshot.currentFormatVersion else {
            throw ArchiveError.unsupportedVersion(formatVersion)
        }
        guard let appVersionText = sqlite3_column_text(statement, 2),
              let preferencesPlist = data(statement, column: 3),
              let templatesJSON = data(statement, column: 4) else {
            throw ArchiveError.invalidConfiguration
        }

        let snapshot = FolderBaseConfigurationSnapshot(
            formatVersion: formatVersion,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            appVersion: String(cString: appVersionText),
            preferencesPlist: preferencesPlist,
            templatesJSON: templatesJSON
        )
        _ = try decodedPreferences(snapshot)
        guard (try? JSONDecoder().decode([MetadataTemplate].self, from: templatesJSON)) != nil else {
            throw ArchiveError.invalidConfiguration
        }
        return snapshot
    }

    /// Applica template e preferenze. Restituisce lo stato dell'avvio al login da applicare
    /// separatamente tramite ServiceManagement.
    @discardableResult
    static func apply(
        _ snapshot: FolderBaseConfigurationSnapshot,
        defaults: UserDefaults,
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool? {
        var preferences = try decodedPreferences(snapshot)
        guard (try? JSONDecoder().decode([MetadataTemplate].self, from: snapshot.templatesJSON)) != nil else {
            throw ArchiveError.invalidConfiguration
        }

        let templatesURL = supportDirectory.appendingPathComponent("templates.json")
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try snapshot.templatesJSON.write(to: templatesURL, options: .atomic)

        let launchAtLogin = preferences.removeValue(forKey: launchAtLoginSnapshotKey) as? Bool
        for key in preferenceKeys { defaults.removeObject(forKey: key) }
        for (key, value) in preferences where preferenceKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
        return launchAtLogin
    }

    private static func decodedPreferences(_ snapshot: FolderBaseConfigurationSnapshot) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: snapshot.preferencesPlist, options: [], format: nil)
        guard let preferences = object as? [String: Any] else { throw ArchiveError.invalidConfiguration }
        return preferences
    }

    nonisolated private static func execute(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ArchiveError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    nonisolated private static func bind(_ value: Data, to statement: OpaquePointer?, index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), SQLITE_BACKUP_ARCHIVE_TRANSIENT)
        }
    }

    nonisolated private static func data(_ statement: OpaquePointer?, column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
