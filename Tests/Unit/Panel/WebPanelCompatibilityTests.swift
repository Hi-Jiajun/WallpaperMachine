import XCTest
@testable import WallpaperMachine

@MainActor
final class WebPanelCompatibilityTests: XCTestCase {
  func testRuntimeReportIsTargetAndWallpaperBoundNotPreference() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    fixture.store.settingsSnapshot.videoBackend = "native_preferred"
    fixture.store.settingsSnapshot.videoBackends = [
      .init(displayId: 7, displayName: "Display", wallpaperId: "one", wallpaperTitle: "One",
            backend: "legacy", fallbackReason: "Target FPS is below content"),
      .init(displayId: 8, displayName: "Other", wallpaperId: "one", wallpaperTitle: "One",
            backend: "native", fallbackReason: nil),
    ]
    var payload = try fixture.payload()
    XCTAssertEqual(payload["backend"] as? String, "legacy")
    XCTAssertEqual(payload["reason"] as? String, "Target FPS is below content")
    fixture.store.settingsSnapshot.videoBackends.removeFirst()
    payload = try fixture.payload()
    XCTAssertNil(payload["backend"], "Another display's native backend cannot certify this target")
    fixture.store.settingsSnapshot.videoBackends = [
      .init(displayId: 7, displayName: "Display", wallpaperId: "two", wallpaperTitle: "Two",
            backend: "native", fallbackReason: nil)
    ]
    XCTAssertNil(try fixture.payload()["backend"], "A previous wallpaper's report cannot leak into this card")
  }

  func testStableSelectorsResolveActualBackendWithoutMatchingAnotherDisplay() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    for selector in ["primary", "identity:{\"uuid\":\"AABB\"}"] {
      fixture.controller.navigation.targetDisplayID = selector
      fixture.store.settingsSnapshot.displays[0].displayId = selector
      fixture.store.settingsSnapshot.displays[0].title = "Studio Display (7 - Primary)"
      fixture.store.settingsSnapshot.videoBackends = [
        .init(displayId: 8, displayName: "Other", wallpaperId: "one", wallpaperTitle: "One",
              backend: "native", fallbackReason: nil),
        .init(displayId: 7, displayName: "Studio", wallpaperId: "one", wallpaperTitle: "One",
              backend: "legacy", fallbackReason: "Target FPS is below content"),
      ]
      let payload = try fixture.payload()
      XCTAssertEqual(payload["backend"] as? String, "legacy")
      XCTAssertEqual(payload["reason"] as? String, "Target FPS is below content")
    }
  }

  func testStaleSelectionAndMirrorTargetRequestsAreRejectedWithoutStartingCheck() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    for body: [String: Any] in [
      ["id": "two", "displayID": "7"],
      ["id": "one", "displayID": "8"],
      ["id": "one", "displayID": true],
    ] {
      do {
        _ = try await fixture.controller.performCompatibility("compatibilityCheck", request: .init(body))
        XCTFail("A stale or invalid target must be rejected")
      } catch {}
    }
    fixture.store.settingsSnapshot.displays[0].mode = .mirror
    do {
      _ = try await fixture.controller.performCompatibility("compatibilityCheck", request: .init(["id": "one", "displayID": "7"]))
      XCTFail("A mirror cannot independently select this wallpaper")
    } catch {}
    XCTAssertFalse(fixture.compatibility.checking)
    XCTAssertEqual(fixture.compatibility.checks, [])
  }

  func testMirrorRateAndGlobalCapInvalidateCheckedContext() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    fixture.store.settingsSnapshot.displays.append(
      .init(displayId: "8", title: "Mirror", enabled: true, mode: .mirror, mirrorTargets: ["7"],
            selectedMirrorTarget: "7", scalingMode: .fill, scalingFactor: 1,
            targetFps: 30, maxFps: 60, muted: false, volume: 1))
    _ = fixture.controller.compatibilitySnapshot()
    XCTAssertEqual(fixture.compatibility.context?.targetFPS, 30)
    fixture.store.settingsSnapshot.frameRateCap = 24
    _ = fixture.controller.compatibilitySnapshot()
    XCTAssertEqual(fixture.compatibility.context?.targetFPS, 24)
  }

  @MainActor
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-compatibility-\(UUID().uuidString)")
    let defaults: UserDefaults
    let store: BridgeStore
    let controller: WebPanelController
    let compatibility: WallpaperCompatibilityStore
    init() throws {
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      store = BridgeStore(bridge: LayoutSnapshotBridge(noPointer: .init()))
      compatibility = WallpaperCompatibilityStore(service: WallpaperCompatibilityService(libraryURL: root))
      let navigation = ControlPanelNavigation()
      navigation.targetDisplayID = "7"
      let workshop = WorkshopStore(downloader: WorkshopDownloadManager(sessionDirectory: root),
                                  supportDirectory: root, defaults: defaults)
      controller = WebPanelController(store: store, navigation: navigation, workshop: workshop,
                                     defaults: defaults, appLanguage: .english(), compatibility: compatibility)
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
    }
    func payload() throws -> [String: Any] {
      try XCTUnwrap(controller.compatibilitySnapshot()["wallpaperCompatibility"] as? [String: Any])
    }
    func stop() {
      controller.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }
}
