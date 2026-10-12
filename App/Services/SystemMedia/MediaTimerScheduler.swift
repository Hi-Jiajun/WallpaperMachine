import Foundation

/// A cancellable piece of scheduled work.
@MainActor
protocol MediaTimerToken: AnyObject {
    func cancel()
}

/// Delayed and repeating work, injected so tests drive time rather than wait on it.
@MainActor
protocol MediaTimerScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken
    func schedule(every seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken
}

/// Run-loop timers for the probe timeout and the once-a-second timeline push.
@MainActor
final class FoundationMediaTimerScheduler: MediaTimerScheduling {
    @MainActor
    private final class Token: MediaTimerToken {
        private var timer: Timer?

        init(_ timer: Timer) { self.timer = timer }

        func cancel() {
            timer?.invalidate()
            timer = nil
        }
    }

    func schedule(after seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken {
        make(interval: seconds, repeats: false, handler: handler)
    }

    func schedule(every seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken {
        make(interval: seconds, repeats: true, handler: handler)
    }

    private func make(
        interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void
    ) -> any MediaTimerToken {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { handler() }
        }
        // A timeline second may slide; letting the run loop coalesce it costs the page
        // nothing and keeps the app off a wake-up schedule of its own.
        timer.tolerance = interval / 4
        return Token(timer)
    }
}
