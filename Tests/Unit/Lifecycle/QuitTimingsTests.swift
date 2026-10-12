import XCTest

@testable import WallpaperMachine

/// A scripted clock stands in for real time, so every duration is exact and no test sleeps.
@MainActor
final class QuitTimingsTests: XCTestCase {
    private final class ScriptedClock {
        private let base = ContinuousClock.now
        private var elapsed = Duration.zero
        var instant: ContinuousClock.Instant { base.advanced(by: elapsed) }
        func pass(_ amount: Duration) { elapsed += amount }
    }

    private struct Refused: Error {}

    private let clock = ScriptedClock()
    private var lines: [String] = []

    private func makeTimings() -> QuitTimings {
        QuitTimings(now: { [clock] in clock.instant }, log: { [unowned self] in self.lines.append($0) })
    }

    func testEachStageKeepsItsOwnDurationInTheOrderItFinished() async {
        let timings = makeTimings()

        await timings.measure("restore") { clock.pass(.milliseconds(1_250)) }
        await timings.measure("bridge") { clock.pass(.milliseconds(40)) }

        XCTAssertEqual(timings.stages, [
            .init(name: "restore", duration: .milliseconds(1_250), failed: false),
            .init(name: "bridge", duration: .milliseconds(40), failed: false),
        ])
    }

    func testAStageHandsBackItsResult() async {
        let timings = makeTimings()

        let value = await timings.measure("count") { 42 }

        XCTAssertEqual(value, 42)
    }

    func testAStageThatThrowsIsStillTimedAndTheErrorStillReachesTheCaller() async {
        let timings = makeTimings()
        var caught: Error?

        do {
            try await timings.measure("restore") {
                clock.pass(.milliseconds(5_003))
                throw Refused()
            }
        } catch {
            caught = error
        }

        XCTAssertTrue(caught is Refused)
        XCTAssertEqual(timings.stages, [.init(name: "restore", duration: .milliseconds(5_003), failed: true)])
    }

    func testTheWholeQuitIsTimedFromTheStartNotAsTheSumOfItsStages() async {
        let timings = makeTimings()
        clock.pass(.milliseconds(10))
        await timings.measure("imports") { clock.pass(.milliseconds(30)) }
        clock.pass(.milliseconds(5))
        await timings.measure("bridge") { clock.pass(.milliseconds(20)) }

        timings.finish("finished")

        let summary = lines.last ?? ""
        XCTAssertTrue(summary.contains("65 ms"), "10 + 30 + 5 + 20: \(summary)")
        XCTAssertTrue(summary.contains("imports") && summary.contains("bridge"),
                      "the summary names every stage that ran")
    }

    func testEveryStageAndTheSummaryAreLoggedOnce() async {
        let timings = makeTimings()
        await timings.measure("a") {}
        await timings.measure("b") {}
        timings.finish("finished")

        XCTAssertEqual(lines.count, 3)
    }

    func testAQuitWithNoStagesStillSummarises() {
        let timings = makeTimings()
        clock.pass(.milliseconds(7))

        timings.finish("cancelled")

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("7 ms"))
    }

    func testDurationsAreWholeMilliseconds() {
        XCTAssertEqual(Duration.zero.wholeMilliseconds, 0)
        XCTAssertEqual(Duration.milliseconds(1_999).wholeMilliseconds, 1_999)
        XCTAssertEqual(Duration.seconds(3).wholeMilliseconds, 3_000)
        XCTAssertEqual(Duration.microseconds(1_900).wholeMilliseconds, 1, "a fraction of a millisecond is dropped")
    }
}
