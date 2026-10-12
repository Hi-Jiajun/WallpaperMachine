import XCTest
@testable import WallpaperMachine

@MainActor
final class PlaylistSchedulerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: PlaylistStore!
    private var collections: WallpaperCollectionStore!
    private var shown: [String: String] = [:]
    private var running = true
    private var clock = Date()
    private var applied: [String] = []
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        store = PlaylistStore(defaults: defaults)
        collections = WallpaperCollectionStore(defaults: defaults)
        shown = ["primary": "a"]
        running = true
        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12))!
        applied = []
    }

    override func tearDown() {
        defaults = nil
        store = nil
        collections = nil
        super.tearDown()
    }

    private func makeScheduler(
        library: [String] = ["a", "b", "c"], favorites: Set<String> = [],
        commandRevision: @escaping @MainActor (String) -> UInt64 = { _ in 0 },
        activate: PlaylistScheduler.Activate? = nil
    ) -> PlaylistScheduler {
        PlaylistScheduler(
            store: store, collections: collections, displays: { ["primary"] }, library: { library }, favorites: { favorites },
            current: { self.shown[$0] }, isRunning: { _ in self.running },
            activate: activate ?? { display, choose in
                guard let id = choose() else { return nil }
                self.shown[display] = id
                self.applied.append(id)
                return id
            },
            commandRevision: commandRevision, now: { self.clock }, calendar: calendar, center: .default,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    }

    /// Lets the switch a scheduler started on the main actor run to its end.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func testFailedWallpaperIsSkippedImmediatelyAndRetriedAfterCooldown() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        var attempts: [String] = []
        var broken = true
        let scheduler = makeScheduler(activate: { display, choose in
            guard let id = choose() else { return nil }
            attempts.append(id)
            if id == "b", broken { throw WallpaperActionError(message: "Fixture failed") }
            self.shown[display] = id
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(attempts, ["b", "c"])
        XCTAssertEqual(shown["primary"], "c")
        XCTAssertNotNil(store.skipped["primary"]?["b"])
        shown["primary"] = "a"
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts, ["b", "c", "c"], "a failed item is not immediately retried")
        clock.addTimeInterval(PlaylistScheduler.failureCooldown)
        shown["primary"] = "a"
        broken = false
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts.last, "b")
        XCTAssertEqual(shown["primary"], "b")
        XCTAssertNil(store.skipped["primary"]?["b"])
    }

    func testBrokenLibraryHasBoundedAttemptsAndKeepsTheCurrentWallpaper() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        var attempts: [String] = []
        let scheduler = makeScheduler(library: ["a"] + (1...20).map { "broken-\($0)" }, activate: { _, choose in
            guard let id = choose() else { return nil }
            attempts.append(id)
            throw WallpaperActionError(message: "Fixture failed")
        })
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts.count, PlaylistScheduler.maximumAttempts)
        XCTAssertEqual(Set(attempts).count, attempts.count)
        XCTAssertEqual(shown["primary"], "a")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(5 * 60))
    }

    func testCancellationDoesNotBlacklistOrTryAnotherWallpaper() async {
        store.update("primary") { $0.mode = .rotate }
        var attempts: [String] = []
        let scheduler = makeScheduler(activate: { _, choose in
            guard let id = choose() else { return nil }
            attempts.append(id)
            throw CancellationError()
        })
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts, ["b"])
        XCTAssertTrue(store.skipped.isEmpty)
    }

    func testFailedAutomaticSwitchYieldsToANewerManualCommand() async throws {
        store.update("primary") { $0.mode = .rotate }
        let queue = UserCommandQueue()
        let slot = BridgeStore.activationSlot(displayId: "primary")
        var release: CheckedContinuation<Void, Never>?
        var attempts: [String] = []
        let scheduler = makeScheduler(commandRevision: { _ in queue.revision(for: slot) }, activate: { _, choose in
            try await queue.run(slot: slot) {
                guard let id = choose() else { return }
                attempts.append(id)
                await withCheckedContinuation { release = $0 }
                throw WallpaperActionError(message: "Fixture failed")
            }
            return nil
        })
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.skip("primary")
        await settle()
        let continuation = try XCTUnwrap(release)
        let manual = Task {
            await queue.run(slot: slot) { self.shown["primary"] = "manual" }
        }
        await settle()
        XCTAssertTrue(queue.hasWaiting(slot: slot))
        continuation.resume()
        await manual.value
        await settle()
        XCTAssertEqual(attempts, ["b"], "an automatic retry must not supersede the manual switch")
        XCTAssertEqual(shown["primary"], "manual")
    }

    func testChangingPlaylistDuringFailureDoesNotContinueTheOldRotation() async {
        store.update("primary") { $0.mode = .rotate }
        var attempts: [String] = []
        let scheduler = makeScheduler(activate: { _, choose in
            guard let id = choose() else { return nil }
            attempts.append(id)
            self.store.update("primary") { $0.mode = .off }
            throw WallpaperActionError(message: "Fixture failed")
        })
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts, ["b"])
        XCTAssertEqual(shown["primary"], "a")
        XCTAssertNil(store.nextChange["primary"])
    }

    func testRotationWaitsItsIntervalThenAdvancesInOrder() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.interval = 30
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertTrue(applied.isEmpty, "turning rotation on does not change the wallpaper at once")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))

        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))
    }

    func testAChangeThatFellDueWhilePausedHappensOnceOnResume() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.interval = 5
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        clock.addTimeInterval(3 * 60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "nothing changes while wallpapers are paused or hidden")

        running = true
        scheduler.evaluate()
        await settle()
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "missed intervals are not caught up one by one")
    }

    func testDayAndNightFollowTheClockButLeaveAManualChoiceAlone() async {
        store.update("primary") {
            $0.mode = .dayNight
            $0.dayWallpaperID = "b"
            $0.nightWallpaperID = "c"
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(applied, ["b"], "at noon the day wallpaper takes over")
        XCTAssertEqual(store.nextChange["primary"], calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 19)))

        shown["primary"] = "a"
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "a wallpaper applied by hand stays until the next half of the day")

        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 20))!
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "c"])
        XCTAssertEqual(store.nextChange["primary"], calendar.date(from: DateComponents(year: 2027, month: 1, day: 16, hour: 7)))
    }

    func testChoosingADifferentDayWallpaperAppliesAtOnce() async {
        store.update("primary") {
            $0.mode = .dayNight
            $0.dayWallpaperID = "b"
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        store.update("primary") { $0.dayWallpaperID = "c" }
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "c"])
    }

    func testSkipChangesARotatingDisplayNowAndRestartsItsInterval() async {
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        XCTAssertFalse(scheduler.skip("primary"), "a display without a rotation leaves Next to the library order")

        store.update("primary") {
            $0.mode = .rotate
            $0.source = .list
            $0.wallpaperIDs = ["c", "a"]
            $0.interval = 60
        }
        XCTAssertTrue(scheduler.canSkip("primary"))
        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(applied, ["c"])
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(60 * 60))
        store.update("primary") { $0.wallpaperIDs = ["c"] }
        XCTAssertFalse(scheduler.canSkip("primary"), "the only wallpaper on the list is already showing")
        XCTAssertFalse(scheduler.skip("primary"), "with nothing else to change to, Next must not report success")
        await settle()
        XCTAssertEqual(applied, ["c"])
    }

    /// Change now and Next Wallpaper are asked for, so they move a paused or covered display
    /// along at once, while a change that falls due on its own still waits for it to play.
    func testRequestedSkipChangesAPausedDisplayButItsTimerWaits() async {
        running = false
        store.update("primary") {
            $0.mode = .rotate
            $0.source = .list
            $0.wallpaperIDs = ["a", "b", "c"]
            $0.interval = 30
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(applied, ["b"])
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))

        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "the timer's own change waits while the display is paused")
    }

    /// Change now asked for while the timer's own change still waits its turn, with the display
    /// paused meanwhile, is not lost: that change runs as asked for.
    func testRequestedSkipDuringATimerChangeStillMovesAPausedDisplay() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.source = .list
            $0.wallpaperIDs = ["a", "b", "c"]
            $0.interval = 30
        }
        var release: CheckedContinuation<Void, Never>?
        let scheduler = makeScheduler(activate: { display, choose in
            await withCheckedContinuation { release = $0 }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertNotNil(release, "the timer's change is waiting its turn")
        running = false
        XCTAssertTrue(scheduler.skip("primary"))
        release?.resume()
        await settle()
        XCTAssertEqual(applied, ["b"])
    }

    /// When the playlist changes while the timer's change waits its turn, that change is dropped
    /// as stale; Change now asked for meanwhile is then made on its own, paused display or not.
    func testRequestedSkipBehindAStaleTimerChangeIsMadeOnItsOwn() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.source = .list
            $0.wallpaperIDs = ["a", "b", "c"]
            $0.interval = 30
        }
        var release: CheckedContinuation<Void, Never>?
        var holdsFirst = true
        let scheduler = makeScheduler(activate: { display, choose in
            if holdsFirst {
                holdsFirst = false
                await withCheckedContinuation { release = $0 }
            }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertNotNil(release, "the timer's change is waiting its turn")
        store.update("primary") { $0.wallpaperIDs = ["a", "c"] }
        running = false
        XCTAssertTrue(scheduler.skip("primary"))
        release?.resume()
        await settle()
        XCTAssertEqual(applied, ["c"], "the stale change is dropped and the asked-for one is made")
    }

    func testNothingPlayableLeavesTheDisplayAsItIs() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.source = .favorites
        }
        let scheduler = makeScheduler(favorites: ["gone"])
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60), "it tries again an interval later")
    }

    func testApplyingPlanWhilePausedWaitsThenRotatesOnceUsingLiveCollection() async throws {
        let collection = try collections.create(name: "Live", wallpaperIDs: ["a", "gone", "b"])
        store.update("source") { $0.mode = .rotate; $0.source = .collection; $0.collectionID = collection.id }
        let plan = try store.savePlan(from: "source", name: "Collection rotation")
        running = false
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(plan.id, to: "primary")
        await settle()
        XCTAssertEqual(applied, [])
        try collections.remove(["b"], from: collection.id)
        try collections.add(["c"], to: collection.id)
        running = true
        scheduler.evaluate()
        await settle()
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["c"], "membership is resolved when the display actually resumes")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))
    }

    func testReapplyingDayNightPlanSettlesOnceButDeletingPlanKeepsManualOverride() async throws {
        store.update("source") { $0.mode = .dayNight; $0.dayWallpaperID = "b"; $0.nightWallpaperID = "c" }
        let plan = try store.savePlan(from: "source", name: "Day and night")
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(plan.id, to: "primary")
        await settle()
        shown["primary"] = "a"
        try store.applyPlan(plan.id, to: "primary")
        await settle()
        XCTAssertEqual(applied, ["b", "b"], "explicit reactivation reconciles the current phase")
        shown["primary"] = "a"
        try store.deletePlan(plan.id)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "b"], "deleting metadata must not override a manual wallpaper")
    }

    func testQueuedPlanReplacementCannotApplyOldPlanOrOverwriteNewDeadline() async throws {
        store.update("source") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
        let oldPlan = try store.savePlan(from: "source", name: "Old")
        store.update("source") { $0.wallpaperIDs = ["a", "c"]; $0.interval = 60 }
        let newPlan = try store.savePlan(from: "source", name: "New")
        var resume: CheckedContinuation<Void, Never>?
        var first = true
        let scheduler = makeScheduler(activate: { display, choose in
            if first {
                first = false
                await withCheckedContinuation { resume = $0 }
            }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(oldPlan.id, to: "primary")
        await settle()
        let gate = try XCTUnwrap(resume)
        try store.applyPlan(newPlan.id, to: "primary")
        gate.resume()
        await settle()
        XCTAssertEqual(applied, ["c"])
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(60 * 60))
    }

    func testPauseAfterEnqueuePreservesDuePlanUntilResume() async throws {
        store.update("source") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
        let plan = try store.savePlan(from: "source", name: "Rotation")
        var resume: CheckedContinuation<Void, Never>?
        var first = true
        let scheduler = makeScheduler(activate: { display, choose in
            if first {
                first = false
                await withCheckedContinuation { resume = $0 }
            }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(plan.id, to: "primary")
        await settle()
        let gate = try XCTUnwrap(resume)
        running = false
        gate.resume()
        await settle()
        XCTAssertEqual(applied, [])
        XCTAssertEqual(store.nextChange["primary"], .distantPast)
        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])
    }
    func testPlanActivationOnOneDisplayDoesNotLiftAnotherDisplaysPause() async throws {
        shown["second"] = "a"
        running = false
        store.update("source") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
        let plan = try store.savePlan(from: "source", name: "Shared configuration")
        let scheduler = PlaylistScheduler(
            store: store, collections: collections, displays: { ["primary", "second"] },
            library: { ["a", "b"] }, favorites: { [] }, current: { self.shown[$0] },
            isRunning: { $0 == "primary" || self.running },
            activate: { display, choose in
                guard let id = choose() else { return nil }
                self.shown[display] = id
                self.applied.append(display)
                return id
            },
            now: { self.clock }, center: .default,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(plan.id, to: "primary")
        try store.applyPlan(plan.id, to: "second")
        await settle()
        XCTAssertEqual(applied, ["primary"])
        XCTAssertEqual(shown["second"], "a")
        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["primary", "second"])
        XCTAssertEqual(shown["second"], "b")
    }
}
