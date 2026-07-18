import XCTest
@testable import FolderBase

final class BackupServiceTests: XCTestCase {
    @MainActor
    func testCompleteBackupRestoresDatabaseTemplatesFoldersAndPreferences() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBaseCompleteBackup-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "FolderBaseBackupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("en", forKey: "appLanguage")
        defaults.set(true, forKey: "showHiddenFiles")
        defaults.set("openai", forKey: AIProviderSettings.Keys.chatProvider)
        defaults.set(7, forKey: AIProviderSettings.Keys.chatContextChunks)
        defaults.set(["/tmp/private"], forKey: "recentFolderPaths")

        let store = MetadataStore(supportURLOverride: support)
        let managedFolder = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: managedFolder, withIntermediateDirectories: true)
        let documentURL = managedFolder.appendingPathComponent("example.txt")
        try Data("FolderBase backup test".utf8).write(to: documentURL)
        store.addField(folderURL: managedFolder, name: "Stato", kind: .text, options: [])
        let metadataField = try XCTUnwrap(store.fields(for: managedFolder, configurationRootURL: managedFolder).first)
        _ = try store.registerFile(at: documentURL)
        let fileItem = try XCTUnwrap(FileBrowserService().contentsOfDirectory(at: managedFolder).first)
        store.update(item: fileItem, field: metadataField, value: "archiviato")
        store.flushPendingWrites()
        store.loadMetadata(for: [fileItem])
        try await Task.sleep(for: .milliseconds(30))

        let templates = TemplateStore(defaults: defaults, supportURLOverride: support)
        let template = MetadataTemplate(
            id: "template-1",
            name: "Pratiche",
            fields: [FieldTemplate(id: "status", name: "Stato", kind: .text)]
        )
        templates.add(template)
        templates.activeTemplateID = template.id
        let recentFolders = RecentFoldersStore(defaults: defaults)

        let service = BackupService(defaults: defaults)
        service.destinationPath = destination.path
        service.configure(store: store, templateStore: templates, recentFoldersStore: recentFolders)

        let backupURL: URL
        do {
            backupURL = try await service.runBackup(auto: false)
        } catch {
            XCTFail("Complete backup failed: \(String(reflecting: error))")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertNoThrow(try SQLiteDatabaseActor.validateBackup(at: backupURL, thorough: true))
        let snapshot = try XCTUnwrap(BackupConfigurationArchive.read(from: backupURL))
        XCTAssertEqual(snapshot.formatVersion, FolderBaseConfigurationSnapshot.currentFormatVersion)

        defaults.set("it", forKey: "appLanguage")
        defaults.set(false, forKey: "showHiddenFiles")
        defaults.set("none", forKey: AIProviderSettings.Keys.chatProvider)
        defaults.set(2, forKey: AIProviderSettings.Keys.chatContextChunks)
        defaults.set(["/tmp/other"], forKey: "recentFolderPaths")
        store.update(item: fileItem, field: metadataField, value: "modificato")
        store.flushPendingWrites()
        templates.delete(id: template.id)
        recentFolders.reloadFromDefaults()

        try await service.restore(from: backupURL)

        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        XCTAssertTrue(defaults.bool(forKey: "showHiddenFiles"))
        XCTAssertEqual(defaults.string(forKey: AIProviderSettings.Keys.chatProvider), "openai")
        XCTAssertEqual(defaults.integer(forKey: AIProviderSettings.Keys.chatContextChunks), 7)
        XCTAssertEqual(recentFolders.folderURLs.map(\.path), ["/tmp/private"])
        XCTAssertEqual(templates.templates, [template])
        XCTAssertEqual(templates.activeTemplateID, template.id)
        let restoredField = try XCTUnwrap(store.fields(for: managedFolder, configurationRootURL: managedFolder).first)
        XCTAssertEqual(store.value(for: fileItem, field: restoredField), "archiviato")
    }

    @MainActor
    func testLegacyDatabaseBackupLeavesCurrentConfigurationUntouched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBaseLegacyBackup-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "FolderBaseLegacyBackupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MetadataStore(supportURLOverride: support)
        let legacyURL = root.appendingPathComponent("legacy.sqlite")
        do {
            try await store.backup(to: legacyURL)
        } catch {
            XCTFail("Legacy backup setup failed: \(String(reflecting: error))")
            return
        }

        // Simula il formato dei vecchi backup: pagina principale marcata WAL ma nessun
        // file laterale. Il lettore nuovo deve poterlo verificare e ripristinare comunque.
        let legacyWALActor = try SQLiteDatabaseActor(url: legacyURL)
        await legacyWALActor.close()
        try? FileManager.default.removeItem(atPath: legacyURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: legacyURL.path + "-shm")
        XCTAssertNoThrow(try SQLiteDatabaseActor.validateBackup(at: legacyURL, thorough: false))
        XCTAssertNil(try BackupConfigurationArchive.read(from: legacyURL))

        defaults.set("en", forKey: "appLanguage")
        let service = BackupService(defaults: defaults)
        service.configure(store: store)
        try await service.restore(from: legacyURL)

        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
    }
}
