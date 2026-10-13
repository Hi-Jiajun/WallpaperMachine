import XCTest
@testable import WallpaperMachine

@MainActor
final class PlaylistStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    override func tearDown() {
        defaults = nil
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

    /// A display the user emptied stays empty across a relaunch, and anything that turns the
    /// playlist off or chooses another one is the end of the wait.
    func testAHoldOutlivesTheAppAndEndsWithTheMode() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
        store.schedule("primary", at: Date(timeIntervalSince1970: 1_800_000_000))
        store.setHold(.removedWallpaper, on: "primary")
        XCTAssertEqual(store.holds, ["primary": .removedWallpaper])
        XCTAssertNil(store.nextChange["primary"], "a waiting display has no deadline")

        let reloaded = PlaylistStore(defaults: defaults)
        XCTAssertEqual(reloaded.holds, ["primary": .removedWallpaper])
        XCTAssertNil(reloaded.nextChange["primary"])

        reloaded.update("primary") { $0.interval = 60 }
        XCTAssertEqual(reloaded.holds["primary"], .removedWallpaper, "another rhythm is not a request to fill the display")
        reloaded.update("primary") { $0.mode = .off }
        XCTAssertTrue(reloaded.holds.isEmpty, "an Off playlist has nothing to wait for")
        XCTAssertTrue(PlaylistStore(defaults: defaults).holds.isEmpty)

        reloaded.update("primary") { $0.mode = .rotate }
        let plan = try reloaded.savePlan(from: "primary", name: "Rotation")
        reloaded.setHold(.removedWallpaper, on: "primary")
        try reloaded.applyPlan(plan.id, to: "primary")
        XCTAssertTrue(reloaded.holds.isEmpty, "choosing a playlist is asking for it to run")

