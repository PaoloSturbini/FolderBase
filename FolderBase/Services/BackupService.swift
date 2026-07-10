import Foundation
import Combine
import OSLog

/// Coordina i backup del database SQLite di [MetadataStore]: backup manuale su richiesta,
/// backup automatico a intervalli configurabili con rotazione dei file più vecchi, e
/// ripristino da un file di backup con copia di sicurezza del database corrente.
///
/// Le impostazioni sono persistite in `UserDefaults` (l'app non è sandboxed, quindi il
/// percorso della cartella di destinazione è sufficiente, senza security-scoped bookmark).
/// Il riferimento a [MetadataStore] è debole e viene impostato all'avvio da MainWindowView.
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

    /// Prefissi dei nomi file: quello automatico è distinto così la rotazione tocca solo
    /// i backup automatici, mai quelli manuali o le copie di sicurezza pre-ripristino.
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
            case .notReady:
                return L("backup.error.notReady")
            case .noDestination:
                return L("backup.error.noDestination")
            case .destinationMissing:
                return L("backup.error.destinationMissing")
            }
        }
    }

    @Published var destinationPath: String {
        didSet { UserDefaults.standard.set(destinationPath, forKey: Keys.destination) }
    }

    @Published var autoEnabled: Bool {
        didSet { UserDefaults.standard.set(autoEnabled, forKey: Keys.autoEnabled) }
    }

    /// Intervallo tra backup automatici, in ore (1…168 = una settimana).
    @Published var intervalHours: Int {
        didSet { UserDefaults.standard.set(intervalHours, forKey: Keys.intervalHours) }
    }

    /// Numero di backup automatici da mantenere; i più vecchi vengono eliminati.
    @Published var keepCount: Int {
        didSet { UserDefaults.standard.set(keepCount, forKey: Keys.keepCount) }
    }

    @Published private(set) var lastBackupDate: Date?

    private weak var store: MetadataStore?
    private var timer: Timer?
    private var backupInProgress = false

    init() {
        let defaults = UserDefaults.standard
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
        timer?.invalidate()
    }

    /// Collega lo store e avvia lo scheduler. Da chiamare una volta all'avvio.
    func configure(store: MetadataStore) {
        self.store = store
        startScheduler()
        // Un backup potrebbe essere già scaduto mentre l'app era chiusa.
        performAutoBackupIfDue()
    }

    private func startScheduler() {
        timer?.invalidate()
        // Controllo periodico leggero: il backup parte solo se è trascorso l'intervallo.
        let checkTimer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performAutoBackupIfDue() }
        }
        RunLoop.main.add(checkTimer, forMode: .common)
        timer = checkTimer
    }

    /// Esegue un backup automatico se abilitato e se è trascorso l'intervallo configurato.
    func performAutoBackupIfDue() {
        guard autoEnabled, !destinationPath.isEmpty else { return }
        if let last = lastBackupDate,
           Date().timeIntervalSince(last) < Double(intervalHours) * 3600 {
            return
        }
        do {
            _ = try runBackup(auto: true)
        } catch {
            Self.log.error("Backup automatico fallito: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Esegue un backup del database nella cartella configurata.
    /// - Parameter auto: se `true` usa il prefisso automatico, aggiorna il timestamp e
    ///   applica la rotazione; se `false` è un backup manuale (nessuna cancellazione).
    @discardableResult
    func runBackup(auto: Bool) throws -> URL {
        guard let store else { throw BackupError.notReady }
        guard !destinationPath.isEmpty else { throw BackupError.noDestination }
        guard !backupInProgress else { throw BackupError.notReady }
        backupInProgress = true
        defer { backupInProgress = false }

        let folder = URL(fileURLWithPath: destinationPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BackupError.destinationMissing
        }

        let name = (auto ? Prefix.auto : Prefix.manual) + Self.timestamp() + ".sqlite"
        let destination = folder.appendingPathComponent(name)
        try store.backup(to: destination)

        lastBackupDate = Date()
        UserDefaults.standard.set(lastBackupDate!.timeIntervalSince1970, forKey: Keys.lastTimestamp)

        if auto {
            pruneAutoBackups(in: folder)
        }
        return destination
    }

    /// Ripristina il database da `sourceURL`, salvando prima una copia di sicurezza del
    /// database attuale (accanto al DB gestito) così l'operazione resta annullabile.
    func restore(from sourceURL: URL) throws {
        guard let store else { throw BackupError.notReady }

        let safetyURL = store.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent(Prefix.preRestore + Self.timestamp() + ".sqlite")
        try? store.backup(to: safetyURL)

        try store.restore(from: sourceURL)
    }

    /// Mantiene solo i `keepCount` backup automatici più recenti nella cartella.
    private func pruneAutoBackups(in folder: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }

        // Il timestamp nel nome è ordinabile lessicograficamente: i più recenti in coda.
        let autoBackups = files
            .filter { $0.lastPathComponent.hasPrefix(Prefix.auto) && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard autoBackups.count > keepCount else { return }
        for url in autoBackups.prefix(autoBackups.count - keepCount) {
            try? fm.removeItem(at: url)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
