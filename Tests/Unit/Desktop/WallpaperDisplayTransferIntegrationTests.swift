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

    func testApplyingEverywhereRecordsOneHistoryEntryAndManualChoicePerDisplay() async throws {
        var chosen: [String] = []
        store.onUserWallpaperChoice = { id, display in chosen.append("\(display)=\(id)") }

        try await store.activateWallpaperEverywhereAsync(id: "c")

        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "c"])
        XCTAssertEqual(bridge.applications.map { "\($0.0)=\($0.1)" }, ["primary=c", "secondary=c"], "the main display changes first")
        XCTAssertEqual(store.history.entries["primary"]?.past, ["a"])
        XCTAssertEqual(store.history.entries["secondary"]?.past, ["b"])
        XCTAssertEqual(chosen.sorted(), ["primary=c", "secondary=c"])
        XCTAssertEqual(bridge.applyRequests, [true, true], "it is the user's command, so the engine is told so")
        XCTAssertEqual(store.appSnapshot.playbackState, .paused, "the user's Play/Pause is left as it was")
        XCTAssertFalse(store.commands.isBusy)
    }

    /// The load journal holds back a wallpaper that crashed the app twice, and the user choosing
    /// it lifts the hold. A held wallpaper keeps its display assignment, so applying it to every
    /// display must apply it again on the display that reads as showing it, and as the user's
    /// choice on the others, or they would give up what they show for a wallpaper with no scene.
    func testApplyingAHeldWallpaperEverywhereLiftsTheHoldAndOpensItOnEveryDisplay() async throws {
        bridge.assignments = ["primary": "c", "secondary": "a"]
        bridge.held = ["c"]
        try await store.refreshAllAsync()
        XCTAssertEqual(store.heldWallpaperIDs, ["c"])
        var chosen: [String] = []
        store.onUserWallpaperChoice = { id, display in chosen.append("\(display)=\(id)") }

        try await store.activateWallpaperEverywhereAsync(id: "c")

        XCTAssertEqual(bridge.applyRequests, [true, true])
        XCTAssertEqual(bridge.applications.map { "\($0.0)=\($0.1)" }, ["primary=c", "secondary=c"],
                       "the held display is applied again, not skipped for already showing the wallpaper")
        XCTAssertEqual(store.heldWallpaperIDs, [], "the hold is lifted")
        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "c"])
        XCTAssertEqual(chosen.sorted(), ["primary=c", "secondary=c"], "each display is reported once")
    }

    func testApplyingAWallpaperHeldOnEveryDisplayEverywhereLiftsTheHoldOnce() async throws {
        bridge.assignments = ["primary": "c", "secondary": "c"]
        bridge.held = ["c"]
        try await store.refreshAllAsync()
        var chosen: [String] = []
        store.onUserWallpaperChoice = { id, display in chosen.append("\(display)=\(id)") }

        try await store.activateWallpaperEverywhereAsync(id: "c")

        XCTAssertEqual(bridge.applyRequests, [true], "lifting the hold opens it everywhere, so the second display is skipped")
        XCTAssertEqual(store.heldWallpaperIDs, [])
        XCTAssertEqual(chosen.sorted(), ["primary=c", "secondary=c"])
    }

    func testCopyingOrSwappingAHeldWallpaperLeavesTheHoldAlone() async throws {
        bridge.assignments = ["primary": "c", "secondary": "a"]
        bridge.held = ["c"]
        try await store.refreshAllAsync()

        try await store.applyDisplayTransferAsync(.swap("primary", "secondary"))

        XCTAssertEqual(bridge.applyRequests, [false, false], "moving assignments around is not choosing the wallpaper again")
        XCTAssertEqual(store.heldWallpaperIDs, ["c"])
    }

    func testApplyingEverywhereLeavesADisplayThatAlreadyShowsTheWallpaperAloneButStillCountsItAsChosen() async throws {
        var chosen: [String] = []
        store.onUserWallpaperChoice = { id, display in chosen.append("\(display)=\(id)") }

        try await store.activateWallpaperEverywhereAsync(id: "a")

        XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "a"])
        XCTAssertEqual(bridge.applications.map { "\($0.0)=\($0.1)" }, ["secondary=a"], "primary was not reloaded")
        XCTAssertNil(store.history.entries["primary"], "nothing changed on primary, so it has nothing to go back to")
        XCTAssertEqual(store.history.entries["secondary"]?.past, ["b"])
        XCTAssertEqual(chosen.sorted(), ["primary=a", "secondary=a"])
    }

    func testAFailedApplyEverywhereRestoresEveryDisplayWithoutHistory() async throws {
        bridge.failOnce = "secondary=c"; bridge.failAfterMutation = true
        var chosen = 0; store.onUserWallpaperChoice = { _, _ in chosen += 1 }
        do { try await store.activateWallpaperEverywhereAsync(id: "c"); XCTFail("accepted a failed apply") }
        catch { guard case WallpaperDisplayLayoutError.restored = error else { return XCTFail("unexpected \(error)") } }
        XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
        XCTAssertTrue(store.history.entries.isEmpty)
        XCTAssertEqual(chosen, 0)
        XCTAssertFalse(store.commands.isBusy)
    }

    func testPendingEditsBlockApplyingEverywhereBeforeAnyWrite() async {
        bridge.dirtyWallpapers.insert("c")
        do { try await store.activateWallpaperEverywhereAsync(id: "c"); XCTFail("applied unapplied edits") }
        catch { guard case WallpaperDisplayLayoutError.pendingEdits = error else { return XCTFail("unexpected \(error)") } }
        XCTAssertTrue(bridge.applications.isEmpty)
        XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
    }

    /// A mirror follows its source and a disabled display shows nothing, so with one independent
    /// display left this is an ordinary apply, and with none it is refused before any write.
    func testApplyingEverywhereLeavesMirroredAndDisabledDisplaysOutAndRefusesWhenNoneIsLeft() async throws {
        bridge.mirrors = ["secondary": "primary"]
        try await store.refreshAllAsync()
        try await store.activateWallpaperEverywhereAsync(id: "c")
        XCTAssertEqual(bridge.applications.map { "\($0.0)=\($0.1)" }, ["primary=c"])
        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "b"], "the mirror's own assignment is untouched")

        bridge.mirrors = [:]
        bridge.eligible = ["secondary"]
        try await store.refreshAllAsync()
        try await store.activateWallpaperEverywhereAsync(id: "a")
        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "a"], "a disabled display is left alone")

        bridge.eligible = []
        try await store.refreshAllAsync()
        let writes = bridge.applications.count
        do { try await store.activateWallpaperEverywhereAsync(id: "b"); XCTFail("applied with no display to apply to") }
        catch { guard case WallpaperDisplayLayoutError.noEligibleDisplays = error else { return XCTFail("unexpected \(error)") } }
        XCTAssertEqual(bridge.applications.count, writes)
    }

    func testApplyingEverywhereCountsAsTheChoiceForEveryDisplayWhenAskedForNotWhenItGetsItsTurn() async throws {
        var release: CheckedContinuation<Void, Never>?
        let busy = Task { try await store.commands.run(slot: "other") { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }

        let everywhere = Task { try await store.activateWallpaperEverywhereAsync(id: "c") }
        while store.commands.waiting.isEmpty { await Task.yield() }
        XCTAssertEqual(["primary", "secondary"].map { store.commands.userRevision(for: BridgeStore.activationSlot(displayId: $0)) }, [1, 1])
        XCTAssertTrue(bridge.applications.isEmpty, "It has not run yet")

        release?.resume()
        try await busy.value
        try await everywhere.value
        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "c"])
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

    /// Only the user's own removal tells a playlist to leave the display empty. The ejects the
    /// app makes while it deletes, reloads or reapplies a wallpaper are not a removal.
    func testOnlyAUserRemovalReportsARemoval() async throws {
        var removed: [String] = []
        store.onUserWallpaperRemoved = { id, display in removed.append("\(display)=\(id)") }

        try await store.reloadWallpaperAsync(id: "a")
        XCTAssertEqual(bridge.ejections.map { "\($0.0)=\($0.1)" }, ["primary=a"], "a reload ejects and applies again")
        let deleted = try await store.deleteWallpapersAsync(ids: ["b"], recycle: { _ in })
        XCTAssertEqual(deleted.deleted, ["b"])
        XCTAssertNil(bridge.assignments["secondary"], "deleting a wallpaper took it off the display showing it")
        XCTAssertEqual(removed, [], "neither is something the user asked to be left empty")

        bridge.ejectFailure = CocoaError(.fileWriteUnknown)
        do {
            try await store.removeWallpaperFromDisplayAsync(displayId: "primary", wallpaperId: "a")
            XCTFail("the removal succeeded")
        } catch {}
        bridge.ejectFailure = nil
        XCTAssertEqual(bridge.assignments["primary"], "a")
        XCTAssertEqual(removed, [], "a removal that failed removed nothing")

        try await store.removeWallpaperFromDisplayAsync(displayId: "primary", wallpaperId: "c")
        XCTAssertEqual(bridge.assignments["primary"], "a")
        XCTAssertEqual(removed, [], "the display still shows its wallpaper, so nothing was removed from it")

        try await store.removeWallpaperFromDisplayAsync(displayId: "primary", wallpaperId: "a")
        XCTAssertNil(bridge.assignments["primary"])
        XCTAssertEqual(removed, ["primary=a"])
        XCTAssertNil(store.shownWallpaperID(on: "primary"))
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
