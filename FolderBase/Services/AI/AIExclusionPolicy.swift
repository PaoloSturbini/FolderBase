import Foundation

/// Percorso che FolderBase suggerisce di escludere dalle funzioni AI, con una motivazione
/// leggibile nella Configurazione. Nessun suggerimento viene applicato automaticamente.
struct AIExclusionSuggestion: Identifiable, Equatable, Sendable {
    let path: String
    let reason: String
    var id: String { path }
}

/// Un'unica policy per indicizzazione, ricerca per contenuto e fonti della chat.
/// Le esclusioni sono percorsi: una cartella esclude ricorsivamente tutto il suo sottoalbero,
/// mentre un file esclude soltanto sé stesso. I file già indicizzati restano nel DB derivato ma
/// non vengono più restituiti alla UI o inviati al modello.
enum AIExclusionPolicy {
    static let storageKey = "aiExcludedSourcePaths"
    typealias ExclusionsByRoot = [String: [String]]

    private static let generatedDirectoryNames: Set<String> = [
        "node_modules", "deriveddata", "build", "dist", "vendor", "pods",
        "__pycache__", ".venv", "venv", "tmp", "temp", "cache", ".cache",
        ".git", ".svn", ".hg", ".obsidian", ".trash", ".trashes"
    ]

    static func excludedPaths(defaults: UserDefaults = .standard) -> [String] {
        decode(defaults.data(forKey: storageKey) ?? Data())
    }

    /// Esclusioni appartenenti esclusivamente alla cartella principale indicata. Questo evita
    /// che la configurazione di una radice (in particolare quando le radici si sovrappongono)
    /// modifichi la scansione richiesta per un'altra.
    static func excludedPaths(forRoot root: URL, defaults: UserDefaults = .standard) -> [String] {
        let data = defaults.data(forKey: storageKey) ?? Data()
        let rootPath = normalizedPath(root.path)
        if let decoded = try? JSONDecoder().decode(ExclusionsByRoot.self, from: data) {
            return normalizedMapping(decoded)[rootPath] ?? []
        }
        let prefix = rootPath + "/"
        return decode(data).filter { $0 == rootPath || $0.hasPrefix(prefix) }
    }

    static func save(_ paths: [String], defaults: UserDefaults = .standard) {
        defaults.set(encode(paths), forKey: storageKey)
    }

    static func decode(_ data: Data) -> [String] {
        if let legacy = try? JSONDecoder().decode([String].self, from: data) {
            return normalizedUnique(legacy)
        }
        return normalizedUnique(Array(decodeByRoot(data).values.joined()))
    }

    static func encode(_ paths: [String]) -> Data {
        (try? JSONEncoder().encode(normalizedUnique(paths))) ?? Data()
    }

    static func decodeByRoot(_ data: Data, knownRoots: [URL] = []) -> ExclusionsByRoot {
        if let decoded = try? JSONDecoder().decode(ExclusionsByRoot.self, from: data) {
            return normalizedMapping(decoded)
        }
        // Migrazione trasparente dal vecchio array globale: assegna ogni percorso alla radice
        // gestita più specifica che lo contiene.
        let legacy = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        let roots = knownRoots.map { normalizedPath($0.path) }.sorted { $0.count > $1.count }
        var result: ExclusionsByRoot = [:]
        for path in normalizedUnique(legacy) {
            if let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                result[root, default: []].append(path)
            }
        }
        return normalizedMapping(result)
    }

    static func encode(_ mapping: ExclusionsByRoot) -> Data {
        (try? JSONEncoder().encode(normalizedMapping(mapping))) ?? Data()
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Mantiene soltanto le radici principali: se una cartella selezionata è già contenuta in
    /// un'altra radice, non rappresenta un indice autonomo.
    static func topLevelRoots(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let unique = urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        return unique.filter { candidate in
            !unique.contains { other in
                other.path != candidate.path && candidate.path.hasPrefix(other.path + "/")
            }
        }
    }

    static func isExcluded(_ url: URL, excludedPaths: [String]? = nil) -> Bool {
        isExcluded(path: url.path, excludedPaths: excludedPaths)
    }

    static func isExcluded(path: String, excludedPaths: [String]? = nil) -> Bool {
        let candidate = normalizedPath(path)
        let exclusions = excludedPaths ?? self.excludedPaths()
        return exclusions.contains { rawExclusion in
            let exclusion = normalizedPath(rawExclusion)
            return candidate == exclusion || candidate.hasPrefix(exclusion + "/")
        }
    }

    /// Analizza le radici gestite senza seguire pacchetti o scendere dentro una cartella già
    /// proposta. Il limite evita che un archivio enorme trasformi il suggerimento in una nuova
    /// indicizzazione completa.
    static func suggestions(
        under roots: [URL],
        excluding excludedPaths: [String],
        limit: Int = 100,
        visitedLimit: Int = 25_000
    ) -> [AIExclusionSuggestion] {
        let fileManager = FileManager.default
        var result: [AIExclusionSuggestion] = []
        var seen = Set<String>()
        var visited = 0

        for root in roots {
            guard result.count < limit, visited < visitedLimit else { break }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey],
                options: [.skipsPackageDescendants],
                errorHandler: nil
            ) else { continue }

            for case let url as URL in enumerator {
                visited += 1
                if visited >= visitedLimit || result.count >= limit { break }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey]),
                      values.isDirectory == true else { continue }

                let name = url.lastPathComponent
                let lowered = name.lowercased()
                let hidden = values.isHidden == true || name.hasPrefix(".")
                let generated = generatedDirectoryNames.contains(lowered)
                guard hidden || generated else { continue }

                enumerator.skipDescendants()
                let path = normalizedPath(url.path)
                guard !isExcluded(path: path, excludedPaths: excludedPaths), seen.insert(path).inserted else {
                    continue
                }
                result.append(AIExclusionSuggestion(
                    path: path,
                    reason: hidden ? L("ai.exclusions.reason.hidden") : L("ai.exclusions.reason.generated")
                ))
            }
        }
        return result.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func normalizedUnique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths
            .map(normalizedPath)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func normalizedMapping(_ mapping: ExclusionsByRoot) -> ExclusionsByRoot {
        var result: ExclusionsByRoot = [:]
        for (rawRoot, paths) in mapping {
            let root = normalizedPath(rawRoot)
            let prefix = root + "/"
            let contained = normalizedUnique(paths).filter { $0 == root || $0.hasPrefix(prefix) }
            if !contained.isEmpty { result[root] = contained }
        }
        return result
    }
}
