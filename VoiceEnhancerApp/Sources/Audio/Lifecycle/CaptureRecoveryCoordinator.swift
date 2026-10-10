import Foundation

/// Owns capture intent, debouncing and bounded recovery. Graph configuration
/// stays with the caller; only the latest request may publish a result.
@MainActor
public final class CaptureRecoveryCoordinator {
    public enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var wantsCapture = false
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private let beginCapture: () async throws -> Void
    private let endCapture: () -> Void
    private let publish: (State) -> Void
    private let wait: (UInt64) async throws -> Void
    private let retryDelays: [UInt64]

    public init(retryDelays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000],
                wait: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
                start: @escaping () async throws -> Void,
                stop: @escaping () -> Void,
                publish: @escaping (State) -> Void) {
        self.retryDelays = retryDelays
        self.wait = wait
        self.beginCapture = start
        self.endCapture = stop
        self.publish = publish
    }

    public func start() async {
        if wantsCapture && (task != nil || state == .running) { return }
        wantsCapture = true
        schedule(delay: 0)
        let pending = task
        await pending?.value
    }

    public func stop() {
        wantsCapture = false
        invalidate()
        endCapture()
        setState(.idle)
    }

    /// Device/configuration events never restart an intentionally stopped app.
    /// Intent remains set after exhausted retries, allowing a later plug-in or
    /// input selection event to recover without losing the persisted UID.
    public func requestRestart(delay: UInt64 = 250_000_000) {
        guard wantsCapture else { return }
        schedule(delay: delay)
    }

    public func retry() async {
        wantsCapture = true
        schedule(delay: 0)
        let pending = task
        await pending?.value
    }

    private func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    private func schedule(delay: UInt64) {
        invalidate()
        let request = generation
        endCapture() // also invalidates permission requests in MicCapture
        setState(.starting)
        task = Task { [weak self] in
            await self?.run(request: request, delay: delay)
        }
    }

    private func isCurrent(_ request: UInt64) -> Bool {
        request == generation && wantsCapture && !Task.isCancelled
    }

    private func run(request: UInt64, delay: UInt64) async {
        if delay > 0 {
            do { try await wait(delay) } catch { return }
        }
        for attempt in 0...retryDelays.count {
            guard isCurrent(request) else { return }
            do {
                try await beginCapture()
                guard isCurrent(request) else { return }
                task = nil
                setState(.running)
                return
            } catch {
                guard isCurrent(request) else { return }
                endCapture()
                if attempt == retryDelays.count {
                    task = nil
                    setState(.failed(error.localizedDescription))
                    return
                }
                do { try await wait(retryDelays[attempt]) } catch { return }
            }
        }
    }

    private func setState(_ value: State) {
        state = value
        publish(value)
    }
}
