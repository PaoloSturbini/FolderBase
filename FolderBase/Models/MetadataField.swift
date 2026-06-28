import Foundation

enum MetadataFieldType: String, Codable, CaseIterable {
    case text
    case select
    case multiSelect
    case date
    case checkbox
    case number
    case url
}

struct MetadataField: Identifiable, Codable {
    var id: UUID
    var name: String
    var type: MetadataFieldType
    var options: [String]
    var folderPath: String?
}
