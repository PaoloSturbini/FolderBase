import Foundation

struct FileItem: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var name: String
    var type: String
    var created: Date
    var size: Int64?
    var isFolder: Bool

    var createdDescription: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: created)
    }

    var sizeDescription: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
