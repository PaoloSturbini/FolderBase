import AppKit
import Carbon
import Darwin
import SwiftUI

/// Dati necessari per aprire una directory in una finestra indipendente senza perdere la
/// gerarchia metadata della vista di origine.
struct FolderWindowRequest: Codable, Hashable {
    let folderPath: String
    let configurationRootPath: String
}

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

        // Gestiamo NOI gli URL folderbase:// a livello di Apple Event, invece del `.onOpenURL`
        // di SwiftUI: quest'ultimo apriva una FINESTRA nuova del WindowGroup per recapitare
        // l'URL. Registrando il gestore qui (dopo l'avvio di SwiftUI) diventiamo l'handler
        // effettivo e riusiamo l'istanza già aperta senza creare finestre intermedie.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Riceve gli URL con schema personalizzato (folderbase://open?id=…). Estrae l'identità e la
    /// inoltra al bridge; `MainWindowView` (istanza già aperta) la risolve e apre il file nell'app
    /// predefinita. Nessuna finestra nuova viene creata.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string),
              url.scheme == "folderbase",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else { return }
        // Gli Apple Event sono recapitati sul main thread: possiamo assumere l'isolamento MainActor.
        MainActor.assumeIsolated {
            MenuBarBridge.shared.requestedFileID = id
        }
    }
}

@main
struct FolderBaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Icona nella barra dei menu (top bar): consente di tenere FolderBase "ridotto" lì e
    /// riaprire la finestra direttamente su una delle cartelle disponibili. Disattivabile
    /// da Configurazione → Visualizzazione.
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        // L'id "main" permette al menu della barra dei menu di ritrovare/riaprire la finestra.
        // I deep link folderbase:// sono gestiti nell'AppDelegate (Apple Event), non con
        // `.onOpenURL`, per non far creare a SwiftUI una finestra intermedia.
        WindowGroup(id: "main") {
            MainWindowView()
        }

        // Finestre indipendenti aperte dal menu contestuale di una directory. Il valore è il
        // path della radice, così macOS può creare più istanze con navigazione separata.
        WindowGroup("FolderBase", for: FolderWindowRequest.self) { $request in
            MainWindowView(
                initialFolderURL: request.map { URL(fileURLWithPath: $0.folderPath) },
                inheritedConfigurationRootURL: request.map { URL(fileURLWithPath: $0.configurationRootPath) }
            )
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarMenu()
        } label: {
            Image(systemName: "folder.badge.gearshape")
        }
    }
}
