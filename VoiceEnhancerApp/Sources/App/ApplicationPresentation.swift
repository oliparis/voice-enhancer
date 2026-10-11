import AppKit

@MainActor
enum ApplicationPresentation {
    /// Bring the app forward before macOS asks for microphone access.
    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "main" || $0.title == "Voice Enhancer"
        }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
