import Foundation

/// Legge il contenuto di una cartella. È puro e senza stato: nessun accesso a
/// `MetadataStore`, quindi può essere eseguito in sicurezza su un thread di background.
final class FileBrowserService {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .creationDateKey, .fileSizeKey, .contentTypeKey,
        .fileResourceIdentifierKey, .volumeIdentifierKey
    ]

    func contentsOfDirectory(at url: URL, showHiddenFiles: Bool = false) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: options
        )

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for fileURL in urls {
            if Task.isCancelled { return [] }
            let values = try fileURL.resourceValues(forKeys: Self.resourceKeys)
            let isFolder = values.isDirectory ?? false
            let identity = MetadataStore.identity(for: fileURL, resourceValues: values)
            items.append(FileItem(
                    identity: identity,
                    url: fileURL,
                    name: fileURL.lastPathComponent,
                    type: isFolder ? L("file.folderType") : values.contentType?.localizedDescription ?? fileURL.pathExtension.uppercased(),
                    created: values.creationDate ?? .distantPast,
                    size: isFolder ? nil : Int64(values.fileSize ?? 0),
                    isFolder: isFolder
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
