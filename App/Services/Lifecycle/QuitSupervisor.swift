import Foundation

/// Runs the stages of a quit, each against a deadline.
///
/// Before this, a stage that never returned left the app half quit: the control panel
/// was already hidden and the activation policy already `.accessory`, so the app was
/// invisible, a second Exit was refused without a word, and nothing in the log said
/// which stage was stuck. Now restoration of the desktop gets one budget and the rest
/// of the teardown shares another; a stage that outlives its time is named, logged and
/// left behind.
///
/// Stages are raced rather than run under a task group, because a group waits for its
/// slowest child and a stage that is stuck never returns. Each stage runs in a task of
/// its own and a timer runs beside it; whichever settles first decides, and the other
/// is cancelled but never awaited. A stage that finishes after its deadline finds the
/// race already decided and changes nothing.
///
/// What a refused or cut-short quit does to the rest of the app (the alert, the panel,
/// the menu, the exit fuse) belongs to `AppDelegate`; this type only decides and logs.
@MainActor
final class QuitSupervisor {
    /// How long each part of a quit may take.
    struct Budgets: Equatable, Sendable {
        /// Putting the user's own desktop picture back. Its own retries take about five
        /// seconds; the rest is for the lock-screen service that restores first.
        var restoration: Duration
        /// All the stages after restoration together.
        var teardown: Duration
        /// How long the process may take to exit once the quit has finished.
        var exitFuse: Duration
        /// The same, when a stage was left running: the renderer's threads are still alive
        /// and a slow exit would run C++ static destructors under them.
        var stalledExitFuse: Duration
        /// The least the last stage is given, even when earlier ones used the budget up:
        /// it is the renderer's shutdown, which closes the scenes and the log. It closes the
        /// load journal the moment it starts, so that does not depend on this time.
        var lastStageFloor: Duration

        /// Chosen generously. The stage durations every quit logs are what to tune them from.
        static let interactive = Budgets(
            restoration: .seconds(20), teardown: .seconds(10), exitFuse: .seconds(5),
            stalledExitFuse: .seconds(1), lastStageFloor: .seconds(2))

        func exitFuse(stalled: [String]) -> Duration {
            stalled.isEmpty ? exitFuse : stalledExitFuse
        }
    }

    struct Stage {
        let name: String
        let run: @MainActor () async throws -> Void
    }

    /// Why the quit was called off.
    enum Cancellation: Equatable, Sendable {
        /// Restoration threw; the text is the error's own.
        case restorationFailed(String)
        case restorationTimedOut
    }

    enum Outcome: Equatable {
        /// Restoration is done and the app may exit. `stalled` names the stages that were
        /// left behind, in order.
        case proceed(stalled: [String])
        /// The desktop could not be restored in time, so the app keeps running.
        case cancel(Cancellation)
    }

