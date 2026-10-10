import CaptureLifecycle
import Foundation

@MainActor
final class PermissionPrompt {
    private var waiting: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func allow() { waiting?.resume(); waiting = nil }
    var isWaiting: Bool { waiting != nil }
}

enum TestError: Error { case denied }

@main
struct CaptureLifecycleTests {
    @MainActor
    static func main() async {
        let coordinator = CaptureStartCoordinator()
        var graphs = 0
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func cancelled(_ task: Task<Void, Error>) async -> Bool {
            do { try await task.value; return false } catch is CancellationError { return true } catch { return false }
        }

        let stoppedPrompt = PermissionPrompt()
        let stopped = Task { try await coordinator.start(after: stoppedPrompt.wait) { graphs += 1 } }
        while !stoppedPrompt.isWaiting { await Task.yield() }
        coordinator.invalidate()
        stoppedPrompt.allow()
        expect(await cancelled(stopped), "stop cancels a start waiting for permission")
        expect(graphs == 0, "permission completing after stop cannot start audio")

        let olderPrompt = PermissionPrompt()
        let older = Task { try await coordinator.start(after: olderPrompt.wait) { graphs += 100 } }
        while !olderPrompt.isWaiting { await Task.yield() }
        do { try await coordinator.start(after: {}) { graphs += 1 } } catch { failures += 1 }
        olderPrompt.allow()
        expect(await cancelled(older), "a newer device request supersedes an older pending start")
        expect(graphs == 1, "only the current device graph is configured")

        let cancelledPrompt = PermissionPrompt()
        let abandoned = Task { try await coordinator.start(after: cancelledPrompt.wait) { graphs += 100 } }
        while !cancelledPrompt.isWaiting { await Task.yield() }
        abandoned.cancel()
        cancelledPrompt.allow()
        expect(await cancelled(abandoned), "task cancellation prevents graph configuration")
        expect(graphs == 1, "cancelled UI task does not start capture")

        do {
            try await coordinator.start(after: { throw TestError.denied }) { graphs += 100 }
            failures += 1
        } catch TestError.denied {} catch { failures += 1 }
        do { try await coordinator.start(after: {}) { graphs += 1 } } catch { failures += 1 }
        expect(graphs == 2, "a later start succeeds after permission failure")
        print("Capture lifecycle: \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
