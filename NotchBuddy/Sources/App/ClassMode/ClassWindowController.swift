#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - ClassWindowController
// Past classes live in a normal window, not in the notch: notes, a full
// transcript and a chat do not fit in a 640-point island, and reading them is
// not a glance-and-go task.

@MainActor
final class ClassWindowController {
    static let shared = ClassWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Mis clases — Coucou"
        window.contentView = NSHostingView(rootView: ClassHistoryView())
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
