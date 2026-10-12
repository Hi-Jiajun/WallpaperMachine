import XCTest
@testable import WallpaperMachine

@MainActor
final class HotKeyPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    private let playPause = HotKey(keyCode: 35, modifiers: 6400, label: "⌃⌥⌘P")

    func testNoShortcutIsTakenUntilTheUserRecordsOne() {
        XCTAssertTrue(HotKeyPreferences(defaults: defaults).bindings.isEmpty)
    }

    func testRecordedShortcutsOutliveTheAppAndCanBeCleared() throws {
        let preferences = HotKeyPreferences(defaults: defaults)
        try preferences.set(playPause, for: .togglePlayback)
        XCTAssertEqual(HotKeyPreferences(defaults: defaults).bindings[.togglePlayback], playPause)
        try preferences.set(nil, for: .togglePlayback)
        XCTAssertNil(HotKeyPreferences(defaults: defaults).bindings[.togglePlayback])
    }

    func testOneCombinationServesOneActionOnly() throws {
        let preferences = HotKeyPreferences(defaults: defaults)
        try preferences.set(playPause, for: .togglePlayback)
        XCTAssertThrowsError(try preferences.set(playPause, for: .nextWallpaper))
        XCTAssertNil(preferences.bindings[.nextWallpaper])
        XCTAssertNoThrow(try preferences.set(playPause, for: .togglePlayback), "setting the same one again is fine")
    }

    func testARefusalIsForgottenOnceTheShortcutChanges() throws {
        let preferences = HotKeyPreferences(defaults: defaults)
        try preferences.set(playPause, for: .togglePlayback)
        preferences.recordFailure("taken", for: .togglePlayback)
        XCTAssertEqual(preferences.failures[.togglePlayback], "taken")
        try preferences.set(HotKey(keyCode: 45, modifiers: 6400, label: "⌃⌥⌘N"), for: .togglePlayback)
        XCTAssertNil(preferences.failures[.togglePlayback])
    }

    func testEachShortcutRunsTheCommandItNames() {
        XCTAssertEqual(Set(HotKeyAction.allCases.map(\.identifier)).count, HotKeyAction.allCases.count)
        XCTAssertFalse(HotKeyAction.allCases.contains { $0.identifier == 0 })
    }
}
