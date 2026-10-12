import Foundation

/// What a health check concluded, and what it was run for.
struct NativeVideoHealthEvent: Equatable {
    /// Why the check ran, for the log: "resumed after 2 h".
    let trigger: String
    let verdict: NativeVideoLiveness
}

/// The playing surface a supervisor looks at.
@MainActor
protocol NativeVideoHealthTarget: AnyObject {
    /// Whether looking at the pipeline now would tell anything: it is playing,
    /// and it has shown a picture before. A surface that has never shown one is
    /// the first-frame watch's business, and a paused or hidden one is not
    /// supposed to be producing anything.
    var isEligibleForCheck: Bool { get }
    /// One look at the pipeline, or `nil` when there is nothing to look at right
    /// now (no item between two loop copies).
    func liveSample() -> NativeVideoLivenessEvaluator.Sample?
    /// The check is over, whether it concluded or was abandoned. Whatever
    /// `liveSample` attached to the pipeline goes away here, so a surface that
    /// is not being checked is not paying for it.
    func finishSampling()
    func reportHealth(_ event: NativeVideoHealthEvent)
}

/// Looks at a surface's pipeline after something that could have cost it its
/// decoder, and reports whether pictures still come out.
///
/// A check settles first, because the system needs a moment to hand the
/// decoder back after a wake, and then samples at a fixed step until the
/// samples prove the pipeline works or the window ends. Healthy pipelines are
/// usually proven within a couple of samples, so the common cost of a check is
/// one short-lived video output. At most one check runs at a time: a newer
/// trigger replaces the one in flight, since what it describes is the state
/// the older check was about to judge.
@MainActor
final class NativeVideoHealthSupervisor {
    struct Policy: Equatable {
        /// How long a surface has to have been paused before resuming it is
        /// worth a check. A flick of the occlusion state is not.
        var minimumPause: Duration = .seconds(5)
        /// Wait between the trigger and the first sample.
        var settle: Duration = .milliseconds(500)
        /// How long the samples may go on without proving anything.
        var window: Duration = .seconds(2)
        /// Time between samples.
        var step: Duration = .milliseconds(100)

        /// How many samples fit the window: the bound on one check's work.
        var sampleLimit: Int {
            guard step > .zero else { return 1 }
            return max(1, Int(window / step))
        }
    }

    weak var target: (any NativeVideoHealthTarget)?
    private let policy: Policy
    private let sleep: @Sendable (Duration) async throws -> Void
    private var run: Task<Void, Never>?
    /// Moves whenever a run starts or is abandoned, so a run that was replaced
    /// can tell, whatever it was doing when it was.
    private var generation: UInt64 = 0

    init(
        policy: Policy = Policy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.policy = policy
        self.sleep = sleep
    }

    /// Starts a check for `trigger`, replacing one that is still running. A
    /// surface that cannot be judged right now is left alone.
    func schedule(trigger: String) {
        guard target?.isEligibleForCheck == true else { return }
        abandonRun()
        let mine = generation
        run = Task { @MainActor [weak self] in
            await self?.perform(trigger: trigger, generation: mine)
        }
    }

    /// Abandons the check in flight and reports nothing for it.
    func cancel() {
        abandonRun()
    }

    /// Waits for the check in flight to finish.
    func waitUntilIdleForTest() async {
        await run?.value
    }

    private func abandonRun() {
        generation &+= 1
        guard let run else { return }
        run.cancel()
        self.run = nil
        target?.finishSampling()
    }

    private func perform(trigger: String, generation mine: UInt64) async {
        let verdict = await observe(generation: mine)
        guard mine == generation else { return }
        run = nil
        target?.finishSampling()
        if let verdict {
            target?.reportHealth(NativeVideoHealthEvent(trigger: trigger, verdict: verdict))
        }
    }

    /// The verdict, or `nil` when the check stopped being meaningful: it was
    /// replaced, the surface paused or went away, or it was cancelled.
    private func observe(generation mine: UInt64) async -> NativeVideoLiveness? {
        do { try await sleep(policy.settle) } catch { return nil }
        var evaluator = NativeVideoLivenessEvaluator()
        let samples = policy.sampleLimit
        for index in 0..<samples {
            guard mine == generation, let target, target.isEligibleForCheck else { return nil }
            if let sample = target.liveSample() { evaluator.record(sample) }
            if let proven = evaluator.verdict { return proven }
            if index + 1 < samples {
                do { try await sleep(policy.step) } catch { return nil }
            }
        }
        guard mine == generation, target?.isEligibleForCheck == true else { return nil }
        return evaluator.timedOut()
    }
}
