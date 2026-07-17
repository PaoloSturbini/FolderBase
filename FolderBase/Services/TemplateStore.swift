import Foundation

/// Archivio dei template (globali, non legati a una cartella), persistito come JSON in
/// Application Support/FolderBase/templates.json. Indipendente dal database SQLite dei
/// metadata per non complicarne la migrazione di schema.
final class TemplateStore: ObservableObject {
    @Published private(set) var templates: [MetadataTemplate] = []
    @Published var activeTemplateID: String? {
        didSet { defaults.set(activeTemplateID, forKey: Self.activeTemplateKey) }
    }

    private let fileURL: URL
    private let defaults: UserDefaults
    private static let activeTemplateKey = "activeMetadataTemplateID"

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.activeTemplateID = defaults.string(forKey: Self.activeTemplateKey)
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderBase", isDirectory: true)
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        self.fileURL = supportURL.appendingPathComponent("templates.json")
        load()
        if activeTemplateID != nil, activeTemplate == nil { activeTemplateID = nil }
    }

    var activeTemplate: MetadataTemplate? {
        guard let activeTemplateID else { return nil }
        return templates.first { $0.id == activeTemplateID }
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
        if activeTemplateID == id { activeTemplateID = nil }
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
