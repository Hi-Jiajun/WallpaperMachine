import XCTest

@testable import WallpaperMachine

/// Settings the panel keeps itself rather than handing to the engine, and the General rows
/// that point the user at System Settings.
@MainActor
final class WebPanelGeneralSettingsTests: ControlPanelTestCase {
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

  /// A launch at login the user switched off in System Settings stays off however often the app
  /// registers it. The row must say what the user has to do and offer the way there, and the
  /// native action must open Login Items and nothing else.
  func testLaunchAtLoginNeedsApprovalIsInTheSnapshotAndTheActionOpensLoginItemsOnly() async throws {
    try await withPanel { panel in
      var openedLoginItems = 0
      panel.controller.openLoginItemsSettings = { openedLoginItems += 1 }
      panel.store.settingsSnapshot.launchAtLoginAvailable = true
      panel.store.settingsSnapshot.launchAtLoginEnabled = false
      panel.store.settingsSnapshot.launchAtLoginNeedsApproval = true

      let settings = try XCTUnwrap(panel.controller.snapshot()["settings"] as? [String: Any])
      XCTAssertEqual(settings["launchAtLoginNeedsApproval"] as? Bool, true)
      XCTAssertEqual(
        settings["launchAtLogin"] as? Bool, false, "Waiting for approval is not being enabled")
      XCTAssertEqual(
        settings["launchAtLoginAvailable"] as? Bool, true,
        "The app is installed where it can register, so the switch stays usable")

      try await panel.finishWelcome()
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      _ = try await panel.js("document.querySelector('[data-section=\"general\"]').click()")
      let row = "document.querySelector('.settings-row[data-key=\"launchAtLogin\"]')"
      let rowState = """
        const row = \(row);
        const toggle = row.querySelector('input[type="checkbox"]');
        const described = document.getElementById(toggle.getAttribute('aria-describedby') || '');
        return {
          note: described?.textContent.trim() ?? '',
          button: row.querySelector('[data-action="openLoginItemsSettings"]') !== null,
          usable: !toggle.disabled, checked: toggle.checked,
        };
        """
      try await panel.waitJS("\(row)?.querySelector('[data-action=\"openLoginItemsSettings\"]')")

      let waitingPage = try await panel.js(rowState) as? [String: Any]
      let waiting = try XCTUnwrap(waitingPage)
      XCTAssertEqual(waiting["button"] as? Bool, true)
      XCTAssertEqual(waiting["usable"] as? Bool, true)
      XCTAssertEqual(waiting["checked"] as? Bool, false)
      XCTAssertFalse((waiting["note"] as? String ?? "").isEmpty, "The row must say what to do")

      _ = try await panel.js("\(row).querySelector('[data-action=\"openLoginItemsSettings\"]').click()")
      try await panel.waitUntil { openedLoginItems == 1 }
      try await panel.quiet()
      XCTAssertEqual(openedLoginItems, 1, "One click opens Login Items once")

      // The user allows it in System Settings and comes back to the panel. Nothing else asks the
      // bridge, so the return itself has to read the status again and drop the prompt.
      var granted = panel.store.settingsSnapshot
      granted.launchAtLoginEnabled = true
      granted.launchAtLoginNeedsApproval = false
      panel.reportFromBridge(granted)
      panel.controller.windowStateChanged(NSWindow.didBecomeKeyNotification)
      try await panel.waitUntil { !panel.store.settingsSnapshot.launchAtLoginNeedsApproval }
      try await panel.waitJS("powerProbe.received.at(-1)?.settings?.launchAtLoginNeedsApproval === false")
      try await panel.waitJS("!\(row).querySelector('[data-action=\"openLoginItemsSettings\"]')")
      let allowedPage = try await panel.js(rowState) as? [String: Any]
      let allowed = try XCTUnwrap(allowedPage)
      XCTAssertEqual(allowed["button"] as? Bool, false)
      XCTAssertEqual(allowed["checked"] as? Bool, true)
      XCTAssertEqual(allowed["note"] as? String, "", "Nothing is left to explain once it is enabled")
      XCTAssertEqual(openedLoginItems, 1)
    }
  }

  /// Returning to the panel costs a bridge round trip only while a Login Items note is waiting
  /// to be cleared; a panel with nothing pending does not re-read the bridge on every focus.
  func testReturningToThePanelReadsTheBridgeOnlyWhileAnApprovalIsPending() async throws {
    try await withPanel { panel in
      panel.store.settingsSnapshot.launchAtLoginAvailable = true
      panel.reportFromBridge(panel.store.settingsSnapshot)

      panel.controller.windowStateChanged(NSWindow.didBecomeKeyNotification)
      try await panel.quiet()
      XCTAssertEqual(panel.bridge.snapshotReads, 0, "Nothing is waiting for approval")

      var waiting = panel.store.settingsSnapshot
      waiting.launchAtLoginNeedsApproval = true
      panel.store.settingsSnapshot = waiting
      panel.reportFromBridge(waiting)
      panel.controller.windowStateChanged(NSWindow.didDeminiaturizeNotification)
      try await panel.quiet()
      XCTAssertEqual(panel.bridge.snapshotReads, 0, "Only becoming key counts as returning to the panel")

      panel.controller.windowStateChanged(NSWindow.didBecomeKeyNotification)
      panel.controller.windowStateChanged(NSWindow.didBecomeKeyNotification)
      try await panel.waitUntil { panel.bridge.snapshotReads >= 1 }
      try await panel.quiet()
      XCTAssertEqual(
        panel.bridge.snapshotReads, 1, "Focus changes in a row share the read that is in flight")
    }
  }

  /// The first-run guide offers the same switch, so a login item waiting for approval must be
  /// explained there too, without disabling the switch the way a copy outside Applications is.
  func testFirstRunPreferencesExplainAPendingLoginItemApproval() async throws {
    try await withPanel { panel in
      panel.store.settingsSnapshot.launchAtLoginAvailable = true
      panel.show()
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"go\"][data-step=\"3\"]').click()")
      let row = "document.querySelector('#welcome .welcome-pref[data-key=\"pref-launchAtLogin\"]')"
      let rowState = """
        const row = \(row);
        return {
          note: row.querySelector('.welcome-pref-note').textContent.trim(),
          usable: !row.querySelector('input').disabled,
        };
        """
      panel.store.snapshotRevision &+= 1
      try await panel.waitJS("powerProbe.received.at(-1)?.settings?.launchAtLoginAvailable === true")
      let plainPage = try await panel.js(rowState) as? [String: Any]
      let plain = try XCTUnwrap(plainPage)

      panel.store.settingsSnapshot.launchAtLoginNeedsApproval = true
      panel.store.snapshotRevision &+= 1
      try await panel.waitJS("powerProbe.received.at(-1)?.settings?.launchAtLoginNeedsApproval === true")
      try await panel.waitJS("\(row).querySelector('.welcome-pref-note').textContent.trim().length > \((plain["note"] as? String ?? "").count)")
      let waitingPage = try await panel.js(rowState) as? [String: Any]
      let waiting = try XCTUnwrap(waitingPage)

      XCTAssertEqual(plain["usable"] as? Bool, true)
      XCTAssertEqual(
        waiting["usable"] as? Bool, true,
        "Approval is something the user does in System Settings; the switch is not disabled")
      let plainNote = try XCTUnwrap(plain["note"] as? String)
      let waitingNote = try XCTUnwrap(waiting["note"] as? String)
      XCTAssertTrue(
        waitingNote.hasPrefix(plainNote) && waitingNote.count > plainNote.count,
        "The row keeps its own description and adds what the user has to do")
    }
  }
}
