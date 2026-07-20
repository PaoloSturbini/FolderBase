import AppKit
import SwiftUI

/// Presenta la chat in una vera finestra macOS: indipendente dalla finestra principale,
/// ridimensionabile, minimizzabile e liberamente spostabile tra Scrivanie/monitor.
@MainActor
enum ChatWindowPresenter {
    private static var controllers: [ObjectIdentifier: ChatWindowController] = [:]

    static func show(chatService: ChatService, store: MetadataStore, focusedFile: FileItem?) {
        let controller = ChatWindowController(
            chatService: chatService,
            store: store,
            focusedFile: focusedFile
        )
        guard let window = controller.window else { return }
        controllers[ObjectIdentifier(window)] = controller
        controller.onClose = { closedWindow in
            controllers.removeValue(forKey: ObjectIdentifier(closedWindow))
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class ChatWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((NSWindow) -> Void)?

    init(chatService: ChatService, store: MetadataStore, focusedFile: FileItem?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("chat.title")
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ChatView(
            chatService: chatService,
            store: store,
            focusedFile: focusedFile,
            dismiss: { [weak window] in window?.close() }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onClose?(window)
    }
}
