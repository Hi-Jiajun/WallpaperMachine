import XCTest

@testable import WallpaperMachine

/// Settings the panel keeps itself rather than handing to the engine.
@MainActor
final class WebPanelGeneralSettingsTests: XCTestCase {
  /// Controllers that share one preferences suite, the way a relaunch does.
  @MainActor private struct Panel {
    let defaults: UserDefaults
    let root: URL
    let workshop: WorkshopStore
    func makeController() -> WebPanelController {
      WebPanelController(
        store: BridgeStore(bridge: WallpaperBridge(noPointer: .init())),
        navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
        appLanguage: .english())
    }
  }

  private func makePanel() throws -> Panel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-general-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    return Panel(defaults: defaults, root: root, workshop: workshop)
  }

  func testHidingAfterApplyingIsOffUntilTurnedOnAndPersists() async throws {
    let panel = try makePanel()
    let controller = panel.makeController()
    defer { controller.stop() }

    XCTAssertFalse(controller.hidesAfterActivating, "The panel stays open after applying unless the user opts in")
    try await controller.perform("setting", body: ["key": "hideAfterActivating", "value": true])
    XCTAssertTrue(controller.hidesAfterActivating)

    let reopened = panel.makeController()
    defer { reopened.stop() }
    XCTAssertTrue(reopened.hidesAfterActivating, "The choice must survive a relaunch")
  }

  func testInspectingWebWallpapersIsStoredReportedAndSurvivesARelaunch() async throws {
    let panel = try makePanel()
    let controller = panel.makeController()
    defer { controller.stop() }
    func reported(_ controller: WebPanelController) throws -> Bool? {
      let settings = try XCTUnwrap(controller.snapshot()["settings"] as? [String: Any])
      return settings["inspectWebWallpapers"] as? Bool
    }

    // Both directions are written: a debug build starts on, a release build off.
    try await controller.perform("setting", body: ["key": "inspectWebWallpapers", "value": true])
    XCTAssertTrue(WebWallpaperInspection.isEnabled(defaults: panel.defaults))
    XCTAssertEqual(try reported(controller), true)

    try await controller.perform("setting", body: ["key": "inspectWebWallpapers", "value": false])
    XCTAssertFalse(WebWallpaperInspection.isEnabled(defaults: panel.defaults))
    XCTAssertEqual(try reported(controller), false)

    let reopened = panel.makeController()
    defer { reopened.stop() }
    XCTAssertEqual(try reported(reopened), false, "turning inspection off must stick after a relaunch")
    try await reopened.perform("setting", body: ["key": "inspectWebWallpapers", "value": true])
    let third = panel.makeController()
    defer { third.stop() }
    XCTAssertEqual(try reported(third), true)
  }
}
