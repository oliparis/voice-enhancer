import AVFoundation

/// Presents the app only when macOS needs to ask for microphone permission.
@MainActor
public enum CapturePermissionRequest {
    public static func needsForeground(for status: AVAuthorizationStatus) -> Bool {
        status == .notDetermined
    }

    public static func request(
        authorizationStatus: AVAuthorizationStatus,
        presentApplication: () -> Void,
        requestAccess: () async -> Bool
    ) async -> Bool {
        switch authorizationStatus {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            presentApplication()
            return await requestAccess()
        @unknown default:
            return false
        }
    }
}
