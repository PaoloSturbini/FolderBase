import Foundation

/// Archivio dei template (globali, non legati a una cartella), persistito come JSON in
/// Application Support/FolderBase/templates.json. Indipendente dal database SQLite dei
/// metadata per non complicarne la migrazione di schema.
final class TemplateStore: ObservableObject {
    @Published private(set) var templates: [MetadataTemplate] = []

    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderBase", isDirectory: true)
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        self.fileURL = supportURL.appendingPathComponent("templates.json")
        load()
    }

    func add(_ template: MetadataTemplate) {
        templates.append(template)
        save()
    }

    func update(_ template: MetadataTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else {
            add(template)
            return
        }
        templates[index] = template
        save()
    }

    func delete(id: String) {
        templates.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MetadataTemplate].self, from: data) else { return }
        templates = decoded
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(templates)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Failed to save templates: \(error)")
        }
    }
}
