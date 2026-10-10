import AppKit
import Foundation

/// Routes workspace wake events into the existing capture recovery coordinator.
/// Observe only wake; the audio engine/device listeners handle route changes.
public final class CaptureWakeMonitor {
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    @MainActor
    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
                onWake: @escaping @MainActor @Sendable () -> Void) {
        self.center = center
        observer = center.addObserver(forName: NSWorkspace.didWakeNotification,
                                      object: nil, queue: .main) { _ in
            Task { @MainActor in onWake() }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }
}