        reloaded.setHold(.removedWallpaper, on: "primary")
        reloaded.restore(DisplayPlaylist(), on: "primary")
        XCTAssertTrue(reloaded.holds.isEmpty, "a restored playlist runs again")
    }

    func testAHoldIsPostedOnceAndAnUnknownStoredOneIsIgnored() {
        let store = PlaylistStore(defaults: defaults)
        let posts = PostCount()
        let token = NotificationCenter.default.addObserver(
            forName: PlaylistStore.didChangeNotification, object: store, queue: nil
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.setHold(.removedWallpaper, on: "primary")
        store.setHold(.removedWallpaper, on: "primary")
        XCTAssertEqual(posts.value, 1, "holding a held display again is not a change")
        store.setHold(nil, on: "primary")
        store.setHold(nil, on: "primary")
        XCTAssertEqual(posts.value, 2)

        defaults.set(["primary": "someFutureReason", "second": "removedWallpaper"], forKey: "WallpaperMachine.playlistHolds")
        XCTAssertEqual(PlaylistStore(defaults: defaults).holds, ["second": .removedWallpaper],
                       "a hold from a newer version leaves the display free instead of stuck")
    }

    private static let roundsKey = "WallpaperMachine.playlistRounds"
    private static let playlistsKey = "WallpaperMachine.playlists"
    private let library = ["a", "b", "c", "d"]

    /// Rewrites the saved playlists behind the store's back, as restoring a backup does.
    private func rewriteSavedPlaylists(_ edit: (inout [String: DisplayPlaylist]) -> Void) throws {
        let data = try XCTUnwrap(defaults.data(forKey: Self.playlistsKey))
        var playlists = try JSONDecoder().decode([String: DisplayPlaylist].self, from: data)
        edit(&playlists)
        defaults.set(try JSONEncoder().encode(playlists), forKey: Self.playlistsKey)
    }

    func testTheShuffleRoundOutlivesTheApp() {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.order = .shuffle }
        store.recordPick("a", on: "primary", candidates: library)
        store.recordPick("b", on: "primary", candidates: library)

        let reloaded = PlaylistStore(defaults: defaults)
        XCTAssertEqual(reloaded.recent["primary"], ["a", "b"])

        reloaded.recordPick("c", on: "primary", candidates: library)
        XCTAssertEqual(PlaylistStore(defaults: defaults).recent["primary"], ["a", "b", "c"],
                       "the round carries on from where the last launch left it")
    }

    func testACompletedRoundIsNotKept() {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.order = .shuffle }
        for id in library { store.recordPick(id, on: "primary", candidates: library) }
        XCTAssertEqual(store.recent["primary"], [], "the last wallpaper of a round ends it")
        XCTAssertNil(defaults.object(forKey: Self.roundsKey), "a fresh round leaves nothing behind")
        XCTAssertNil(PlaylistStore(defaults: defaults).recent["primary"])
    }

    func testARoundIsDroppedWhenTheSourceCollectionOrderOrModeChanges() {
        let store = PlaylistStore(defaults: defaults)
        let edits: [(display: String, edit: (inout DisplayPlaylist) -> Void)] = [
            ("source", { $0.source = .favorites }),
            ("collection", { $0.collectionID = "collection" }),
            ("order", { $0.order = .sequential }),
            ("mode", { $0.mode = .off }),
        ]
        for display in edits.map(\.display) + ["kept"] {
            store.update(display) { $0.mode = .rotate; $0.order = .shuffle }
            store.recordPick("a", on: display, candidates: library)
        }
        XCTAssertEqual(PlaylistStore(defaults: defaults).recent.count, 5)

        for (display, edit) in edits { store.update(display, edit) }
        store.update("kept") { $0.interval = 60 }
        XCTAssertEqual(store.recent, ["kept": ["a"]], "the running app starts the round over too")
        XCTAssertEqual(PlaylistStore(defaults: defaults).recent, ["kept": ["a"]],
                       "only an edit of what the round is drawn from starts a new one")
    }

    func testEditingTheListLeavesTheRound() {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.order = .shuffle; $0.source = .list; $0.wallpaperIDs = library }
        for id in ["a", "b", "c"] { store.recordPick(id, on: "primary", candidates: library) }
        store.add(["e"], to: "primary")
        XCTAssertEqual(PlaylistStore(defaults: defaults).recent["primary"], ["a", "b", "c"])
    }

    func testDeletingAWallpaperPrunesTheRoundEvenWhenNoListHeldIt() {
        let store = PlaylistStore(defaults: defaults)
        store.update("everything") { $0.mode = .rotate; $0.order = .shuffle }
        for id in ["a", "b", "c"] { store.recordPick(id, on: "everything", candidates: library) }
        store.forget(["b"])
        XCTAssertEqual(PlaylistStore(defaults: defaults).recent["everything"], ["a", "c"])

        store.update("primary") { $0.mode = .rotate; $0.order = .shuffle; $0.source = .list; $0.wallpaperIDs = library }
        for id in ["a", "c"] { store.recordPick(id, on: "primary", candidates: library) }
        store.forget(["c"])
        let reloaded = PlaylistStore(defaults: defaults)
        XCTAssertEqual(reloaded.recent["primary"], ["a"])
        XCTAssertEqual(reloaded.recent["everything"], ["a"])
    }

    func testARoundForADisplayWithoutAShufflePlaylistIsNotRestored() throws {
        let store = PlaylistStore(defaults: defaults)
        for display in ["shuffling", "ghost", "idle", "sequential", "dayNight"] {
            store.update(display) { $0.mode = .rotate; $0.order = .shuffle }
            store.recordPick("a", on: display, candidates: library)
        }
        XCTAssertEqual(PlaylistStore(defaults: defaults).recent.count, 5)

        try rewriteSavedPlaylists {
            $0["ghost"] = nil
            $0["idle"]?.mode = .off
            $0["sequential"]?.order = .sequential
            $0["dayNight"]?.mode = .dayNight
        }
        XCTAssertEqual(PlaylistStore(defaults: defaults).recent, ["shuffling": ["a"]])
    }

    func testARestoredPlaylistFromAnotherSourceDoesNotInheritTheRound() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.order = .shuffle; $0.source = .favorites }
        store.update("second") { $0.mode = .rotate; $0.order = .shuffle; $0.source = .favorites }
        store.recordPick("a", on: "primary", candidates: library)
        store.recordPick("a", on: "second", candidates: library)

        try rewriteSavedPlaylists {
            $0["primary"]?.source = .all
            $0["second"]?.collectionID = "collection"
        }
        XCTAssertTrue(PlaylistStore(defaults: defaults).recent.isEmpty,
                      "a round belongs to the wallpapers it was drawn from")
    }

    func testInOrderRotationWritesNoRound() {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.order = .sequential }
        store.recordPick("a", on: "primary", candidates: library)
        store.schedule("primary", at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(defaults.object(forKey: Self.roundsKey))
        XCTAssertNil(PlaylistStore(defaults: defaults).recent["primary"])
    }

    func testPickingWallpapersPostsNothingAndAnUnreadableRoundStartsFresh() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.order = .shuffle }
        let posts = PostCount()
        let token = NotificationCenter.default.addObserver(
            forName: PlaylistStore.didChangeNotification, object: store, queue: nil
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.recordPick("a", on: "primary", candidates: library)
        XCTAssertEqual(posts.value, 0, "the panel does not redraw for a pick the scheduler dates anyway")

        let saved = try XCTUnwrap(defaults.data(forKey: Self.roundsKey))
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        future["random"] = ["pool": ["x"]]
        defaults.set(try JSONSerialization.data(withJSONObject: future), forKey: Self.roundsKey)
        XCTAssertEqual(PlaylistStore(defaults: defaults).recent["primary"], ["a"],
                       "a field a newer build added does not cost the round")

        for unreadable in [Data("not json".utf8), Data(#"{"playlists":5}"#.utf8), Data("{}".utf8)] {
            defaults.set(unreadable, forKey: Self.roundsKey)
            XCTAssertTrue(PlaylistStore(defaults: defaults).recent.isEmpty)
        }
    }

    func testASavedRoundIsCappedToTheNewestPicks() throws {
        let store = PlaylistStore(defaults: defaults)
        store.update("primary") { $0.mode = .rotate; $0.order = .shuffle }
        store.recordPick("a", on: "primary", candidates: library)
        let saved = try XCTUnwrap(defaults.data(forKey: Self.roundsKey))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var playlists = try XCTUnwrap(object["playlists"] as? [String: [String: Any]])
        playlists["primary"]?["ids"] = (0..<3000).map { "wallpaper-\($0)" }
        object["playlists"] = playlists
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: Self.roundsKey)

        let round = try XCTUnwrap(PlaylistStore(defaults: defaults).recent["primary"])
        XCTAssertEqual(round.count, 2048)
        XCTAssertEqual(round.first, "wallpaper-952")
        XCTAssertEqual(round.last, "wallpaper-2999", "the newest picks are the ones kept")
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
