import Foundation
import ServiceManagement
import os

/// Gestisce l'avvio automatico di FolderBase al login del Mac.
///
/// Usa `SMAppService.mainApp` (macOS 13+), che registra l'intera app come
/// login item senza bisogno di un helper separato. Lo stato reale è quello
/// riportato dal sistema (`status`), quindi al ritorno da Impostazioni di
/// sistema chiamiamo `refresh()` per riallineare l'interfaccia.
@MainActor
final class LaunchAtLoginService: ObservableObject {
    static let shared = LaunchAtLoginService()

    private static let log = Logger(subsystem: "com.paolosturbini.folderbase", category: "LaunchAtLogin")

    /// Riflette lo stato corrente del login item. Pubblicato così i toggle in
    /// SwiftUI si aggiornano da soli.
    @Published private(set) var isEnabled: Bool

    private init() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    /// Riallinea `isEnabled` allo stato riportato dal sistema.
    func refresh() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    /// Attiva o disattiva l'avvio al login. In caso di errore ripristina lo
    /// stato reale così l'interfaccia non resta disallineata.
    func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            Self.log.error("Impossibile aggiornare l'avvio al login: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
