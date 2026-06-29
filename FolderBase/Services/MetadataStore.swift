import Foundation

struct FileMetadata: Codable, Equatable {
    var values: [String: String]

    static let empty = FileMetadata(values: [:])
}

private struct MetadataDocument: Codable {
    var fieldsByFolder: [String: [MetadataField]]
    var metadataByPath: [String: FileMetadata]
}

final class MetadataStore: ObservableObject {
    /// Colonne metadata definite per ogni cartella (chiave = path della cartella).
    @Published private(set) var fieldsByFolder: [String: [MetadataField]] = [:]
    @Published private(set) var metadataByPath: [String: FileMetadata] = [:]

    private let metadataURL: URL

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderBase", isDirectory: true)

        self.metadataURL = supportURL.appendingPathComponent("metadata.json")

        do {
            try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try load()
        } catch {
            fieldsByFolder = [:]
            metadataByPath = [:]
        }
    }

    /// Colonne configurate per la cartella indicata. Una cartella nuova parte senza colonne.
    func fields(for folderURL: URL?) -> [MetadataField] {
        guard let folderURL else { return [] }
        return fieldsByFolder[folderURL.path] ?? []
    }

    func metadata(for fileURL: URL) -> FileMetadata {
        metadataByPath[fileURL.path] ?? .empty
    }

    func value(for fileURL: URL, field: MetadataField) -> String {
        metadata(for: fileURL).values[field.id] ?? defaultValue(for: field)
    }

    func update(fileURL: URL, field: MetadataField, value: String) {
        var metadata = self.metadata(for: fileURL)
        metadata.values[field.id] = value
        metadataByPath[fileURL.path] = metadata
        save()
    }

    func addField(folderURL: URL, name: String, kind: MetadataFieldKind, options: [String]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let field = MetadataField(
            id: UUID().uuidString,
            name: trimmedName,
            kind: kind,
            options: normalizedOptions(for: kind, options: options)
        )

        var current = fieldsByFolder[folderURL.path] ?? []
        current.append(field)
        fieldsByFolder[folderURL.path] = current
        save()
    }

    func removeField(folderURL: URL, field: MetadataField) {
        guard var current = fieldsByFolder[folderURL.path] else { return }
        current.removeAll { $0.id == field.id }
        fieldsByFolder[folderURL.path] = current
        save()
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            fieldsByFolder = [:]
            metadataByPath = [:]
            return
        }

        let data = try Data(contentsOf: metadataURL)

        if let document = try? JSONDecoder().decode(MetadataDocument.self, from: data) {
            fieldsByFolder = document.fieldsByFolder
            metadataByPath = document.metadataByPath
            return
        }

        // Formato non riconosciuto (vecchie versioni): si riparte puliti.
        fieldsByFolder = [:]
        metadataByPath = [:]
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let document = MetadataDocument(fieldsByFolder: fieldsByFolder, metadataByPath: metadataByPath)
            let data = try encoder.encode(document)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            assertionFailure("Failed to save metadata: \(error)")
        }
    }

    private func defaultValue(for field: MetadataField) -> String {
        if field.kind == .select {
            return field.options.first ?? ""
        }

        return ""
    }

    private func normalizedOptions(for kind: MetadataFieldKind, options: [String]) -> [String] {
        guard kind == .select else { return [] }

        let cleaned = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(NSOrderedSet(array: cleaned)) as? [String] ?? cleaned
    }
}
