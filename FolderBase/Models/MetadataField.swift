import Foundation

enum MetadataFieldKind: String, CaseIterable, Codable, Identifiable {
    case text = "Nota libera"
    case number = "Numero"
    case date = "Data"
    case kanban = "Kanban"
    case select = "Select"
    case link = "Link"

    var id: String { rawValue }

    /// I tipi che usano un elenco di opzioni colorate.
    var usesOptions: Bool {
        self == .select || self == .kanban
    }
}

enum MetadataTagColor: String, CaseIterable, Codable, Identifiable {
    case gray
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gray:
            return "Grigio"
        case .red:
            return "Rosso"
        case .orange:
            return "Arancio"
        case .yellow:
            return "Giallo"
        case .green:
            return "Verde"
        case .blue:
            return "Blu"
        case .purple:
            return "Viola"
        case .pink:
            return "Rosa"
        }
    }
}

struct MetadataSelectOption: Identifiable, Codable, Hashable {
    var id: String
    var label: String
    var color: MetadataTagColor

    init(id: String = UUID().uuidString, label: String, color: MetadataTagColor = .gray) {
        self.id = id
        self.label = label
        self.color = color
    }
}

struct MetadataField: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: MetadataFieldKind
    var options: [MetadataSelectOption]

    init(id: String, name: String, kind: MetadataFieldKind, options: [MetadataSelectOption]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(MetadataFieldKind.self, forKey: .kind)

        if let decodedOptions = try? container.decode([MetadataSelectOption].self, forKey: .options) {
            options = decodedOptions
        } else {
            let legacyOptions = (try? container.decode([String].self, forKey: .options)) ?? []
            options = legacyOptions.map { MetadataSelectOption(label: $0, color: .gray) }
        }
    }
}

/// Conversioni stabili per i valori dei campi numerici e data, salvati come testo.
enum MetadataValueFormatter {
    /// Formato canonico di salvataggio per le date: solo giorno, ordinabile come stringa.
    private static let storageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Formato mostrato all'utente nelle celle (localizzato).
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func string(from date: Date) -> String {
        storageFormatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        storageFormatter.date(from: string.trimmingCharacters(in: .whitespaces))
    }

    static func displayDate(from string: String) -> String {
        guard let date = date(from: string) else { return string }
        return displayFormatter.string(from: date)
    }

    static func number(from string: String) -> Double? {
        let normalized = string
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }
}
