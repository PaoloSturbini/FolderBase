import CoreServices
import Foundation

/// Osserva un insieme di cartelle con FSEvents e notifica (debounced, sul main thread)
/// qualsiasi modifica al loro contenuto — anche fatta da altre app come il Finder.
/// Usato per le cartelle "gestite" (con metadata) oltre a quella aperta, così il database
/// resta riallineato quando file vengono spostati, rinominati o cancellati altrove.
final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "FolderBase.FSEvents")
    private let onChange: () -> Void
    private var debounceWork: DispatchWorkItem?
    private let latency: CFTimeInterval = 0.3
    private var watchedPaths: [String] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// (Ri)avvia l'osservazione sull'insieme di percorsi indicato. Idempotente: se i percorsi
    /// non cambiano non ricrea lo stream.
    func watch(paths: [String]) {
        let normalized = Array(Set(paths)).sorted()
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

        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            normalized as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Chiamato dal callback C: coalizza più eventi ravvicinati in un'unica notifica.
    fileprivate func scheduleNotification() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
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
    watcher.scheduleNotification()
}
