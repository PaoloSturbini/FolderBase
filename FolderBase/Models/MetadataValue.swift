import Foundation

struct MetadataValue: Identifiable, Codable {
    var id: UUID
    var filePath: String
    var fieldId: UUID
    var value: String
}
