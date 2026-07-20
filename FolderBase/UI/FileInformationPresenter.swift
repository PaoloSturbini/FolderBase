import AppKit
import Foundation

/// Mostra informazioni essenziali senza delegare a Finder (e quindi senza richiedere permessi
/// Apple Events). Funziona allo stesso modo per file e cartelle.
@MainActor
func showFileInformation(for url: URL) {
    let normalized = url.standardizedFileURL
    let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .contentTypeKey, .isReadableKey, .isWritableKey
    ]
    let values = try? normalized.resourceValues(forKeys: keys)
    let isDirectory = values?.isDirectory == true
    let kind = values?.contentType?.localizedDescription
        ?? (isDirectory ? L("info.kind.folder") : L("info.kind.file"))
    let size = isDirectory
        ? L("info.size.folder")
        : values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    dateFormatter.timeStyle = .medium
    let created = values?.creationDate.map(dateFormatter.string(from:)) ?? "—"
    let modified = values?.contentModificationDate.map(dateFormatter.string(from:)) ?? "—"
    let access = [
        values?.isReadable == true ? L("info.access.read") : nil,
        values?.isWritable == true ? L("info.access.write") : nil
    ].compactMap { $0 }.joined(separator: ", ")

    let details = """
    \(L("info.kind")): \(kind)
    \(L("info.location")): \(normalized.deletingLastPathComponent().path)
    \(L("info.size")): \(size)
    \(L("info.created")): \(created)
    \(L("info.modified")): \(modified)
    \(L("info.access")): \(access.isEmpty ? "—" : access)
    """

    let text = NSTextField(wrappingLabelWithString: details)
    text.frame = NSRect(x: 0, y: 0, width: 460, height: 126)
    text.isSelectable = true
    let alert = NSAlert()
    alert.messageText = normalized.lastPathComponent
    alert.informativeText = normalized.path
    alert.icon = NSWorkspace.shared.icon(forFile: normalized.path)
    alert.accessoryView = text
    alert.addButton(withTitle: L("common.done"))
    alert.runModal()
}
