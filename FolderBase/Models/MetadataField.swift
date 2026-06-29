import Foundation

enum MetadataFieldKind: String, CaseIterable, Codable, Identifiable {
    case text = "Nota libera"
    case select = "Select"
    case link = "Link"

    var id: String { rawValue }
}

struct MetadataField: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: MetadataFieldKind
    var options: [String]
}
