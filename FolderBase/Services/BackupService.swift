import Combine
import Foundation
import OSLog

/// Coordina backup e ripristino dello stato completo di FolderBase. Ogni copia contiene il
/// database dei metadata più un manifest interno con template e preferenze applicative.
/// L'indice AI non viene copiato perché è derivato e ricostruibile; i segreti restano nel
/// Portachiavi e non vengono mai scritti in chiaro nel backup.
@MainActor
final class BackupService: ObservableObject {
    private static let log = Logger(subsystem: "com.paolosturbini.folderbase", category: "Backup")

    private enum Keys {
        static let destination = "backupDestinationPath"
        static let autoEnabled = "autoBackupEnabled"
        static let intervalHours = "autoBackupIntervalHours"
        static let keepCount = "autoBackupKeepCount"
        static let lastTimestamp = "lastBackupTimestamp"
    }

    private enum Prefix {
        static let manual = "FolderBase-backup-"
        static let auto = "FolderBase-auto-"
        static let preRestore = "FolderBase-prerestore-"
    }

    enum BackupError: LocalizedError {
        case notReady
        case noDestination
        case destinationMissing

        var errorDescription: String? {
            switch self {
            case .notReady: return L("backup.error.notReady")
            case .noDestination: return L("backup.error.noDestination")
            case .destinationMissing: return L("backup.error.destinationMissing")
            }
        }
    }

    @Published var destinationPath: String {
        didSet { defaults.set(destinationPath, forKey: Keys.destination) }
    }

    @Published var autoEnabled: Bool {
        didSet { defaults.set(autoEnabled, forKey: Keys.autoEnabled) }
    }

    @Published var intervalHours: Int {
        didSet { defaults.set(intervalHours, forKey: Keys.intervalHours) }
    }

    @Published var keepCount: Int {
        didSet { defaults.set(keepCount, forKey: Keys.keepCount) }
    }

    @Published private(set) var lastBackupDate: Date?
    @Published private(set) var lastBackupError: String?

    private weak var store: MetadataStore?
    private weak var templateStore: TemplateStore?
    private weak var recentFoldersStore: RecentFoldersStore?
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var schedulerTask: Task<Void, Never>?
    private var backupInProgress = false

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        destinationPath = defaults.string(forKey: Keys.destination) ?? ""
        autoEnabled = defaults.bool(forKey: Keys.autoEnabled)
        let storedInterval = defaults.integer(forKey: Keys.intervalHours)
        intervalHours = storedInterval > 0 ? storedInterval : 24
        let storedKeep = defaults.integer(forKey: Keys.keepCount)
        keepCount = storedKeep > 0 ? storedKeep : 10
        let stamp = defaults.double(forKey: Keys.lastTimestamp)
        lastBackupDate = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    deinit {
        schedulerTask?.cancel()
    }

    /// Collega tutti gli archivi che devono essere riallineati dopo un ripristino e avvia uno
    /// scheduler basato su `Task`, indipendente dal run loop delle finestre SwiftUI.
    func configure(
        store: MetadataStore,
        templateStore: TemplateStore? = nil,
        recentFoldersStore: RecentFoldersStore? = nil
    ) {
        self.store = store
        self.templateStore = templateStore
        self.recentFoldersStore = recentFoldersStore
        if schedulerTask == nil { startScheduler() }

        // Controlla subito: se l'app è rimasta chiusa oltre l'intervallo, non attende 15 minuti.
        Task { [weak self] in await self?.performAutoBackupIfDue() }
    }

