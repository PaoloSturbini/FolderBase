import Foundation

/// Legge il contenuto di una cartella. È puro e senza stato: nessun accesso a
/// `MetadataStore`, quindi può essere eseguito in sicurezza su un thread di background.
final class FileBrowserService {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .creationDateKey, .fileSizeKey, .contentTypeKey,
        .fileResourceIdentifierKey, .volumeIdentifierKey
    ]
    private static let identityKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .fileResourceIdentifierKey, .volumeIdentifierKey
    ]

    struct Preview: Sendable {
        let items: [FileItem]
        let needsEnrichment: Bool
    }

    /// Per directory grandi restituisce prima nomi, tipo base e identità. Dimensione, data e
    /// content type arrivano con la lettura completa successiva, senza cambiare gli ID delle righe.
    func previewOfDirectory(at url: URL, showHiddenFiles: Bool = false, detailedThreshold: Int = 800) throws -> Preview {
        let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(Self.identityKeys), options: options
        )
        // Per le cartelle normali una sola lettura completa è più rapida di due pubblicazioni
        // SwiftUI consecutive. Solo oltre la soglia usiamo il primo paint leggero.
        if urls.count <= detailedThreshold {
            return Preview(
                items: try makeItems(urls: urls, resourceKeys: Self.resourceKeys, detailed: true),
                needsEnrichment: false
            )
        }
        return Preview(
            items: try makeItems(urls: urls, resourceKeys: Self.identityKeys, detailed: false),
            needsEnrichment: !urls.isEmpty
        )
    }

    func contentsOfDirectory(at url: URL, showHiddenFiles: Bool = false) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: options
        )

        return try makeItems(urls: urls, resourceKeys: Self.resourceKeys, detailed: true)
    }

    private func makeItems(urls: [URL], resourceKeys: Set<URLResourceKey>, detailed: Bool) throws -> [FileItem] {
        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for fileURL in urls where !FileSystemPolicy.isInTrash(fileURL) {
            if Task.isCancelled { return [] }
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            let isFolder = values.isDirectory ?? false
            let identity = MetadataStore.identity(for: fileURL, resourceValues: values)
            let type = isFolder ? L("file.folderType") : (detailed ? values.contentType?.localizedDescription : nil) ?? fileURL.pathExtension.uppercased()
            let name = fileURL.lastPathComponent
            items.append(FileItem(
                    identity: identity,
                    url: fileURL,
                    name: name,
                    type: type,
                    created: detailed ? values.creationDate ?? .distantPast : .distantPast,
                    size: detailed && !isFolder ? values.fileSize.map(Int64.init) : nil,
                    isFolder: isFolder,
                    sortNameKey: name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                    sortTypeKey: type.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            ))
        }
        return items.sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder {
                    return lhs.isFolder && !rhs.isFolder
                }

                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
