import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperDisplayLayoutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let assignments = [WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "a")]
    override func setUpWithError() throws { try super.setUpWithError(); defaults = try TemporaryDefaults.make(for: self).defaults }

    func testSaveRenameAndDeletePersist() throws {
        let store = WallpaperDisplayLayoutStore(defaults: defaults)
        let value = try store.save(name: "  Work  ", assignments: assignments)
        XCTAssertEqual(value.name, "Work")
        try store.rename(value.id, name: "Evening")
        let loaded = WallpaperDisplayLayoutStore(defaults: defaults)
        XCTAssertEqual(try loaded.layout(value.id).assignments, assignments)
        XCTAssertEqual(try loaded.layout(value.id).name, "Evening")
        try loaded.delete(value.id)
        XCTAssertTrue(WallpaperDisplayLayoutStore(defaults: defaults).layouts.isEmpty)
    }

    func testInvalidAndDuplicateAssignmentsNeverReplaceSavedLayouts() throws {
        let store = WallpaperDisplayLayoutStore(defaults: defaults)
        _ = try store.save(name: "Work", assignments: assignments)
        let before = defaults.data(forKey: WallpaperDisplayLayoutStore.storageKey)
        XCTAssertThrowsError(try store.save(name: "", assignments: assignments))
        XCTAssertThrowsError(try store.save(name: "Empty", assignments: []))
        XCTAssertThrowsError(try store.save(name: "Duplicate", assignments: assignments + assignments))
        XCTAssertEqual(defaults.data(forKey: WallpaperDisplayLayoutStore.storageKey), before)
    }

    func testBoundsCorruptionAndRemovedContentRemainVisible() throws {
        let values = (0..<65).map { _ in WallpaperDisplayLayout(name: "Layout", assignments: assignments) }
        let data = try JSONEncoder().encode(values)
        XCTAssertThrowsError(try WallpaperDisplayLayoutStore.decode(data))
        defaults.set(data, forKey: WallpaperDisplayLayoutStore.storageKey)
        let invalid = WallpaperDisplayLayoutStore(defaults: defaults)
        XCTAssertTrue(invalid.layouts.isEmpty)
        XCTAssertNotNil(invalid.loadError)
        let missing = WallpaperDisplayAssignment(displayID: "unplugged", displayTitle: "Dock", wallpaperID: "removed")
        _ = try invalid.save(name: "Reconnect later", assignments: [missing])
        XCTAssertEqual(WallpaperDisplayLayoutStore(defaults: defaults).layouts.first?.assignments, [missing])
    }
}
