import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    func testPreviousWalksBackAndRecentTracksActualUseAcrossRelaunch() {
        let history = WallpaperHistoryStore(defaults: defaults)
        let available: Set<String> = ["a", "b", "c"]
        history.recordSwitch(from: "a", to: "b", on: "primary")
        history.recordSwitch(from: "b", to: "c", on: "primary")
        history.recordSwitch(from: "c", to: "c", on: "primary")
        XCTAssertEqual(history.previous(on: "primary", current: "c", available: available), "b")
        history.recordSwitch(from: "c", to: "b", on: "primary", returningToPrevious: true)
        XCTAssertEqual(history.previous(on: "primary", current: "b", available: available), "a")
        history.recordSwitch(from: "b", to: "a", on: "primary", returningToPrevious: true)
        XCTAssertNil(history.previous(on: "primary", current: "a", available: available))
        let reloaded = WallpaperHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.recent(on: "primary", available: available), ["a", "b", "c"])
        XCTAssertNil(reloaded.previous(on: "primary", current: "a", available: available))
    }

    func testUnavailableWallpapersAreSkippedAndDeletionCleansEveryDisplay() {
        let history = WallpaperHistoryStore(defaults: defaults)
        history.recordSwitch(from: "a", to: "b", on: "primary")
        history.recordSwitch(from: "b", to: "c", on: "primary")
        history.recordSwitch(from: "b", to: "d", on: "secondary")
        XCTAssertEqual(history.previous(on: "primary", current: "c", available: ["a", "c"]), "a")
        history.forget(["b"])
        let reloaded = WallpaperHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.recent(on: "primary", available: ["a", "b", "c"]), ["c", "a"])
        XCTAssertNil(reloaded.previous(on: "secondary", current: "d", available: ["a", "b", "c", "d"]))
    }

    func testEachDisplayCanBeClearedWithoutChangingTheOther() {
        let history = WallpaperHistoryStore(defaults: defaults)
        history.recordSwitch(from: "a", to: "b", on: "primary")
        history.recordSwitch(from: "x", to: "y", on: "secondary")
        history.clear(on: "primary")
        let reloaded = WallpaperHistoryStore(defaults: defaults)
        XCTAssertTrue(reloaded.recent(on: "primary", available: ["a", "b"]).isEmpty)
        XCTAssertEqual(reloaded.previous(on: "secondary", current: "y", available: ["x", "y"]), "x")
    }

    func testHistoryStaysBoundedAndAChoiceAfterGoingBackStartsANewPath() {
        let history = WallpaperHistoryStore(defaults: defaults)
        for index in 1...100 {
            history.recordSwitch(from: "\(index - 1)", to: "\(index)", on: "primary")
        }
        let available = Set((0...100).map(String.init))
        XCTAssertEqual(history.recent(on: "primary", available: available).count, WallpaperHistoryStore.limit)
        XCTAssertEqual(history.entries["primary"]?.past.count, WallpaperHistoryStore.limit)
        history.recordSwitch(from: "100", to: "99", on: "primary", returningToPrevious: true)
        history.recordSwitch(from: "99", to: "new", on: "primary")
        XCTAssertEqual(history.previous(on: "primary", current: "new", available: available), "99")
        history.recordSwitch(from: "new", to: "99", on: "primary", returningToPrevious: true)
        XCTAssertEqual(history.previous(on: "primary", current: "99", available: available), "98")
    }

    func testCorruptHistoryDoesNotPreventNewSwitches() {
        defaults.set(Data("broken".utf8), forKey: WallpaperHistoryStore.preferenceKey)
        let history = WallpaperHistoryStore(defaults: defaults)
        history.recordSwitch(from: nil, to: "first", on: "primary")
        XCTAssertEqual(history.recent(on: "primary", available: ["first"]), ["first"])
        XCTAssertNil(history.previous(on: "primary", current: "first", available: ["first"]))
    }
}
