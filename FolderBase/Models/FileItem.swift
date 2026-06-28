import Foundation

struct FileItem: Identifiable {
    let id = UUID()
    var name: String
    var type: String
    var created: Date
    var size: Int64?
    var isFolder: Bool
    var note: String
    var status: String

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

    static let sample: [FileItem] = [
        FileItem(name: "Argentea", type: "Folder", created: Date(), size: nil, isFolder: true, note: "progetto riduzione POS Argentea file fondamentali", status: "doing"),
        FileItem(name: "FUEL", type: "Folder", created: Date(), size: nil, isFolder: true, note: "Progetto Fuel Card Italy", status: "doing"),
        FileItem(name: "Template corporate_semplice.pptx", type: "pptx", created: Date(), size: 90132, isFolder: false, note: "Corporate template", status: "done")
    ]
}
