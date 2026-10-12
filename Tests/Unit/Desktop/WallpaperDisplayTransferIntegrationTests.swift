import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperDisplayTransferIntegrationTests: XCTestCase {
    private var bridge: DisplayTransferTestBridge!
    private var store: BridgeStore!
    private var root: URL!
    private var previousHome: String?
    override func setUp() async throws {
        previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("display-transfer-\(UUID().uuidString)")
        setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
        bridge = DisplayTransferTestBridge(noPointer: .init())
        try bridge.installProjects(in: root.appendingPathComponent("Library"))
        store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
    }
    override func tearDown() async throws {
        if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
        try FileManager.default.removeItem(at: root)
    }

    func testSuccessfulSwapRecordsOneHistoryEntryAndManualChoicePerDisplay() async throws {
        var chosen: [String] = []
        store.onUserWallpaperChoice = { id, display in chosen.append("\(display)=\(id)") }
        try await store.applyDisplayTransferAsync(.swap("primary", "secondary"))
        XCTAssertEqual(bridge.assignments, ["primary": "b", "secondary": "a"])
        XCTAssertEqual(store.history.entries["primary"]?.past, ["a"])
        XCTAssertEqual(store.history.entries["secondary"]?.past, ["b"])
        XCTAssertEqual(Set(chosen), ["primary=b", "secondary=a"])
        XCTAssertEqual(store.appSnapshot.playbackState, .paused)
    }

    func testFailedSwapRollsBackWithoutAddingHistoryOrManualOverrides() async throws {
        bridge.failOnce = "primary=b"; bridge.failAfterMutation = true
        var chosen = 0; store.onUserWallpaperChoice = { _, _ in chosen += 1 }
        do { try await store.applyDisplayTransferAsync(.swap("primary", "secondary")); XCTFail("accepted failed swap") }
        catch { guard case WallpaperDisplayLayoutError.restored = error else { return XCTFail("unexpected \(error)") } }
        XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
        XCTAssertTrue(store.history.entries.isEmpty)
        XCTAssertEqual(chosen, 0)
        XCTAssertFalse(store.commands.isBusy)
    }

    func testPendingWallpaperEditsBlockAllDisplayChanges() async {
        bridge.dirtyWallpapers.insert("b")
        do { try await store.applyDisplayTransferAsync(.swap("primary", "secondary")); XCTFail("applied dirty options") } catch {}
        XCTAssertTrue(bridge.applications.isEmpty)
        XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
    }

    /// Work that outlives a command (a Download and apply) stands down for a choice of the user's
    /// in its display's slot; a transfer has no slot of its own, so it has to be counted per display.
    func testATransferCountsAsTheUsersChoiceForTheDisplaysItGivesAWallpaperTo() async throws {
        func revisions() -> [Int] {
            ["primary", "secondary"].map { Int(store.commands.userRevision(for: BridgeStore.activationSlot(displayId: $0))) }
        }
        XCTAssertEqual(revisions(), [0, 0])

        try await store.applyDisplayTransferAsync(.copy(from: "primary", to: "secondary"))
        XCTAssertEqual(revisions(), [0, 1], "A copy is a choice for the destination only")

        try await store.applyDisplayTransferAsync(.layout([
            WallpaperDisplayAssignment(displayID: "primary", displayTitle: "primary", wallpaperID: "c")]))
        XCTAssertEqual(revisions(), [1, 1], "A layout is a choice for the displays it names")

        try await store.applyDisplayTransferAsync(.swap("primary", "secondary"))
        XCTAssertEqual(revisions(), [2, 2])
    }

    func testATransferThatCannotRunStillCountsAsTheChoiceItWas() async throws {
        bridge.dirtyWallpapers.insert("b")
        do { try await store.applyDisplayTransferAsync(.swap("primary", "secondary")); XCTFail("applied dirty options") } catch {}
        XCTAssertEqual(store.commands.userRevision(for: BridgeStore.activationSlot(displayId: "primary")), 1,
                       "Failing to carry a choice out does not unmake it, as for any command")
    }

    func testTheChoiceIsCountedWhenTheTransferIsAskedForNotWhenItGetsItsTurn() async throws {
        var release: CheckedContinuation<Void, Never>?
        let busy = Task { try await store.commands.run(slot: "other") { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }

        let transfer = Task { try await store.applyDisplayTransferAsync(.copy(from: "primary", to: "secondary")) }
        while store.commands.waiting.isEmpty { await Task.yield() }
        XCTAssertEqual(store.commands.userRevision(for: BridgeStore.activationSlot(displayId: "secondary")), 1)
        XCTAssertTrue(bridge.applications.isEmpty, "It has not run yet")

        release?.resume()
        try await busy.value
        try await transfer.value
        XCTAssertEqual(bridge.assignments["secondary"], "a")
    }

    func testLaterIndividualChoiceWaitsForTheLayoutThenWins() async throws {
        var release: CheckedContinuation<Void, Never>?
        bridge.beforeApply = {
            self.bridge.beforeApply = nil
            await withCheckedContinuation { release = $0 }
        }
        let layout = Task { try await store.applyDisplayTransferAsync(.swap("primary", "secondary")) }
        while release == nil { await Task.yield() }
        let manual = Task { try await store.commands.run(slot: BridgeStore.activationSlot(displayId: "primary")) {
            try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .user)
        } }
        for _ in 0..<10 { await Task.yield() }
        release?.resume()
        try await layout.value
        try await manual.value
        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "a"])
    }
}