    /// Every stage and the whole quit are logged through this.
    let timings: QuitTimings
    let budgets: Budgets
    private let now: () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        budgets: Budgets = .interactive,
        now: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: @escaping (String) -> Void = { AppLog.info($0) }
    ) {
        self.budgets = budgets
        self.now = now
        self.sleep = sleep
        timings = QuitTimings(now: now, log: log)
    }

    /// Runs `restoration`, and only if it succeeds in time, the `teardown` stages in order.
    ///
    /// A teardown stage that throws is logged and the quit goes on without it: nothing
    /// after restoration is worth keeping the app alive for. A stage that outlives the
    /// time it has left is named in `stalled` and the stages after it still run.
    func run(restoration: Stage, teardown: [Stage]) async -> Outcome {
        let restoreStart = now()
        switch await race(restoration, allowance: budgets.restoration) {
        case .finished:
            timings.record(restoration.name, since: restoreStart)
        case .threw(let error):
            timings.record(restoration.name, since: restoreStart, failed: true, detail: error.localizedDescription)
            timings.finish("cancelled")
            return .cancel(.restorationFailed(error.localizedDescription))
        case .deadline:
            timings.recordStalled(restoration.name, since: restoreStart)
            timings.finish("cancelled")
            return .cancel(.restorationTimedOut)
        }

        let deadline = now().advanced(by: budgets.teardown)
        var stalled: [String] = []
        for (index, stage) in teardown.enumerated() {
            var allowance = max(.zero, now().duration(to: deadline))
            if index == teardown.count - 1 { allowance = max(allowance, budgets.lastStageFloor) }
            let start = now()
            guard allowance > .zero else {
                // No time is left, but the stage still has to start: it may be what
                // stops a child process. It simply is not waited for.
                _ = Task { @MainActor in try? await stage.run() }
                timings.recordStalled(stage.name, since: start)
                stalled.append(stage.name)
                continue
            }
            switch await race(stage, allowance: allowance) {
            case .finished:
                timings.record(stage.name, since: start)
            case .threw(let error):
                timings.record(stage.name, since: start, failed: true, detail: error.localizedDescription)
            case .deadline:
                timings.recordStalled(stage.name, since: start)
                stalled.append(stage.name)
            }
        }
        timings.finish(stalled.isEmpty ? "finished" : "finished without " + stalled.joined(separator: ", "))
        return .proceed(stalled: stalled)
    }

    private enum Result: Sendable {
        case finished
        case threw(any Error)
        case deadline
    }

    private func race(_ stage: Stage, allowance: Duration) async -> Result {
        let gate = FirstResult<Result>()
        let sleep = sleep
        let work = Task { @MainActor in
            do {
                try await stage.run()
                gate.offer(.finished)
            } catch {
                gate.offer(.threw(error))
            }
        }
        // Detached, so the timer does not wait for the main actor the stage may be holding.
        let timer = Task.detached {
            do { try await sleep(allowance) } catch { return }
            gate.offer(.deadline)
        }
        let result = await gate.wait()
        if case .deadline = result { work.cancel() } else { timer.cancel() }
        return result
    }
}

/// Keeps the first value offered and hands it to whoever waits, once.
///
/// A second offer is refused, which is what stops a stage that finishes after its
/// deadline from resuming the quit a second time.
final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?
    private var resumed = 0

    /// How many times the waiter was resumed: one, however many offers came.
    var resumeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    /// Returns whether this offer was the one kept.
    @discardableResult
    func offer(_ candidate: Value) -> Bool {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return false
        }
        value = candidate
        let pending = waiter
        waiter = nil
        if pending != nil { resumed += 1 }
        lock.unlock()
        pending?.resume(returning: candidate)
        return true
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                resumed += 1
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Ends the process if it is still there a while after the quit finished.
///
/// A normal exit runs the C++ static destructors of the renderer and waits for the
/// threads it left, and either can hang with the app invisible and logout waiting for it.
/// The fuse runs on a thread of its own, so a blocked main thread does not stop it.
enum ExitFuse {
    /// Calls `fire` on a new thread after `delay`. Nothing disarms it: a process that
    /// exits in time simply takes the thread with it.
    static func arm(after delay: Duration, fire: @escaping @Sendable () -> Void) {
        let thread = Thread {
            Thread.sleep(forTimeInterval: delay.timeInterval)
            fire()
        }
        thread.name = "app.wallpapermachine.exit-fuse"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

/// Why a quit was refused, worded for the alert and the menu line.
struct QuitFailure: LocalizedError {
    let cancellation: QuitSupervisor.Cancellation

    init(_ cancellation: QuitSupervisor.Cancellation) {
        self.cancellation = cancellation
    }

    var errorDescription: String? {
        switch cancellation {
        case .restorationFailed(let text):
            text
        case .restorationTimedOut:
            String(localized: "WallpaperMachine did not quit because restoring the desktop picture took too long. The app is still running; quit again to retry.")
        }
    }
}
