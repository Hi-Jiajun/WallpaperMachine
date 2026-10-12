import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperDisplayTransferTests: XCTestCase {
    private var state: WallpaperDisplayTransfer.Snapshot!
    private var applied: [String] = []
    override func setUp() {
        super.setUp()
        state = .init(displays: [
            .init(id: "primary", title: "Main", eligible: true, wallpaperID: "a"),
            .init(id: "identity:secondary", title: "Second", eligible: true, wallpaperID: "b"),
        ], wallpapers: ["a", "b", "c"])
        applied = []
    }
    private func set(_ id: String?, on display: String) {
        if let index = state.displays.firstIndex(where: { $0.id == display }) { state.displays[index].wallpaperID = id }
    }
    private func run(_ request: WallpaperDisplayTransfer.Request,
                     prepare: @escaping @MainActor (Set<String>) async throws -> Void = { _ in },
                     action: (@MainActor (String, String) async throws -> Void)? = nil) async throws {
        _ = try await WallpaperDisplayTransfer.execute(request, snapshot: { self.state }, prepare: prepare,
            apply: { id, display in
                self.applied.append("\(display)=\(id)")
                if let action { try await action(id, display) }
                else { self.set(id, on: display) }
            }, clear: { _, display in self.set(nil, on: display) })
    }
    private var assignments: [String?] { state.displays.map(\.wallpaperID) }

    func testCaptureKeepsStableDisplayIdentityAndExcludesEmptyAndMirroredDisplays() throws {
        state.displays += [.init(id: "empty", title: "Empty", eligible: true, wallpaperID: nil),
                           .init(id: "mirror", title: "Mirror", eligible: false, wallpaperID: "a")]
        let values = try WallpaperDisplayTransfer.capture(state)
        XCTAssertEqual(values.map(\.displayID), ["primary", "identity:secondary"])
        XCTAssertEqual(values.map(\.wallpaperID), ["a", "b"])
    }

    func testARequestIsAChoiceForEveryDisplayItGivesAWallpaperTo() {
        let layout = [WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "c"),
                      WallpaperDisplayAssignment(displayID: "identity:secondary", displayTitle: "Second", wallpaperID: "a")]
        XCTAssertEqual(WallpaperDisplayTransfer.Request.layout(layout).displayIDs, ["primary", "identity:secondary"])
        XCTAssertEqual(WallpaperDisplayTransfer.Request.copy(from: "primary", to: "identity:secondary").displayIDs,
                       ["identity:secondary"], "A copy leaves its source as it was")
        XCTAssertEqual(WallpaperDisplayTransfer.Request.swap("primary", "identity:secondary").displayIDs,
                       ["primary", "identity:secondary"])
    }

    func testCopyChangesOnlyTheDestinationAndSwapUsesTheOriginalAssignments() async throws {
        try await run(.copy(from: "primary", to: "identity:secondary"))
        XCTAssertEqual(assignments, ["a", "a"])
        set("b", on: "identity:secondary")
        applied = []
        try await run(.swap("primary", "identity:secondary"))
        XCTAssertEqual(assignments, ["b", "a"])
        XCTAssertEqual(applied, ["identity:secondary=a", "primary=b"])
    }

    func testEveryDisplayAndWallpaperIsValidatedBeforeAnyWrite() async throws {
        let layout = try WallpaperDisplayTransfer.capture(state)
        state.displays[1].eligible = false
        do { try await run(.layout(layout)); XCTFail("accepted disabled screen") } catch {}
        XCTAssertTrue(applied.isEmpty)
        state.displays[1].eligible = true
        state.wallpapers.remove("b")
        do { try await run(.layout(layout)); XCTFail("accepted missing wallpaper") } catch {}
        XCTAssertTrue(applied.isEmpty)
        do { try await run(.copy(from: "primary", to: "primary")); XCTFail("accepted same screen") } catch {}
    }

    func testChangesWhilePreparingAbortBeforeAnyWrite() async {
        do {
            try await run(.swap("primary", "identity:secondary"), prepare: { _ in self.set("c", on: "primary") })
            XCTFail("used a stale source")
        } catch {}
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(assignments, ["c", "b"])
    }

    func testSecondStepFailureRestoresBothAssignmentsIncludingAMutatedFailingStep() async {
        do {
            try await run(.swap("primary", "identity:secondary"), action: { id, display in
                self.set(id, on: display)
                if id == "b", display == "primary" { throw CocoaError(.fileReadUnknown) }
            })
            XCTFail("failure was hidden")
        } catch {
            guard case WallpaperDisplayLayoutError.restored = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(assignments, ["a", "b"])
    }

    func testFailedCopyToAnEmptyDisplayRestoresItsEmptyAssignment() async {
        set(nil, on: "identity:secondary")
        do {
            try await run(.copy(from: "primary", to: "identity:secondary"), action: { id, display in
                self.set(id, on: display); throw CocoaError(.fileReadUnknown)
            })
            XCTFail("failure was hidden")
        } catch {}
        XCTAssertEqual(assignments, ["a", nil])
    }

    func testRecoveryPreservesAnExternalChoiceAndReportsIncompleteRestoration() async {
        do {
            try await run(.swap("primary", "identity:secondary"), action: { id, display in
                if display == "primary" {
                    self.set("c", on: "identity:secondary")
                    throw CocoaError(.fileReadUnknown)
                }
                self.set(id, on: display)
            })
            XCTFail("failure was hidden")
        } catch {
            guard case WallpaperDisplayLayoutError.incomplete(let displays, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(displays.contains("Second"))
        }
        XCTAssertEqual(assignments, ["a", "c"])
        XCTAssertFalse(applied.contains("identity:secondary=b"))
    }

    func testCancellationStillRunsRecoveryOutsideTheCancelledTask() async {
        let task = Task { @MainActor in
            try await run(.swap("primary", "identity:secondary"), action: { id, display in
                try Task.checkCancellation()
                self.set(id, on: display)
                if id == "a", display == "identity:secondary" { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { try await task.value; XCTFail("cancellation was ignored") } catch {}
        XCTAssertEqual(assignments, ["a", "b"])
    }
}
