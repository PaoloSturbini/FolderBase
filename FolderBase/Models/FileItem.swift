import Foundation

struct FileItem: Identifiable, Hashable, Sendable {
    var id: String { identity }
    var identity: String
    var url: URL
    var name: String
    var type: String
    var created: Date
    var size: Int64?
    var isFolder: Bool

    /// Formatter condivisi: crearne uno nuovo per ogni cella a ogni render (come prima)
    /// è molto costoso — l'inizializzazione di DateFormatter richiede millisecondi.
    private static let createdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var createdDescription: String {
        Self.createdFormatter.string(from: created)
    }

    var sizeDescription: String {
        guard let size else { return "—" }
        return Self.sizeFormatter.string(fromByteCount: size)
    }
}
