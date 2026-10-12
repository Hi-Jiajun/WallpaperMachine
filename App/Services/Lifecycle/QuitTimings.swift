import Foundation

/// Times the stages of a quit and logs each one, then one line for the whole quit.
///
/// A quit that is slow, or that is cut short by the system, cannot be diagnosed from
/// the line that says it started. The durations here are also what a time budget for
/// a stage has to be read from, so they are logged for every quit, not only slow ones.
@MainActor
final class QuitTimings {
    struct Stage: Equatable {
        let name: String
        let duration: Duration
        /// The stage threw, so the quit was refused or went on without it.
        let failed: Bool
    }

    /// Stages in the order they finished.
    private(set) var stages: [Stage] = []
    private let now: () -> ContinuousClock.Instant
    private let log: (String) -> Void
    private let began: ContinuousClock.Instant

    init(
        now: @escaping () -> ContinuousClock.Instant = { .now },
        log: @escaping (String) -> Void = { AppLog.info($0) }
    ) {
        self.now = now
        self.log = log
        began = now()
    }

    /// Runs one stage and logs how long it took, also when it throws.
    @discardableResult
    func measure<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let start = now()
        do {
            let value = try await body()
            record(name, since: start, failed: false)
            return value
        } catch {
            record(name, since: start, failed: true)
            throw error
        }
    }

    /// Logs the line for the whole quit: how it ended, how long it took since this
    /// object was made, and every stage that ran.
    func finish(_ outcome: String) {
        let stageText = stages.map { "\($0.name) \($0.duration.wholeMilliseconds) ms\($0.failed ? " (failed)" : "")" }
        let detail = stageText.isEmpty ? "" : ": " + stageText.joined(separator: ", ")
        log("quit: \(outcome) after \(began.duration(to: now()).wholeMilliseconds) ms\(detail)")
    }

    private func record(_ name: String, since start: ContinuousClock.Instant, failed: Bool) {
        let stage = Stage(name: name, duration: start.duration(to: now()), failed: failed)
        stages.append(stage)
        log("quit: stage \(name) took \(stage.duration.wholeMilliseconds) ms\(failed ? " and failed" : "")")
    }
}

extension Duration {
    var wholeMilliseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
