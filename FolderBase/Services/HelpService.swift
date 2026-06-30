import AppKit
import Foundation

/// Apre la guida HTML (Italiano/Inglese) nel browser di sistema, nella lingua scelta.
///
/// I file sorgente vivono in `FolderBase/Resources/help_it.html` e `help_en.html`.
/// A runtime li cerca, nell'ordine:
///  1. nel bundle dell'app (`make-app.sh` li copia in `Contents/Resources/`);
///  2. accanto al progetto quando si lancia con `swift run` (CWD = cartella progetto);
///  3. come ultima risorsa scrive una pagina minima in Application Support.
enum HelpService {
    /// Apre la guida nella lingua attualmente selezionata.
    static func openGuide(language: AppLanguage) {
        guard let url = resolveHelpURL(language: language) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func fileName(for language: AppLanguage) -> String {
        "help_\(language.rawValue).html"
    }

    private static func resolveHelpURL(language: AppLanguage) -> URL? {
        let resource = "help_\(language.rawValue)"

        // 1. Risorsa nel bundle (app installata da make-app.sh).
        if let bundled = Bundle.main.url(forResource: resource, withExtension: "html") {
            return bundled
        }

        // 2. File sorgente accanto al progetto (sviluppo con `swift run`).
        let cwd = FileManager.default.currentDirectoryPath
        let projectURL = URL(fileURLWithPath: cwd)
            .appendingPathComponent("FolderBase/Resources")
            .appendingPathComponent(fileName(for: language))
        if FileManager.default.fileExists(atPath: projectURL.path) {
            return projectURL
        }

        // 3. Fallback: scrivi una pagina minima in Application Support e aprila.
        return writeFallback(language: language)
    }

    private static func writeFallback(language: AppLanguage) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("FolderBase/Help", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(fileName(for: language))

        let title = language == .italian ? "Guida FolderBase" : "FolderBase Guide"
        let body = language == .italian
            ? "La guida completa non è stata trovata nel pacchetto dell'app. Consulta il repository del progetto."
            : "The full guide was not found inside the app bundle. Please refer to the project repository."
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <title>\(title)</title>
        <style>body{font-family:-apple-system,sans-serif;max-width:640px;margin:80px auto;padding:0 24px;line-height:1.6;color:#1d1d1f}a{color:#0a6cff}</style>
        </head><body><h1>FolderBase</h1><p>\(body)</p>
        <p><a href="https://github.com/PaoloSturbini/FolderBase">github.com/PaoloSturbini/FolderBase</a></p>
        </body></html>
        """
        do {
            try html.write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }
}
