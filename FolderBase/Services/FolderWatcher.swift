import Foundation

/// Osserva una singola cartella e notifica quando il suo contenuto cambia sul disco
/// (file aggiunti, rimossi o rinominati). Basato su DispatchSource sul vnode della directory.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let onChange: () -> Void
    private let debounce: TimeInterval
    private var pendingNotification: DispatchWorkItem?

    init(url: URL, debounce: TimeInterval = 0.25, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.debounce = debounce
        start(url: url)
    }

    deinit {
        stop()
    }

    private func start(url: URL) {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleNotification()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        source.resume()
        self.source = source
    }

    /// Raggruppa raffiche di eventi (es. copia di molti file) in una sola notifica.
    private func scheduleNotification() {
        pendingNotification?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pendingNotification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func stop() {
        pendingNotification?.cancel()
        pendingNotification = nil
        source?.cancel()
        source = nil
    }
}
