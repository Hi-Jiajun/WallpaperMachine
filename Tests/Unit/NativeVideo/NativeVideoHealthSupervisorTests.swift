import CoreMedia
import XCTest

@testable import WallpaperMachine

/// When a health check runs, how long it samples, and what it reports, against
/// a scripted target and a hand-fired clock. No player, no media, no real
/// waiting.
@MainActor
final class NativeVideoHealthSupervisorTests: XCTestCase {
    /// A short window keeps the drive loops small: settle, then five samples
    /// four steps apart.
    private let policy = NativeVideoHealthSupervisor.Policy(
        minimumPause: .seconds(5), settle: .milliseconds(500), window: .milliseconds(500),
        step: .milliseconds(100))

    private let sleeper = ManualSleeper()
    private let item = NSObject()

    @MainActor
    private final class FakeTarget: NativeVideoHealthTarget {
        var isEligibleForCheck = true
        /// What the pipeline looks like at each sample, by index.
        var look: (Int) -> NativeVideoLivenessEvaluator.Sample?
        private(set) var sampled = 0
        private(set) var finished = 0
        private(set) var events: [NativeVideoHealthEvent] = []

        init(look: @escaping (Int) -> NativeVideoLivenessEvaluator.Sample?) {
            self.look = look
        }

        func liveSample() -> NativeVideoLivenessEvaluator.Sample? {
            defer { sampled += 1 }
            return look(sampled)
        }
        func finishSampling() { finished += 1 }
        func reportHealth(_ event: NativeVideoHealthEvent) { events.append(event) }
    }

    private func sample(
        _ index: Int, advancing: Bool, frame: Bool, waiting: Bool = false
    ) -> NativeVideoLivenessEvaluator.Sample {
        NativeVideoLivenessEvaluator.Sample(
            time: CMTime(seconds: 10 + (advancing ? Double(index) * 0.1 : 0), preferredTimescale: 600),
            item: ObjectIdentifier(item), producedFrame: frame, waiting: waiting)
    }

    private func healthy() -> FakeTarget {
        FakeTarget { [unowned self] in sample($0, advancing: true, frame: true) }
    }

    /// The clock runs and no frame ever comes: a dead decoder.
    private func clockOnly() -> FakeTarget {
        FakeTarget { [unowned self] in sample($0, advancing: true, frame: false) }
    }

    private func makeSupervisor(_ target: FakeTarget) -> NativeVideoHealthSupervisor {
        let supervisor = NativeVideoHealthSupervisor(policy: policy, sleep: sleeper.closure)
        supervisor.target = target
        return supervisor
    }

    /// Lets the next timer the supervisor is waiting on run out.
    private func fireNext() async {
        await sleeper.waitUntilPending()
        sleeper.fireNext()
    }

