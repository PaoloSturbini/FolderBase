import Foundation

/// Definizione di un singolo campo dentro un template: come `MetadataField` ma senza
/// legame a una cartella (è una "ricetta" riutilizzabile).
struct FieldTemplate: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: MetadataFieldKind
    var options: [MetadataSelectOption]

    init(id: String = UUID().uuidString, name: String, kind: MetadataFieldKind, options: [MetadataSelectOption] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.options = options
    }
}

/// Un template è un insieme ordinato di campi (nome + tipo + opzioni) che può essere
/// applicato a una cartella priva di struttura FolderBase per generarne le colonne.
struct MetadataTemplate: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var fields: [FieldTemplate]

    init(id: String = UUID().uuidString, name: String, fields: [FieldTemplate] = []) {
        self.id = id
        self.name = name
        self.fields = fields
    }
}
