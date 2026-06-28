import Foundation

final class FileBrowserService {
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey, .typeIdentifierKey],
            options: [.skipsHiddenFiles]
        )
    }
}
