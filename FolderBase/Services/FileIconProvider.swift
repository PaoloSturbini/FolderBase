import AppKit
import UniformTypeIdentifiers

/// Fornisce l'icona che il sistema (Finder) mostrerebbe per un file o cartella, ossia
/// l'icona dell'app predefinita associata a quel tipo di file.
///
/// La Table di SwiftUI ridisegna le celle molto spesso, quindi le icone vengono messe
/// in cache: per i file "normali" la chiave è l'estensione (poche icone distinte,
/// nessun I/O per ogni file), per cartelle, bundle (.app) ed elementi senza estensione
/// la chiave è il percorso completo così da rispettare anche le icone personalizzate.
enum FileIconProvider {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for item: FileItem) -> NSImage {
        let ext = item.url.pathExtension.lowercased()
        let usesTypeIcon = !item.isFolder && !ext.isEmpty && ext != "app"

        let key: NSString = usesTypeIcon ? ("ext:" + ext) as NSString : ("path:" + item.url.path) as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let icon: NSImage
        if usesTypeIcon, let type = UTType(filenameExtension: ext) {
            // Icona standard del tipo (es. l'icona documento dell'app predefinita).
            icon = NSWorkspace.shared.icon(for: type)
        } else {
            // Cartelle, app bundle, file senza estensione o tipo sconosciuto: icona reale del file.
            icon = NSWorkspace.shared.icon(forFile: item.url.path)
        }

        cache.setObject(icon, forKey: key)
        return icon
    }
}