    private func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15 * 60))
                } catch {
                    return
                }
                guard let self else { return }
                await self.performAutoBackupIfDue()
            }
        }
    }

    func performAutoBackupIfDue() async {
        guard autoEnabled, !destinationPath.isEmpty else { return }
        if let last = lastBackupDate,
           Date().timeIntervalSince(last) < Double(intervalHours) * 3600 {
            return
        }
        do {
            _ = try await runBackup(auto: true)
        } catch {
            lastBackupError = error.localizedDescription
            Self.log.error("Backup automatico fallito: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Crea un singolo file SQLite autosufficiente: database coerente, preferenze e template.
    @discardableResult
    func runBackup(auto: Bool) async throws -> URL {
        guard let store else { throw BackupError.notReady }
        guard !destinationPath.isEmpty else { throw BackupError.noDestination }
        guard !backupInProgress else { throw BackupError.notReady }
        backupInProgress = true
        lastBackupError = nil
        defer { backupInProgress = false }

        do {
            let folder = URL(fileURLWithPath: destinationPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BackupError.destinationMissing
            }

            let prefix = auto ? Prefix.auto : Prefix.manual
            let destination = uniqueDestination(in: folder, prefix: prefix)
            try await createCompleteBackup(at: destination, store: store)

            let now = Date()
            lastBackupDate = now
            defaults.set(now.timeIntervalSince1970, forKey: Keys.lastTimestamp)
            if auto { pruneAutoBackups(in: folder) }
            return destination
        } catch {
            lastBackupError = error.localizedDescription
            throw error
        }
    }

    /// Ripristina database e, per i backup nuovi, l'intera configurazione. I vecchi `.sqlite`
    /// restano accettati e ripristinano soltanto i metadata, lasciando intatte le preferenze.
    func restore(from sourceURL: URL) async throws {
        guard let store else { throw BackupError.notReady }

        let sourceSnapshot = try await Task.detached(priority: .utility) {
            try SQLiteDatabaseActor.validateBackup(at: sourceURL, thorough: true)
            return try BackupConfigurationArchive.read(from: sourceURL)
        }.value

        let supportDirectory = store.databaseURL.deletingLastPathComponent()
        let safetyURL = supportDirectory
            .appendingPathComponent(Prefix.preRestore + Self.timestamp() + ".sqlite")
        try await createCompleteBackup(at: safetyURL, store: store)
        let safetySnapshot = try await Task.detached(priority: .utility) {
            try BackupConfigurationArchive.read(from: safetyURL)
        }.value

        var databaseWasReplaced = false
        do {
            try await store.restore(from: sourceURL)
            databaseWasReplaced = true
            if let sourceSnapshot {
                try applyConfiguration(sourceSnapshot, supportDirectory: supportDirectory)
            }
        } catch {
            if databaseWasReplaced {
                do {
                    try await store.restore(from: safetyURL)
                    if let safetySnapshot {
                        try applyConfiguration(safetySnapshot, supportDirectory: supportDirectory)
                    }
                } catch {
                    Self.log.fault("Rollback del ripristino fallito: \(error.localizedDescription, privacy: .public)")
                }
            }
            throw error
        }
    }

    private func createCompleteBackup(at destination: URL, store: MetadataStore) async throws {
        let supportDirectory = store.databaseURL.deletingLastPathComponent()
        let snapshot = try BackupConfigurationArchive.capture(
            defaults: defaults,
            supportDirectory: supportDirectory,
            launchAtLoginEnabled: LaunchAtLoginService.shared.isEnabled
        )
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).staging")
        defer { try? fileManager.removeItem(at: staging) }

        try await store.backup(to: staging)
        try await Task.detached(priority: .utility) {
            try BackupConfigurationArchive.embed(snapshot, in: staging)
            try SQLiteDatabaseActor.validateBackup(at: staging, thorough: false)
        }.value

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    private func applyConfiguration(_ snapshot: FolderBaseConfigurationSnapshot, supportDirectory: URL) throws {
        let launchAtLogin = try BackupConfigurationArchive.apply(
            snapshot,
            defaults: defaults,
            supportDirectory: supportDirectory,
            fileManager: fileManager
        )

        templateStore?.reloadFromDisk()
        recentFoldersStore?.reloadFromDefaults()
        reloadBackupPreferences()
        if defaults === UserDefaults.standard {
            LocalizationManager.shared.reloadFromDefaults()
            if let launchAtLogin { LaunchAtLoginService.shared.setEnabled(launchAtLogin) }
        }
    }

    private func reloadBackupPreferences() {
        autoEnabled = defaults.bool(forKey: Keys.autoEnabled)
        let storedInterval = defaults.integer(forKey: Keys.intervalHours)
        intervalHours = storedInterval > 0 ? storedInterval : 24
        let storedKeep = defaults.integer(forKey: Keys.keepCount)
        keepCount = storedKeep > 0 ? storedKeep : 10
    }

    private func uniqueDestination(in folder: URL, prefix: String) -> URL {
        let base = prefix + Self.timestamp()
        var candidate = folder.appendingPathComponent(base + ".sqlite")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(suffix).sqlite")
            suffix += 1
        }
        return candidate
    }

    private func pruneAutoBackups(in folder: URL) {
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let autoBackups = files
            .filter { $0.lastPathComponent.hasPrefix(Prefix.auto) && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard autoBackups.count > keepCount else { return }
        for url in autoBackups.prefix(autoBackups.count - keepCount) {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}
