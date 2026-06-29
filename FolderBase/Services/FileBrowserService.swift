import Foundation

final class FileBrowserService {
    func contentsOfDirectory(at url: URL, metadataStore: MetadataStore) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey, .contentTypeKey],
            options: [.skipsHiddenFiles]
        )

        return try urls
            .map { fileURL in
                let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey, .contentTypeKey])
                let isFolder = values.isDirectory ?? false

                return FileItem(
                    url: fileURL,
                    name: fileURL.lastPathComponent,
                    type: isFolder ? "Folder" : values.contentType?.localizedDescription ?? fileURL.pathExtension.uppercased(),
                    created: values.creationDate ?? .distantPast,
                    size: isFolder ? nil : Int64(values.fileSize ?? 0),
                    isFolder: isFolder
                )
            }
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder {
                    return lhs.isFolder && !rhs.isFolder
                }

                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
