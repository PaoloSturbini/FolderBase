import AppKit
import Combine
import SwiftUI

/// Ponte tra il menu della barra dei menu e la finestra principale. Singleton osservabile:
/// il menu ci scrive la cartella richiesta, `MainWindowView` la osserva e la carica. Si usa
/// un publisher (non una Notification) così la richiesta viene recapitata anche quando la
/// finestra è stata appena ricreata: `onReceive` su `@Published` emette il valore corrente
/// al momento della sottoscrizione.
@MainActor
final class MenuBarBridge: ObservableObject {
    static let shared = MenuBarBridge()
    @Published var requestedFolder: URL?
    private init() {}
}

/// Contenuto del menu dell'icona nella barra dei menu (top bar del Mac). Permette di tenere
/// FolderBase "ridotto" nella barra: si può chiudere o minimizzare la finestra e riaprirla
/// da qui direttamente su una delle cartelle disponibili (le recenti della sidebar).
struct MenuBarMenu: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @Environment(\.openWindow) private var openWindow

    /// Cartelle disponibili, lette da UserDefaults a ogni apertura del menu così l'elenco è
    /// sempre allineato alla sidebar senza condividere lo store con la finestra principale.
    private var availableFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentFolderPaths") ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    var body: some View {
        if availableFolders.isEmpty {
            Button(L("menubar.openApp")) { openMainWindow(folder: nil) }
        } else {
            Section(L("menubar.foldersHeader")) {
                ForEach(availableFolders, id: \.path) { url in
                    Button {
                        openMainWindow(folder: url)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "folder")
                    }
                }
            }
            Divider()
            Button(L("menubar.openApp")) { openMainWindow(folder: nil) }
        }
        Divider()
        Button(L("menubar.quit")) { NSApp.terminate(nil) }
    }

    /// Riporta in primo piano la finestra principale (deminimizzandola dal Dock o ricreandola
    /// se era stata chiusa) e, se richiesto, fa caricare la cartella scelta.
    private func openMainWindow(folder: URL?) {
        if let folder {
            MenuBarBridge.shared.requestedFolder = folder
        }
        if let window = mainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// La finestra di `WindowGroup(id: "main")`: SwiftUI le assegna un identifier con quel
    /// prefisso. Esclude la finestra di stato della barra dei menu.
    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }
}
