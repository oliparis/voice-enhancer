import Foundation

/// Serializes graph mutations on the main actor while allowing permission
/// prompts to suspend. Stop or a newer start invalidates a pending request.
@MainActor
public final class CaptureStartCoordinator {
    private var generation: UInt64 = 0

    public init() {}

    public func invalidate() {
        generation &+= 1
    }

    public func start(after permission: () async throws -> Void,
                      configure: () throws -> Void) async throws {
        generation &+= 1
        let request = generation
        try await permission()
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        // No suspension inside configuration: start/stop cannot interleave.
        try configure()
    }
}
