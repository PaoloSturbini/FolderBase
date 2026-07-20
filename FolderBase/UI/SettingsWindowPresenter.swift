import AppKit
import SwiftUI

/// Finestra Configurazione autonoma e spostabile. La dimensione resta fissa per conservare il
/// layout progettato, ma non è più un foglio agganciato alla finestra principale.
@MainActor
enum SettingsWindowPresenter {
    private static var controller: NSWindowController?

    static func show(content: (@escaping () -> Void) -> AnyView) {
        if let window = controller?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("sidebar.configuration")
        window.isReleasedWhenClosed = false
        if let parentWindow {
            // Alla prima apertura la configurazione resta vicina all'angolo superiore sinistro
            // della finestra principale, come un pannello dell'app, invece di coprirne il centro.
            let horizontalInset = min(70, max(20, (parentWindow.frame.width - window.frame.width) / 2))
            let verticalRoom = parentWindow.frame.height - window.frame.height
            let verticalInset = min(220, max(70, verticalRoom * 0.7))
            let proposed = NSPoint(
                x: parentWindow.frame.minX + horizontalInset,
                y: parentWindow.frame.maxY - window.frame.height - verticalInset
            )
            window.setFrameOrigin(proposed)
            if let visible = parentWindow.screen?.visibleFrame {
                window.setFrame(window.frame.intersection(visible).size == window.frame.size
                    ? window.frame
                    : NSRect(
                        x: min(max(window.frame.origin.x, visible.minX), visible.maxX - window.frame.width),
                        y: min(max(window.frame.origin.y, visible.minY), visible.maxY - window.frame.height),
                        width: window.frame.width,
                        height: window.frame.height
                    ), display: false)
            }
        } else {
            window.center()
        }
        let windowController = FixedSettingsWindowController(window: window)
        windowController.onClose = { controller = nil }
        window.contentViewController = NSHostingController(rootView: content { window.close() })
        controller = windowController
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class FixedSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    override init(window: NSWindow?) {
        super.init(window: window)
        window?.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
