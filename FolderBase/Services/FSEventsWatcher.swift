import CoreServices
import Foundation
import os.log

/// Osserva un insieme di cartelle con FSEvents e notifica (debounced, sul main thread)
/// qualsiasi modifica al loro contenuto — anche fatta da altre app come il Finder.
/// Usato per le cartelle "gestite" (con metadata) oltre a quella aperta, così il database
/// resta riallineato quando file vengono spostati, rinominati o cancellati altrove.
final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "FolderBase.FSEvents")
    private let onChange: ([String]) -> Void
    private var debounceWork: DispatchWorkItem?
    private let latency: CFTimeInterval = 0.3
    private var watchedPaths: [String] = []
    private var retryWork: DispatchWorkItem?
    private var retryAttempts = 0
    private var pendingChangedPaths: Set<String> = []
    private let maxRetryAttempts = 3

    private static let log = Logger(subsystem: "com.paolosturbini.folderbase", category: "FSEvents")

    init(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit {
        retryWork?.cancel()
        stop()
    }

    /// (Ri)avvia l'osservazione sull'insieme di percorsi indicato. Idempotente: se i percorsi
    /// non cambiano non ricrea lo stream.
    ///
    /// I percorsi che non esistono (o non sono directory) vengono scartati: passare a
    /// `FSEventStreamCreate` percorsi non più esistenti — es. una cartella gestita su un
    /// volume esterno non ancora rimontato dopo sleep/wake, o cancellata — può far fallire
    /// la creazione dello stream e, per un bug del framework FSEvents (macOS 26), il suo
    /// percorso di errore chiude il file descriptor 0 (guarded) → crash EXC_GUARD.
    func watch(paths: [String]) {
        let fm = FileManager.default
        let existing = paths.filter { path in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let normalized = Array(Set(existing)).sorted()
        guard normalized != watchedPaths else { return }
        watchedPaths = normalized

        stop()
        guard !normalized.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)

        // Bug di FSEvents (macOS 26): se la creazione dello stream fallisce internamente, il suo
        // percorso di errore esegue close(0). Se fd 0 è il nostro tappo /dev/null (non protetto)
        // non succede nulla; ma quel close LIBERA fd 0, e se una libreria di sistema (es. SQLite)
        // vi apre poi un descriptor PROTETTO, il fallimento SUCCESSIVO scatena EXC_GUARD e l'app
        // muore (visto riaprendo la finestra dalla barra dei menu). Difesa in due mosse:
        // ri-tappare fd 0..2 sia PRIMA della chiamata (nel caso qualcosa li abbia liberati)
        // sia SUBITO DOPO (un fallimento ha appena chiuso fd 0: va rioccupato all'istante).
        ensureStandardFileDescriptors()
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            normalized as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )
        ensureStandardFileDescriptors()

        guard let stream = created else {
            // Non fatale: fseventsd può essere momentaneamente indisponibile (es. subito dopo
            // il risveglio dal sleep). Logga e riprova più tardi invece di restare senza watcher.
            Self.log.error("FSEventStreamCreate fallita per \(normalized.count) percorsi; nuovo tentativo tra 10s (\(self.retryAttempts + 1)/\(self.maxRetryAttempts))")
            scheduleRetry(paths: normalized)
            return
        }

        retryAttempts = 0
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Ritenta la creazione dello stream dopo un fallimento (limitato per non insistere
    /// all'infinito se fseventsd resta indisponibile: la ricerca/reconcile funziona comunque).
    private func scheduleRetry(paths: [String]) {
        guard retryAttempts < maxRetryAttempts else { return }
        retryAttempts += 1
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            watchedPaths = []   // forza la ricreazione oltre il controllo di idempotenza
            watch(paths: paths)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Chiamato dal callback C: coalizza più eventi ravvicinati in un'unica notifica.
    fileprivate func scheduleNotification(paths: [String]) {
        pendingChangedPaths.formUnion(paths)
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.pendingChangedPaths)
            self.pendingChangedPaths.removeAll()
            self.onChange(paths)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

/// Callback C di FSEvents: recupera l'istanza da `info` e inoltra la notifica.
private func fsEventsCallback(
    stream: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
    watcher.scheduleNotification(paths: paths)
}