    func testAHealthyPipelineIsReportedAndSamplingStopsAtTheProof() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // the settle
        await fireNext()  // the step after the first sample
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(
            target.events, [NativeVideoHealthEvent(trigger: "resumed after 2 h", verdict: .advancing)])
        XCTAssertEqual(target.sampled, 2, "one sample anchors the clock, the next proves it")
        XCTAssertEqual(sleeper.pendingCount, 0, "no further timer once it is proven")
        XCTAssertEqual(target.finished, 1, "what sampling attached is released")
    }

    func testADeadPipelineIsReportedStalledOnlyWhenTheWholeWindowHasBeenSampled() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // the settle
        for _ in 0..<(policy.sampleLimit - 1) {
            await fireNext()
            XCTAssertTrue(target.events.isEmpty, "a stall is concluded at the end of the window")
        }
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.sampled, policy.sampleLimit, "the window bounds the work")
        XCTAssertEqual(target.events.count, 1)
        XCTAssertEqual(target.events.first?.trigger, "resumed after 2 h")
        guard case .stalled = target.events.first?.verdict else {
            return XCTFail("\(String(describing: target.events.first))")
        }
        XCTAssertEqual(target.finished, 1)
        XCTAssertEqual(sleeper.pendingCount, 0)
    }

    func testTheDefaultWindowTakesAtMostTwentySamples() async {
        // The documented bound: two seconds in steps of a tenth.
        let target = clockOnly()
        let supervisor = NativeVideoHealthSupervisor(sleep: sleeper.closure)
        supervisor.target = target

        supervisor.schedule(trigger: "wake")
        await fireNext()
        for _ in 0..<19 { await fireNext() }
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.sampled, 20)
        XCTAssertEqual(target.events.count, 1)
        XCTAssertEqual(sleeper.pendingCount, 0, "and then it is over")
    }

    func testAPipelineThatWasWaitingForDataIsReportedWaitingNotStalled() async {
        let target = FakeTarget { [unowned self] in sample($0, advancing: false, frame: false, waiting: true) }
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 9 min")
        await fireNext()
        for _ in 0..<(policy.sampleLimit - 1) { await fireNext() }
        await supervisor.waitUntilIdleForTest()

        guard case .waiting = target.events.first?.verdict else {
            return XCTFail("a slow source is not a dead pipeline: \(target.events)")
        }
    }

    func testAWindowWithNothingToSampleIsReportedWaiting() async {
        let target = FakeTarget { _ in nil }
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 9 min")
        await fireNext()
        for _ in 0..<(policy.sampleLimit - 1) { await fireNext() }
        await supervisor.waitUntilIdleForTest()

        guard case .waiting = target.events.first?.verdict else {
            return XCTFail("\(target.events)")
        }
    }

    func testASurfaceThatCannotBeJudgedIsNotProbed() async {
        let target = healthy()
        target.isEligibleForCheck = false
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await supervisor.waitUntilIdleForTest()

        XCTAssertTrue(sleeper.requested.isEmpty, "not even the settle is waited for")
        XCTAssertEqual(target.sampled, 0)
        XCTAssertTrue(target.events.isEmpty)
        XCTAssertEqual(target.finished, 0)
    }

    func testASurfaceThatStopsBeingEligibleDuringTheSettleIsNeverSampled() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await sleeper.waitUntilPending()
        target.isEligibleForCheck = false  // the user paused during the settle
        sleeper.fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.sampled, 0)
        XCTAssertTrue(target.events.isEmpty)
        XCTAssertEqual(target.finished, 1)
    }

    func testAPauseMidRunStopsSamplingAndReportsNothing() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // settle
        await fireNext()  // first step
        await sleeper.waitUntilPending()  // the second sample is taken, waiting on the next step
        XCTAssertEqual(target.sampled, 2)
        target.isEligibleForCheck = false
        sleeper.fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.sampled, 2, "no sample after it stopped being meaningful")
        XCTAssertTrue(target.events.isEmpty, "a half-finished check says nothing")
        XCTAssertEqual(target.finished, 1)
        XCTAssertEqual(sleeper.pendingCount, 0)
    }

    func testCancellingAbandonsTheRunAndReleasesWhatItAttached() async {
        let target = clockOnly()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // settle
        await sleeper.waitUntilPending()  // sampling, waiting on the first step
        supervisor.cancel()
        XCTAssertEqual(target.finished, 1, "released at once, not when the run notices")
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(sleeper.cancelledCount, 1, "the step timer is cancelled")
        XCTAssertTrue(target.events.isEmpty)
        XCTAssertEqual(target.sampled, 1)
    }

    func testCancellingWithNothingRunningDoesNothing() {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.cancel()

        XCTAssertEqual(target.finished, 0)
    }

    func testTwoTriggersAreOneCheckForTheLatest() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await sleeper.waitUntilPending()
        supervisor.schedule(trigger: "woke from sleep")
        await fireNext()  // the second run's settle
        await fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(
            target.events, [NativeVideoHealthEvent(trigger: "woke from sleep", verdict: .advancing)],
            "the earlier trigger is absorbed, not reported on its own")
        XCTAssertEqual(sleeper.cancelledCount, 1, "its settle was cancelled")
    }

    func testATriggerDuringSamplingStartsTheCheckOverFromItsOwnSettle() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "resumed after 2 h")
        await fireNext()  // settle
        await sleeper.waitUntilPending()  // one sample taken, waiting on the step
        XCTAssertEqual(target.sampled, 1)
        supervisor.schedule(trigger: "woke from sleep")
        XCTAssertEqual(target.finished, 1, "the first check's output is released")
        await sleeper.waitUntilPending()
        XCTAssertEqual(
            sleeper.requested.last, policy.settle, "and the new check settles before it looks")
        XCTAssertEqual(target.sampled, 1, "nothing is sampled before the settle ends")
        await fireNext()
        await fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.events.map(\.trigger), ["woke from sleep"])
    }

    func testAnotherCheckCanFollowOnceOneHasFinished() async {
        let target = healthy()
        let supervisor = makeSupervisor(target)

        supervisor.schedule(trigger: "first")
        await fireNext()
        await fireNext()
        await supervisor.waitUntilIdleForTest()
        supervisor.schedule(trigger: "second")
        await fireNext()
        await fireNext()
        await supervisor.waitUntilIdleForTest()

        XCTAssertEqual(target.events.map(\.trigger), ["first", "second"])
    }
}
