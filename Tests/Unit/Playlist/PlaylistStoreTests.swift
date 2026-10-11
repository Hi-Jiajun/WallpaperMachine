import XCTest
@testable import WallpaperMachine

@MainActor
final class PlaylistStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "WallpaperMachine.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }


    func testPlaylistsAndDatesOutliveTheApp() {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") {
            $0.mode = .rotate
            $0.order = .shuffle
            $0.interval = 60
        }
        store.add(["a", "b", "a"], to: "primary")
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        store.schedule("primary", at: due)

        let reloaded = PlaylistStore(defaults: defaults)
        XCTAssertEqual(reloaded.playlist(for: "primary").mode, .rotate)
        XCTAssertEqual(reloaded.playlist(for: "primary").order, .shuffle)
        XCTAssertEqual(reloaded.playlist(for: "primary").interval, 60)
        XCTAssertEqual(reloaded.playlist(for: "primary").wallpaperIDs, ["a", "b"], "a wallpaper is on a list once")
        XCTAssertEqual(reloaded.nextChange["primary"], due)
    }

    func testCustomIntervalsOutliveTheAppAndOutOfRangeOnesFallBack() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.interval = 45 }
        XCTAssertEqual(PlaylistStore(defaults: defaults).playlist(for: "primary").interval, 45)

        for stored in [0, 7 * 24 * 60 + 1] {
            let data = try XCTUnwrap(#"{"mode":"rotate","interval":\#(stored)}"#.data(using: .utf8))
            let playlist = try JSONDecoder().decode(DisplayPlaylist.self, from: data)
            XCTAssertEqual(playlist.interval, DisplayPlaylist().interval, "\(stored) minutes is outside the range")
        }
    }

    func testChangingTheRhythmStartsAFreshWait() {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate }
        store.schedule("primary", at: Date())
        store.add(["a"], to: "primary")
        XCTAssertNotNil(store.nextChange["primary"], "editing the list keeps the wait")
        store.update("primary") { $0.interval = 120 }
        XCTAssertNil(store.nextChange["primary"])
    }

    func testReorderingPreservesMembershipAndDeadlineAndDetachesSavedPlan() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b", "c"] }
        let plan = try store.savePlan(from: "primary", name: "Original")
        try store.applyPlan(plan.id, to: "primary")
        let deadline = Date(timeIntervalSince1970: 1_800_000_000)
        store.schedule("primary", at: deadline)
        try store.reorder(["c", "a", "b"], on: "primary", expected: ["a", "b", "c"])
        let reloaded = PlaylistStore(defaults: defaults)
        XCTAssertEqual(reloaded.playlist(for: "primary").wallpaperIDs, ["c", "a", "b"])
        XCTAssertNil(reloaded.playlist(for: "primary").planID)
        XCTAssertEqual(reloaded.nextChange["primary"], deadline)
        XCTAssertEqual(reloaded.plan(id: plan.id)?.playlist.wallpaperIDs, ["a", "b", "c"])
    }

    func testStaleDuplicateOrForeignReordersLeaveTheListIntact() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.source = .list; $0.wallpaperIDs = ["a", "b", "c"] }
        for ids in [["a", "b"], ["a", "a", "c"], ["a", "b", "elsewhere"]] {
            XCTAssertThrowsError(try store.reorder(ids, on: "primary"))
        }
        XCTAssertThrowsError(try store.reorder(["c", "b", "a"], on: "primary", expected: ["b", "a", "c"]))
        XCTAssertEqual(store.playlist(for: "primary").wallpaperIDs, ["a", "b", "c"])
        store.update("primary") { $0.source = .collection }
        XCTAssertThrowsError(try store.reorder(["c", "b", "a"], on: "primary"))
    }

    func testWallpapersThatLeaveTheLibraryLeaveEveryPlaylist() {
        let store = PlaylistStore(defaults: defaults)
        store.add(["a", "b"], to: "primary")
        store.update("second") {
            $0.mode = .dayNight
            $0.dayWallpaperID = "b"
            $0.nightWallpaperID = "c"
        }
        store.forget(["b"])
        XCTAssertEqual(store.playlist(for: "primary").wallpaperIDs, ["a"])
        XCTAssertNil(store.playlist(for: "second").dayWallpaperID)
        XCTAssertEqual(store.playlist(for: "second").nightWallpaperID, "c")
        XCTAssertNil(PlaylistStore(defaults: defaults).playlist(for: "second").dayWallpaperID)
    }

    func testRedatingToTheSameDateIsNotAChange() {
        let store = PlaylistStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        store.schedule("primary", at: date)
        let posts = PostCount()
        let token = NotificationCenter.default.addObserver(
            forName: PlaylistStore.didChangeNotification, object: store, queue: nil
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.schedule("primary", at: date)
        XCTAssertEqual(posts.value, 0, "the scheduler re-dates on every evaluation without a feedback loop")
    }
    func testPlansCopyAcrossDisplaysAndManualEditsDetachOnlyThatDisplay() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") {
            $0.mode = .rotate
            $0.source = .list
            $0.wallpaperIDs = ["a", "b"]
            $0.interval = 60
        }
        let plan = try store.savePlan(from: "primary", name: " Evening ")
        try store.applyPlan(plan.id, to: "primary")
        try store.applyPlan(plan.id, to: "second")
        store.update("second") { $0.interval = 60 }
        XCTAssertEqual(store.playlist(for: "second").planID, plan.id, "a no-op keeps the active plan")
        store.update("second") { $0.interval = 120 }
        XCTAssertNil(store.playlist(for: "second").planID)
        XCTAssertEqual(store.playlist(for: "primary").interval, 60)
        XCTAssertEqual(store.plan(id: plan.id)?.playlist.interval, 60)
        XCTAssertNil(store.plan(id: plan.id)?.playlist.planID)
        try store.renamePlan(plan.id, name: "Night")
        let reloaded = PlaylistStore(defaults: defaults)
        XCTAssertEqual(reloaded.plan(id: plan.id)?.name, "Night")
        XCTAssertEqual(reloaded.playlist(for: "primary").planID, plan.id)
        XCTAssertEqual(reloaded.playlist(for: "second").interval, 120)
        XCTAssertEqual(reloaded.nextChange["primary"], .distantPast)
    }

    func testPlanDeletionRetainsActiveCopyAndItsSchedule() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
        let plan = try store.savePlan(from: "primary", name: "Rotation")
        try store.applyPlan(plan.id, to: "second")
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        store.schedule("second", at: due)
        try store.deletePlan(plan.id)
        let reloaded = PlaylistStore(defaults: defaults)
        XCTAssertNil(reloaded.plan(id: plan.id))
        XCTAssertEqual(reloaded.playlist(for: "second").wallpaperIDs, ["a", "b"])
        XCTAssertNil(reloaded.playlist(for: "second").planID)
        XCTAssertEqual(reloaded.nextChange["second"], due)
        XCTAssertThrowsError(try store.applyPlan(plan.id, to: "primary"))
    }

    func testDeletingWallpapersCleansInactivePlansAsWellAsActiveDisplays() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") {
            $0.wallpaperIDs = ["a", "b"]
            $0.dayWallpaperID = "b"
            $0.nightWallpaperID = "c"
        }
        let plan = try store.savePlan(from: "primary", name: "Day")
        store.forget(["b"])
        let reloaded = PlaylistStore(defaults: defaults)
        XCTAssertEqual(reloaded.plan(id: plan.id)?.playlist.wallpaperIDs, ["a"])
        XCTAssertNil(reloaded.plan(id: plan.id)?.playlist.dayWallpaperID)
        XCTAssertEqual(reloaded.plan(id: plan.id)?.playlist.nightWallpaperID, "c")
    }

    func testRemovingCollectionEmptiesReferencesWithoutExpandingRotation() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") {
            $0.mode = .rotate; $0.source = .collection; $0.collectionID = "collection"
            $0.wallpaperIDs = ["stale-list"]
        }
        let plan = try store.savePlan(from: "primary", name: "Collection")
        try store.applyPlan(plan.id, to: "second")
        store.forgetCollection("collection")
        let reloaded = PlaylistStore(defaults: defaults)
        XCTAssertEqual(reloaded.playlist(for: "second").source, .list)
        XCTAssertEqual(reloaded.playlist(for: "second").wallpaperIDs, [])
        XCTAssertNil(reloaded.playlist(for: "second").collectionID)
        XCTAssertEqual(reloaded.plan(id: plan.id)?.playlist.source, .list)
        XCTAssertEqual(reloaded.plan(id: plan.id)?.playlist.wallpaperIDs, [])
    }

    func testInvalidPlanNamesLeaveSavedPlanAndDisplayUnchanged() throws {
        let store = PlaylistStore(defaults: defaults)
        let plan = try store.savePlan(from: "primary", name: "Valid")
        XCTAssertThrowsError(try store.renamePlan(plan.id, name: " \n "))
        XCTAssertThrowsError(try store.savePlan(from: "primary", name: String(repeating: "x", count: 129)))
        XCTAssertEqual(store.plans, [plan])
        XCTAssertEqual(PlaylistStore(defaults: defaults).plans, [plan])
    }
}

private final class PostCount: @unchecked Sendable {
    var value = 0
}
