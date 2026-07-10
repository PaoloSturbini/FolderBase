import Foundation

/// Regole condivise da navigazione, ricerca e indicizzazione.
enum FileSystemPolicy {
    /// Riconosce sia il Cestino dell'utente (`~/.Trash`) sia quelli dei volumi
    /// (`/Volumes/<volume>/.Trashes`). Il confronto per componenti evita falsi positivi.
    nonisolated static func isInTrash(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL.path
        let path = standardized.path
        if path == homeTrash || path.hasPrefix(homeTrash + "/") { return true }

        let components = standardized.pathComponents
        return components.contains(".Trashes") || components.contains(".Trash")
    }
}
