import CaptureLifecycle
import AVFoundation
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

@MainActor
final class PermissionResultPrompt {
    private var waiting: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool {
        await withCheckedContinuation { waiting = $0 }
    }
    func resolve(_ granted: Bool) { waiting?.resume(returning: granted); waiting = nil }
    var isWaiting: Bool { waiting != nil }
}

@main
struct CaptureLifecycleTests {
    @MainActor
    static func main() async {
        let coordinator = CaptureStartCoordinator()
        var graphs = 0
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
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

        for status in [AVAuthorizationStatus.authorized, .denied, .restricted, .notDetermined] {
            expect(CapturePermissionRequest.needsForeground(for: status) == (status == .notDetermined),
                   "only undetermined permission requires foreground presentation: \(status.rawValue)")
        }

        for status in [AVAuthorizationStatus.authorized, .denied, .restricted] {
            var events: [String] = []
            let granted = await CapturePermissionRequest.request(
                authorizationStatus: status,
                presentApplication: { events.append("foreground") },
                requestAccess: { events.append("request"); return true }
            )
            expect(granted == (status == .authorized), "known permission returns its existing result: \(status.rawValue)")
            expect(events.isEmpty, "known permission neither presents nor requests access: \(status.rawValue)")
        }

        for decision in [true, false] {
            var events: [String] = []
            let granted = await CapturePermissionRequest.request(
                authorizationStatus: .notDetermined,
                presentApplication: { events.append("foreground") },
                requestAccess: { events.append("request"); return decision }
            )
            expect(events == ["foreground", "request"], "foreground occurs once before the permission request")
            expect(granted == decision, "undetermined permission returns the requested decision: \(decision)")
        }

        let pendingDecision = PermissionResultPrompt()
        var pendingEvents: [String] = []
        let pendingRequest = Task {
            await CapturePermissionRequest.request(
                authorizationStatus: .notDetermined,
                presentApplication: { pendingEvents.append("foreground") },
                requestAccess: { pendingEvents.append("request"); return await pendingDecision.wait() }
            )
        }
        while !pendingDecision.isWaiting { await Task.yield() }
        expect(pendingEvents == ["foreground", "request"], "application is already foregrounded while permission is pending")
        pendingDecision.resolve(false)
        expect(await pendingRequest.value == false, "a pending denied prompt returns false")

        let stoppedDecision = PermissionResultPrompt()
        var stoppedEvents: [String] = []
        let stoppedPermissionFlow = Task {
            try await coordinator.start(after: {
                let granted = await CapturePermissionRequest.request(
                    authorizationStatus: .notDetermined,
                    presentApplication: { stoppedEvents.append("foreground") },
                    requestAccess: { stoppedEvents.append("request"); return await stoppedDecision.wait() }
                )
                if !granted { throw TestError.denied }
            }) { graphs += 100 }
        }
        while !stoppedDecision.isWaiting { await Task.yield() }
        expect(stoppedEvents == ["foreground", "request"], "capture permission flow presents before awaiting access")
        coordinator.invalidate()
        stoppedDecision.resolve(true)
        expect(await cancelled(stoppedPermissionFlow), "stop invalidates capture while the presented permission prompt is pending")
        expect(graphs == 2, "permission granted after stop cannot configure the capture graph")

        print("Capture lifecycle: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
