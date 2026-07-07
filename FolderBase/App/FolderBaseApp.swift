import AppKit
import Darwin
import SwiftUI

/// Assicura che i descriptor standard 0/1/2 (stdin/stdout/stderr) siano validi, puntandoli a
/// /dev/null se risultano chiusi. In un'app GUI lanciata dal Finder lo stdin (fd 0) può essere
/// chiuso: in quel caso i framework di sistema (FSEvents, Process/NSTask, …) "raccolgono" fd 0 per
/// le proprie risorse e poi crashano chiudendolo o duplicandolo → EXC_GUARD su fd 0. Tappando i
/// descriptor all'avvio si previene l'intera classe di crash (visti su FSEventStreamCreate e su
/// qlmanage). Idempotente: agisce solo sui descriptor davvero chiusi (EBADF), mai su quelli aperti.
func ensureStandardFileDescriptors() {
    for fd in Int32(0)...2 {
        guard fcntl(fd, F_GETFD) == -1, errno == EBADF else { continue }
        let opened = open("/dev/null", fd == 0 ? O_RDONLY : O_WRONLY)
        guard opened >= 0 else { continue }
        if opened != fd {
            dup2(opened, fd)
            close(opened)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        // Il prima possibile: prima che partano watcher FSEvents o processi esterni.
        ensureStandardFileDescriptors()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureStandardFileDescriptors()
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct FolderBaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindowView()
        }
    }
}
