import CaptureLifecycle
import Foundation
import AppKit

@MainActor
final class TestClock {
    var pending: [CheckedContinuation<Void, Error>] = []
    var delays: [UInt64] = []
    func wait(_ delay: UInt64) async throws {
        delays.append(delay)
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    // Deliberately resume cancelled waits too, testing generation checks even
    // when the underlying operation does not cooperate with task cancellation.
    func advance() {
        let ready = pending
        pending.removeAll()
        for continuation in ready { continuation.resume() }
    }
}

enum TestError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Input unavailable" }
}

@MainActor
final class FakeCapture {
    var starts = 0, stops = 0, failuresRemaining = 0
    var selectedUID = "saved-usb-mic"
    var startedUIDs: [String] = []
    var hold = false
    var pending: [CheckedContinuation<Void, Never>] = []
    func start() async throws {
        starts += 1
        startedUIDs.append(selectedUID)
        if hold { await withCheckedContinuation { pending.append($0) } }
        if failuresRemaining > 0 { failuresRemaining -= 1; throw TestError.unavailable }
    }
    func stop() { stops += 1 }
    func release() {
        hold = false
        let ready = pending; pending.removeAll()
        for continuation in ready { continuation.resume() }
    }
}

@main
struct CaptureRecoveryTests {
    @MainActor
    static func main() async {
        var checks = 0, failures = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func eventually(_ condition: () -> Bool) async {
            for _ in 0..<10000 {
                if condition() { return }
                await Task.yield()
            }
            fatalError("Recovery test stalled")
        }
        func make(_ capture: FakeCapture, _ clock: TestClock,
                  publish: @escaping (CaptureRecoveryCoordinator.State) -> Void = { _ in }) -> CaptureRecoveryCoordinator {
            CaptureRecoveryCoordinator(retryDelays: [10, 20], wait: clock.wait,
                start: capture.start, stop: capture.stop, publish: publish)
        }

        let success = FakeCapture(), successClock = TestClock()
        var states: [CaptureRecoveryCoordinator.State] = []
        let first = make(success, successClock) { states.append($0) }
        await first.start()
        await first.start()
        expect(success.starts == 1, "repeated start does not create another graph")
        expect(states == [.starting, .running], "successful start publishes ordered state")
        first.stop()
        first.requestRestart()
        expect(first.state == .idle && !first.wantsCapture && success.starts == 1,
               "device events leave intentional stop alone")

        let flaky = FakeCapture(), retryClock = TestClock()
        flaky.failuresRemaining = 2
        let retry = make(flaky, retryClock)
        let retryTask = Task { await retry.start() }
        await eventually { retryClock.pending.count == 1 }
        expect(flaky.starts == 1 && retry.state == .starting, "failure waits before retry")
        retryClock.advance()
        await eventually { retryClock.pending.count == 1 }
        retryClock.advance()
        await retryTask.value
        expect(flaky.starts == 3 && retry.state == .running, "failed attempts recover within bounded retries")
        expect(retryClock.delays == [10, 20], "retry schedule follows configured backoff")
        expect(flaky.selectedUID == "saved-usb-mic", "recovery does not overwrite selected device identity")

        let broken = FakeCapture(), exhaustedClock = TestClock()
        broken.failuresRemaining = 99
        let exhausted = make(broken, exhaustedClock)
        let exhaustedTask = Task { await exhausted.start() }
        await eventually { exhaustedClock.pending.count == 1 }; exhaustedClock.advance()
        await eventually { exhaustedClock.pending.count == 1 }; exhaustedClock.advance()
        await exhaustedTask.value
        expect(broken.starts == 3 && exhausted.state == .failed("Input unavailable"), "retry exhaustion reports last error and stops retrying")
        expect(exhausted.wantsCapture, "intent survives temporary device unavailability")
        broken.failuresRemaining = 0
        exhausted.requestRestart(delay: 0)
        await eventually { exhausted.state == .running }
        expect(broken.starts == 4, "later device event recovers after exhausted retries")

        let burst = FakeCapture(), burstClock = TestClock()
        let coalesced = make(burst, burstClock)
        await coalesced.start()
        burst.selectedUID = "first-switch"
        coalesced.requestRestart(delay: 100)
        await eventually { !burstClock.pending.isEmpty }
        burst.selectedUID = "last-switch"
        coalesced.requestRestart(delay: 100)
        await eventually { burstClock.pending.count == 2 }
        burstClock.advance()
        await eventually { coalesced.state == .running }
        expect(burst.starts == 2 && burst.startedUIDs.last == "last-switch", "event burst starts only latest device request")
        coalesced.requestRestart(delay: 100)
        await eventually { !burstClock.pending.isEmpty }
        coalesced.stop(); burstClock.advance()
        for _ in 0..<20 { await Task.yield() }
        expect(burst.starts == 2 && coalesced.state == .idle, "stop cancels a pending debounced restart")

        let late = FakeCapture(), lateClock = TestClock()
        late.hold = true
        let stopped = make(late, lateClock)
        let lateTask = Task { await stopped.start() }
        await eventually { !late.pending.isEmpty }
        stopped.stop(); late.release()
        await lateTask.value
        expect(stopped.state == .idle, "late successful permission completion cannot publish running after stop")

        let superseded = FakeCapture(), supersededClock = TestClock()
        superseded.hold = true
        let latest = make(superseded, supersededClock)
        let oldTask = Task { await latest.start() }
        await eventually { superseded.pending.count == 1 }
        superseded.selectedUID = "new-device"
        latest.requestRestart(delay: 0)
        await eventually { superseded.pending.count == 2 }
        superseded.release()
        await oldTask.value
        await eventually { latest.state == .running }
        expect(superseded.starts == 2 && superseded.startedUIDs.last == "new-device", "superseded attempt cannot interfere with newest graph")

        let manual = FakeCapture(), manualClock = TestClock()
        let manualRetry = make(manual, manualClock)
        await manualRetry.retry()
        expect(manualRetry.state == .running && manualRetry.wantsCapture, "explicit retry can start capture from idle")
        manualRetry.stop()
        let wakeCapture = FakeCapture(), wakeClock = TestClock()
        let waking = make(wakeCapture, wakeClock)
        let center = NotificationCenter()
        var wakes = 0
        var monitor: CaptureWakeMonitor? = CaptureWakeMonitor(center: center) {
            wakes += 1
            waking.requestRestart(delay: 3_000_000_000)
        }
        weak var weakMonitor = monitor
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await eventually { wakes == 1 }
        expect(wakeClock.pending.isEmpty && wakeCapture.starts == 0, "wake preserves intentional stop")
        await waking.start()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await eventually { wakeClock.pending.count == 1 }
        expect(wakeClock.delays.last == 3_000_000_000, "wake waits for device stabilization")
        waking.requestRestart(delay: 250_000_000)
        await eventually { wakeClock.pending.count == 2 }
        wakeClock.advance()
        await eventually { waking.state == .running }
        expect(wakeCapture.starts == 2, "wake and device events coalesce into one recovery")
        monitor = nil
        expect(weakMonitor == nil, "wake observer owner is released")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        expect(wakes == 2, "released wake monitor removes observer")
        waking.stop()
        print("Capture recovery: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
