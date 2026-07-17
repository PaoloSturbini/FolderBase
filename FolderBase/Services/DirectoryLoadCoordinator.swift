import Foundation

/// Un solo caricamento per percorso: albero e tabella condividono la stessa scansione invece di
/// competere sul filesystem. Le Task detached non ereditano il main actor.
actor DirectoryLoadCoordinator {
    static let shared = DirectoryLoadCoordinator()

    private struct Key: Hashable { let path: String; let showHidden: Bool }
    private var previewTasks: [Key: Task<FileBrowserService.Preview, Error>] = [:]
    private var detailTasks: [Key: Task<[FileItem], Error>] = [:]

    func preview(at url: URL, showHiddenFiles: Bool) async throws -> FileBrowserService.Preview {
        let key = Key(path: url.standardizedFileURL.path, showHidden: showHiddenFiles)
        if let task = previewTasks[key] { return try await task.value }
        let task = Task.detached(priority: .userInitiated) {
            try FileBrowserService().previewOfDirectory(at: url, showHiddenFiles: showHiddenFiles)
        }
        previewTasks[key] = task
        defer { previewTasks[key] = nil }
        return try await task.value
    }

    func details(at url: URL, showHiddenFiles: Bool) async throws -> [FileItem] {
        let key = Key(path: url.standardizedFileURL.path, showHidden: showHiddenFiles)
        if let task = detailTasks[key] { return try await task.value }
        let task = Task.detached(priority: .utility) {
            try FileBrowserService().contentsOfDirectory(at: url, showHiddenFiles: showHiddenFiles)
        }
        detailTasks[key] = task
        defer { detailTasks[key] = nil }
        return try await task.value
    }
}
