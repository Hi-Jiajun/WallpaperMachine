import XCTest

@testable import WallpaperMachine

/// The rule that decides when a native video surface stops rebuilding itself
/// and gives the wallpaper up. Pure, so every case passes instants in rather
/// than waiting for them.
final class NativeVideoRecoveryBudgetTests: XCTestCase {
    private let origin = ContinuousClock.now

    private func at(_ seconds: Int) -> ContinuousClock.Instant {
        origin + .seconds(seconds)
    }

    func testTwoRebuildsAreAllowedInsideTheWindowAndTheThirdIsRefused() {
        var budget = NativeVideoRecoveryBudget()

        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertTrue(budget.permit(at: at(10)))
        XCTAssertFalse(budget.permit(at: at(20)), "a pipeline that keeps stalling is not rebuilt for ever")
        XCTAssertFalse(budget.permit(at: at(599)))
    }

    func testARefusalDoesNotSpendAnything() {
        var budget = NativeVideoRecoveryBudget()
        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertTrue(budget.permit(at: at(1)))
        XCTAssertFalse(budget.permit(at: at(2)))

        XCTAssertEqual(budget.spent, 2)
    }

    func testTheAllowanceComesBackAsOldRebuildsLeaveTheWindow() {
        var budget = NativeVideoRecoveryBudget()
        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertTrue(budget.permit(at: at(100)))
        XCTAssertFalse(budget.permit(at: at(599)))

        // The first one is ten minutes old now; the second still counts.
        XCTAssertTrue(budget.permit(at: at(600)))
        XCTAssertFalse(budget.permit(at: at(601)))
        XCTAssertTrue(budget.permit(at: at(700)), "the second left the window too")
    }

    func testAnUninterruptedStableRunForgivesTheHistory() {
        var budget = NativeVideoRecoveryBudget()
        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertTrue(budget.permit(at: at(5)))
        budget.healthy(at: at(10))

        // Sixty seconds of frames since 10, well inside the ten-minute window.
        XCTAssertTrue(budget.permit(at: at(70)))
        XCTAssertTrue(budget.permit(at: at(71)), "the earlier two no longer count")
        XCTAssertFalse(budget.permit(at: at(72)))
    }

    func testARunThatIsTooShortForgivesNothing() {
        var budget = NativeVideoRecoveryBudget()
        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertTrue(budget.permit(at: at(5)))
        budget.healthy(at: at(10))

        XCTAssertFalse(budget.permit(at: at(69)), "59 seconds is not a stable run")
    }

    func testARunIsMeasuredFromItsFirstFrameNotItsLatest() {
        var budget = NativeVideoRecoveryBudget()
        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertTrue(budget.permit(at: at(1)))
        budget.healthy(at: at(10))
        budget.healthy(at: at(65))
        budget.healthy(at: at(69))

        XCTAssertTrue(budget.permit(at: at(70)), "frames have been flowing since 10")
    }

    func testARebuildInterruptsTheRunItFollows() {
        var budget = NativeVideoRecoveryBudget()
        XCTAssertTrue(budget.permit(at: at(0)))
        budget.healthy(at: at(5))
        XCTAssertTrue(budget.permit(at: at(30)), "the second rebuild, inside the run")

        // No frame since the second rebuild, so nothing proves it held: the
        // frame at 5 belongs to a run that rebuild ended.
        XCTAssertFalse(budget.permit(at: at(200)))
    }

    func testARefusedRequestDoesNotInterruptTheRun() {
        // Nothing was rebuilt, so the frames that kept arriving still count.
        var budget = NativeVideoRecoveryBudget()
        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertTrue(budget.permit(at: at(1)))
        budget.healthy(at: at(10))
        XCTAssertFalse(budget.permit(at: at(20)))

        XCTAssertTrue(budget.permit(at: at(70)))
    }

    func testAFrameAfterTheRebuildStartsANewRun() {
        var budget = NativeVideoRecoveryBudget()
        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertTrue(budget.permit(at: at(30)))
        budget.healthy(at: at(35))

        XCTAssertTrue(budget.permit(at: at(95)))
    }

    func testResetRestoresTheFullAllowance() {
        var budget = NativeVideoRecoveryBudget()
        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertTrue(budget.permit(at: at(1)))
        XCTAssertFalse(budget.permit(at: at(2)))
        budget.healthy(at: at(3))

        budget.reset()

        XCTAssertEqual(budget.spent, 0)
        XCTAssertTrue(budget.permit(at: at(4)))
        XCTAssertTrue(budget.permit(at: at(5)))
        XCTAssertFalse(budget.permit(at: at(6)))
    }

    func testThePolicyIsWhatSetsTheLimits() {
        var budget = NativeVideoRecoveryBudget(
            policy: .init(maximum: 1, window: .seconds(10), stableRun: .seconds(5)))

        XCTAssertTrue(budget.permit(at: at(0)))
        XCTAssertFalse(budget.permit(at: at(9)))
        XCTAssertTrue(budget.permit(at: at(10)))
    }
}
