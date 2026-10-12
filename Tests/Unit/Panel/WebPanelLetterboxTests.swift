import XCTest

@testable import WallpaperMachine

/// The Black bars card's native half: the snapshot it is drawn from and the one action it can
/// send. The probe is injected and counted, so every case also shows what did and did not decode.
@MainActor
final class WebPanelLetterboxTests: XCTestCase {
  private final class Probes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    func record() {
      lock.lock()
      value += 1
      lock.unlock()
    }
  }

  /// Refreshing the library is the only thing that moves `libraryRefreshRevision`.
  private final class RefreshingBridge: LayoutSnapshotBridge {
    override func refreshLibrary() async throws -> BridgeSnapshotBundle {
      guard let snapshot else { throw CancellationError() }
      return snapshot
    }
  }

  func testBuildingTheSnapshotNeverStartsAProbe() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    for _ in 0..<50 { _ = fixture.controller.snapshot() }
    XCTAssertEqual(fixture.probes.count, 0)
    let payload = try fixture.payload()
    XCTAssertEqual(payload["state"] as? String, "idle")
    XCTAssertEqual(payload["wallpaperID"] as? String, "one")
    XCTAssertEqual(payload["eligible"] as? Bool, true)
    let current = try XCTUnwrap(payload["current"] as? [String: Any])
    XCTAssertEqual(current["scalingMode"] as? String, "fill")
    XCTAssertEqual(current["scalingFactor"] as? Double, 1)
  }

  func testOnlyAnInstalledVideoGetsTheCard() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    fixture.store.librarySnapshot.wallpapers = [
      .init(id: "one", title: "one", kind: .projectScene, supported: true, active: false, selected: true, previewPath: nil)
    ]
    XCTAssertNil(fixture.controller.letterboxSnapshot(), "a scene has no baked-in bars to look for")
    fixture.store.librarySnapshot.wallpapers[0] = .init(
      id: "one", title: "one", kind: .webpage, supported: true, active: false, selected: true, previewPath: nil)
    XCTAssertNil(fixture.controller.letterboxSnapshot())
    fixture.store.appSnapshot.selectedWallpaperId = nil
    XCTAssertNil(fixture.controller.letterboxSnapshot())
    XCTAssertTrue(fixture.controller.snapshot()["videoLetterbox"] is NSNull)
  }

  func testRequestsThatDoNotMatchTheCardAreRejectedWithoutStartingAProbe() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    for body: [String: Any] in [
      ["id": "two", "displayID": "7"],  // not the selected wallpaper
      ["id": "one", "displayID": "8"],  // not the target display
      ["id": "missing", "displayID": "7"],  // not installed
      ["id": "one", "displayID": true],
    ] {
      do {
        _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(body))
        XCTFail("\(body) must be rejected")
      } catch {}
    }
    let ok: [String: Any] = ["id": "one", "displayID": "7"]

    fixture.store.settingsSnapshot.displays[0].mode = .mirror
    await assertRejected(fixture, ok, "a mirror follows its source and cannot be checked on its own")
    fixture.store.settingsSnapshot.displays[0].mode = .standalone
    fixture.store.settingsSnapshot.displays[0].enabled = false
    await assertRejected(fixture, ok, "a disabled display")
    fixture.store.settingsSnapshot.displays[0].enabled = true
    fixture.store.wallpaperOptionsSnapshot = nil
    await assertRejected(fixture, ok, "no settings snapshot for the wallpaper")
    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "one", kind: .video)
    fixture.store.librarySnapshot.wallpapers[0] = .init(
      id: "one", title: "one", kind: .projectScene, supported: true, active: false, selected: true, previewPath: nil)
    await assertRejected(fixture, ok, "a scene")

    XCTAssertEqual(fixture.probes.count, 0)
    XCTAssertEqual(fixture.letterbox.phase(for: "one", revision: fixture.store.libraryRefreshRevision), .idle)
  }

  func testSuggestionFollowsTheTargetDisplayWithoutAnotherProbe() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    fixture.letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1080) }
    let handled = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
    XCTAssertTrue(handled)
    XCTAssertEqual(fixture.probes.count, 1)

    var payload = try fixture.payload()
    XCTAssertEqual(payload["state"] as? String, "bars")
    let bars = try XCTUnwrap(payload["bars"] as? [String: Double])
    XCTAssertEqual(try XCTUnwrap(bars["left"]), 0.125, accuracy: 0.005)
    XCTAssertEqual(bars["top"], 0)
    // A 4:3 picture in a 16:9 clip: 1 / 0.75 on a 16:9 display, plus half a percent.
    XCTAssertEqual(try fixture.suggestion(payload)["kind"] as? String, "factor")
    XCTAssertEqual(try fixture.suggestion(payload)["factor"] as? Double, 1.34)

    // A 16:10 display already shows only 90% of the width, so less zoom hides the same bars.
    fixture.letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1200) }
    payload = try fixture.payload()
    XCTAssertEqual(try fixture.suggestion(payload)["factor"] as? Double, 1.21)
    // A 4:3 display shows exactly the picture.
    fixture.letterbox.viewportProvider = { _ in CGSize(width: 1600, height: 1200) }
    payload = try fixture.payload()
    XCTAssertEqual(try fixture.suggestion(payload)["kind"] as? String, "hidden")
    // A display that cannot be found gives no suggestion at all.
    fixture.letterbox.viewportProvider = { _ in nil }
    XCTAssertNil(try fixture.payload()["suggestion"])
    XCTAssertEqual(fixture.probes.count, 1, "the viewport is read when the snapshot is built, not by looking again")
  }

  func testOnlyFillGetsASuggestion() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(top: 23, bottom: 23) })
    defer { fixture.stop() }
    fixture.letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1080) }
    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .match, factor: 1)])
    _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))

    let payload = try fixture.payload()
    XCTAssertEqual(payload["state"] as? String, "bars", "the bars are still reported")
    XCTAssertNotNil(payload["bars"])
    XCTAssertNil(payload["suggestion"], "a scale factor only crops them in Fill")
    XCTAssertEqual((payload["current"] as? [String: Any])?["scalingMode"] as? String, "match")

    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .fill, factor: 1.25)])
    let fill = try fixture.payload()
    // 23 of 180 rows a side leaves 134 rows: 180 / 134 = 1.3433, plus half a percent is 1.35.
    XCTAssertEqual(try fixture.suggestion(fill)["factor"] as? Double, 1.35)
    XCTAssertEqual((fill["current"] as? [String: Any])?["scalingFactor"] as? Double, 1.25)
  }

  func testOutcomesThatAreNotBarsCarryTheirReason() async throws {
    let cases: [(frames: () -> VideoLetterboxProbe.Frames, state: String, reason: String?)] = [
      ({ LetterboxFixtures.frames() }, "none", nil),
      ({ LetterboxFixtures.frames(top: 22, bottom: 5) }, "uneven", nil),
      ({ LetterboxFixtures.frames(top: 90, bottom: 90) }, "unclear", "dark"),
      ({ LetterboxFixtures.frames(top: 44, bottom: 44) }, "unclear", "implausible"),
      ({ LetterboxFixtures.frames(count: 2) }, "unclear", "fewFrames"),
    ]
    for expected in cases {
      let fixture = try Fixture(frames: expected.frames)
      defer { fixture.stop() }
      _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
      let payload = try fixture.payload()
      XCTAssertEqual(payload["state"] as? String, expected.state)
      XCTAssertEqual(payload["reason"] as? String, expected.reason)
      XCTAssertNil(payload["suggestion"])
    }
  }

  func testFailuresAreReportedByTheirCode() async throws {
    let failures: [(VideoLetterboxProbe.Failure, String)] = [
      (.unreadable("x"), "unreadable"), (.noVideoTrack, "noVideo"), (.timedOut, "timedOut"), (.fileChanged, "changed"),
    ]
    for (failure, code) in failures {
      let fixture = try Fixture(frames: { throw failure })
      defer { fixture.stop() }
      _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
      let payload = try fixture.payload()
      XCTAssertEqual(payload["state"] as? String, "failed")
      XCTAssertEqual(payload["reason"] as? String, code)
    }
  }

  func testResultReadsAsIdleOnceTheLibraryHasBeenRefreshed() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
    XCTAssertEqual(try fixture.payload()["state"] as? String, "bars")

    fixture.bridge.snapshot = BridgeSnapshotBundle(
      app: fixture.store.appSnapshot, library: fixture.store.librarySnapshot,
      wallpaperOptions: fixture.store.wallpaperOptionsSnapshot,
      monitorInformation: fixture.store.monitorInformationSnapshot, settings: fixture.store.settingsSnapshot)
    let before = fixture.store.libraryRefreshRevision
    try await fixture.store.refreshLibraryAsync()
    XCTAssertNotEqual(fixture.store.libraryRefreshRevision, before)
    XCTAssertEqual(try fixture.payload()["state"] as? String, "idle")
    XCTAssertEqual(fixture.probes.count, 1)
  }

  func testSelectingAnotherWallpaperDropsTheCardAndItsResultWaitsForTheRevision() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
    fixture.store.appSnapshot.selectedWallpaperId = "two"
    XCTAssertEqual(try fixture.payload()["wallpaperID"] as? String, "two")
    XCTAssertEqual(try fixture.payload()["state"] as? String, "idle", "two was never checked")
    fixture.store.appSnapshot.selectedWallpaperId = "one"
    XCTAssertEqual(try fixture.payload()["state"] as? String, "bars", "one still has its result")
  }

  private func assertRejected(_ fixture: Fixture, _ body: [String: Any], _ why: String,
                              file: StaticString = #filePath, line: UInt = #line) async {
    do {
      _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(body))
      XCTFail("Must reject: \(why)", file: file, line: line)
    } catch {}
  }

  @MainActor
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-letterbox-\(UUID().uuidString)")
    let defaults: UserDefaults
    let bridge: RefreshingBridge
    let store: BridgeStore
    let controller: WebPanelController
    let letterbox: VideoLetterboxStore
    let probes: Probes

    init(frames: @escaping @Sendable () throws -> VideoLetterboxProbe.Frames = { LetterboxFixtures.frames(top: 23, bottom: 23) }) throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let video = root.appendingPathComponent("video.mp4")
      try Data("x".utf8).write(to: video)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      bridge = RefreshingBridge(noPointer: .init())
      store = BridgeStore(bridge: bridge)
      let counter = Probes()
      probes = counter
      letterbox = VideoLetterboxStore(
        probe: VideoLetterboxProbe(frames: { _ in
          counter.record()
          return try frames()
        }, timeout: .seconds(600)),
        entry: { _, _ in video })
      let navigation = ControlPanelNavigation()
      navigation.targetDisplayID = "7"
      let workshop = WorkshopStore(downloader: WorkshopDownloadManager(sessionDirectory: root),
                                  supportDirectory: root, defaults: defaults)
      controller = WebPanelController(store: store, navigation: navigation, workshop: workshop,
                                     defaults: defaults, appLanguage: .english(), letterbox: letterbox)
      store.appSnapshot.selectedWallpaperId = "one"
      store.librarySnapshot.wallpapers = ["one", "two"].map {
        .init(id: $0, title: $0, kind: .video, supported: true, active: false, selected: $0 == "one", previewPath: nil)
      }
      store.settingsSnapshot.displays = [
        .init(displayId: "7", title: "Display", enabled: true, mode: .standalone, mirrorTargets: [],
              selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
              targetFps: 60, maxFps: 60, muted: false, volume: 1)
      ]
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "one", kind: .video)
      letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1080) }
    }

    func configuration(mode: BridgeScalingMode, factor: Double) -> BridgeDisplayConfigRow {
      BridgeDisplayConfigRow(displayId: "7", title: "Display", enabled: true, scalingMode: mode,
                             scalingFactor: factor, targetFps: 60, maxFps: 60, muted: false, volume: 1,
                             dirty: false, canRestoreDefaults: false)
    }

    func payload() throws -> [String: Any] {
      try XCTUnwrap(controller.letterboxSnapshot())
    }

    func suggestion(_ payload: [String: Any]) throws -> [String: Any] {
      try XCTUnwrap(payload["suggestion"] as? [String: Any])
    }

    func stop() {
      controller.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }
}
