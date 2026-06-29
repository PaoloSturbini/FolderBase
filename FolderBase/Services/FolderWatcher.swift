import Foundation

/// Osserva una singola cartella e notifica quando il suo contenuto cambia sul disco
/// (file aggiunti, rimossi o rinominati). Basato su DispatchSource sul vnode della directory.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
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
            self?.onChange()
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

    func stop() {
        source?.cancel()
        source = nil
    }
}
