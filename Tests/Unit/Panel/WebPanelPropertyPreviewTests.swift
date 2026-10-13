import XCTest

@testable import WallpaperMachine

/// Showing a wallpaper's pending property edits on the desktop: which panel edits reach the
/// bridge's property preview and when, and what Revert, Apply, deleting a wallpaper and turning
/// the choice off do about edits already shown. The bridge is a double that records what the
/// displays were asked to show; whether a display really follows is a desktop check, not one made
/// here, and so is the bridge's own bookkeeping, which its Rust tests cover.
@MainActor
final class WebPanelPropertyPreviewTests: XCTestCase {
  func testAnEditWithTheSwitchOnReachesTheBridgeOnceAfterTheDebounceAndNeverWithItOff() async throws {
    let context = try Context()
    defer { context.tearDown() }

    for value in [true, false, true] { try await context.edit(value) }
    await context.settle()
    XCTAssertTrue(context.sleeper.requested.isEmpty, "with the choice off an edit does not even start to wait")
    XCTAssertTrue(context.bridge.previews.isEmpty)

    try await context.switchOn()
    for value in [false, true, false] { try await context.edit(value) }
    await context.settle()
    XCTAssertTrue(context.bridge.previews.isEmpty, "nothing is shown until the edits pause")
    await context.letTheEditsPause()
    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp", show: true)],
      "a burst of edits costs the displays one update, and it asks for the pending edits, not a value")
    XCTAssertEqual(context.bridge.options["wp"]?.dirty, true, "showing an edit does not apply it")
    XCTAssertFalse(context.bridge.events.contains("apply wp"))
  }

  func testEveryWayToEditThePendingPropertiesIsFollowed() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()

    try await context.edit(true)
    await context.letTheEditsPause()
    try await context.controller.perform("restoreProperty", body: ["id": "wp", "propertyID": "mode"])
    await context.letTheEditsPause()
    try await context.controller.perform("restoreAllProperties", body: ["id": "wp"])
    await context.letTheEditsPause()
    try await context.store.setPropertyPathAsync(wallpaperId: "wp", propertyId: "mode", path: "/tmp/picture.png")
    await context.letTheEditsPause()

    XCTAssertEqual(
      context.bridge.previews.count, 4,
      "an edit, a restored default, every default restored and a chosen file each show the draft again")
  }

  func testApplyCancelsAPendingPushAndRevertLeavesRestoringToTheBridge() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()

    try await context.edit(true)
    await context.settle()
    XCTAssertEqual(context.sleeper.pendingCount, 1, "the edit is waiting to be shown")
    try await context.controller.perform("apply", body: ["id": "wp"])
    await context.letTheEditsPause()
    XCTAssertTrue(context.bridge.previews.isEmpty, "the wallpaper loads from what is saved; showing the edit first is moot")
    XCTAssertEqual(context.bridge.events, ["edit wp", "apply wp"])

    try await context.edit(false)
    await context.letTheEditsPause()
    XCTAssertEqual(context.bridge.previews, [.init(wallpaperID: "wp", show: true)])
    try await context.edit(true)
    await context.settle()
    XCTAssertEqual(context.sleeper.pendingCount, 1)
    try await context.controller.perform("revert", body: ["id": "wp"])
    await context.letTheEditsPause()
    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp", show: true)],
      "the bridge puts the saved look back when it cancels the edit, so the app asks for nothing more")
    XCTAssertEqual(Array(context.bridge.events.suffix(2)), ["edit wp", "cancel wp"])

    try await context.switchOff()
    XCTAssertEqual(context.bridge.previews.count, 1, "after a Revert there is nothing left to take back")
  }

  func testTheTextApplyCommitsStartsNoUpdateOfItsOwn() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    context.store.editorState.setPropertyText("hello", key: .init(wallpaperID: "wp", fieldID: "note"))

    try await context.controller.perform("apply", body: ["id": "wp"])
    await context.letTheEditsPause()

    XCTAssertEqual(context.bridge.events, ["edit wp", "apply wp"], "Apply sent the text it held")
    XCTAssertTrue(context.sleeper.requested.isEmpty, "an edit made by Apply itself shows nothing before it loads the result")
    XCTAssertTrue(context.bridge.previews.isEmpty)
  }

  func testTurningTheSwitchOffRestoresEveryWallpaperItPreviewed() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    try await context.edit(true, id: "wp2")
    try await context.edit(true, id: "wp")
    await context.letTheEditsPause()
    XCTAssertEqual(Set(context.bridge.previews), [.init(wallpaperID: "wp", show: true), .init(wallpaperID: "wp2", show: true)])
    context.bridge.previews = []

    try await context.edit(false, id: "wp")
    await context.settle()
    XCTAssertEqual(context.sleeper.pendingCount, 1, "an update is waiting when the switch goes off")
    try await context.switchOff()
    await context.letTheEditsPause()

    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp", show: false), .init(wallpaperID: "wp2", show: false)],
      "each wallpaper that was shown an edit gets the saved look back, and the waiting update is dropped")
    XCTAssertEqual(context.bridge.options["wp"]?.dirty, true, "the edits stay pending in the inspector")

    try await context.switchOff()
    XCTAssertEqual(context.bridge.previews.count, 2, "what was put back is not asked for again")
    try await context.edit(true)
    await context.letTheEditsPause()
    XCTAssertEqual(context.bridge.previews.count, 2, "and with the switch off an edit stays off the desktop")
  }

  func testAWallpaperThatWasAppliedOrDeletedIsNotAskedToGoBack() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    for id in ["wp", "wp2", "wp3"] { try await context.edit(true, id: id) }
    await context.letTheEditsPause()
    XCTAssertEqual(context.bridge.previews.count, 3)
    context.bridge.previews = []

    try await context.controller.perform("apply", body: ["id": "wp"])
    let report = try await context.store.deleteWallpapersAsync(ids: ["wp2"], recycle: { _ in })
    XCTAssertEqual(report.deleted, ["wp2"])
    try await context.switchOff()

    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp3", show: false)],
      "an applied wallpaper loaded its edits from what is saved and a deleted one is gone; only the pending one is put back")
  }

  func testTheDisplaysDrawingAnEditAreKnownUntilTheEditEnds() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.showWallpapersOnDisplays()
    var ended = 0
    context.store.onPropertyEditsOnDesktopEnded = { ended += 1 }

    try await context.edit(true)
    await context.letTheEditsPause()
    XCTAssertEqual(context.displaysShowingEdits(), [], "with the choice off no display draws an edit")

    try await context.switchOn()
    try await context.edit(false)
    await context.settle()
    XCTAssertEqual(context.displaysShowingEdits(), [], "an edit waiting for its quiet period is not on a display yet")
    await context.letTheEditsPause()
    XCTAssertEqual(
      context.displaysShowingEdits(), ["1", "2"],
      "the display showing the wallpaper and the one mirroring it, not the one showing another wallpaper")
    XCTAssertEqual(ended, 0)

    try await context.controller.perform("revert", body: ["id": "wp"])
    XCTAssertEqual(context.displaysShowingEdits(), [], "Revert put the saved look back")
    XCTAssertEqual(ended, 1, "and whatever withheld the desktop's picture is told to take it")

    try await context.controller.perform("revert", body: ["id": "wp"])
    XCTAssertEqual(ended, 1, "a wallpaper nothing was shown of has nothing to take again")

    try await context.edit(true)
    await context.letTheEditsPause()
    XCTAssertEqual(context.displaysShowingEdits(), ["1", "2"])
    try await context.controller.perform("apply", body: ["id": "wp"])
    XCTAssertEqual(context.displaysShowingEdits(), [], "Apply loads the saved look")
    XCTAssertEqual(ended, 2)
  }

  func testTurningTheSwitchOffOrDeletingAWallpaperLetsItsDisplaysGo() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.showWallpapersOnDisplays()
    var ended = 0
    context.store.onPropertyEditsOnDesktopEnded = { ended += 1 }
    try await context.switchOn()
    for id in ["wp", "wp2", "wp3"] { try await context.edit(true, id: id) }
    await context.letTheEditsPause()
    XCTAssertEqual(context.displaysShowingEdits(), ["1", "2", "3"])

    // wp3 is on no display, so deleting it needs no eject.
    let report = try await context.store.deleteWallpapersAsync(ids: ["wp3"], recycle: { _ in })
    XCTAssertEqual(report.deleted, ["wp3"])
    XCTAssertEqual(ended, 1)

    context.bridge.previewFailure = Refused()
    try await context.switchOff()
    XCTAssertEqual(context.displaysShowingEdits(), ["1", "2", "3"], "a wallpaper the bridge could not put back may still be drawing its edit")
    XCTAssertEqual(ended, 1)

    context.bridge.previewFailure = nil
    try await context.switchOff()
    XCTAssertEqual(context.displaysShowingEdits(), [])
    XCTAssertGreaterThan(ended, 1)
  }

  func testAnUpdateThatOutlivesTheSwitchIsDropped() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    try await context.edit(true)
    await context.settle()
    XCTAssertEqual(context.sleeper.pendingCount, 1)

    // Turned off from somewhere that does not go through the panel's action.
    LivePropertyEditing.setEnabled(false, defaults: context.defaults, center: NotificationCenter())
    await context.letTheEditsPause()

    XCTAssertTrue(context.bridge.previews.isEmpty, "the choice is read when the update is due, not only when the edit was made")
  }

  func testOnlyScenesAreShownOnTheDesktop() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()

    for id in ["web", "clip"] { try await context.edit(true, id: id) }
    await context.letTheEditsPause()

    XCTAssertTrue(context.sleeper.requested.isEmpty, "a web page and a video have nothing for the desktop to follow")
    XCTAssertTrue(context.bridge.previews.isEmpty)
    XCTAssertEqual(context.bridge.events, ["edit web", "edit clip"])
  }

  func testAPreviewFailureIsLoggedNotShown() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    context.bridge.previewFailure = Refused()

    try await context.edit(true)
    await context.letTheEditsPause()

    XCTAssertEqual(context.bridge.previews.count, 1, "the bridge was asked")
    XCTAssertEqual(context.log.count, 1, "and its refusal went to the log")
    XCTAssertTrue(context.log.first?.contains("wp") == true, "naming the wallpaper")
    XCTAssertNil(context.store.latestBridgeErrorMessage, "an edit in progress is not interrupted by an alert")
    XCTAssertEqual(context.bridge.options["wp"]?.dirty, true, "the edit itself is untouched")

    context.bridge.previewFailure = nil
    try await context.edit(false)
    await context.letTheEditsPause()
    XCTAssertEqual(context.bridge.previews.count, 2, "the next edit tries again")
    XCTAssertEqual(context.log.count, 1)
  }

  func testASwitchOffTheBridgeRefusesIsAskedAgainTheNextTime() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    try await context.edit(true)
    await context.letTheEditsPause()
    context.bridge.previews = []

    context.bridge.previewFailure = Refused()
    try await context.switchOff()
    XCTAssertEqual(context.bridge.previews, [.init(wallpaperID: "wp", show: false)])
    XCTAssertEqual(context.log.count, 1, "the refusal is logged and the switch still goes off")
    XCTAssertFalse(LivePropertyEditing.isEnabled(defaults: context.defaults))

    context.bridge.previewFailure = nil
    try await context.switchOff()
    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp", show: false), .init(wallpaperID: "wp", show: false)],
      "a wallpaper that could not be put back stays marked until it can")
    try await context.switchOff()
    XCTAssertEqual(context.bridge.previews.count, 2)
  }

  // MARK: Doubles

  private struct Refused: Error {}

  /// The panel's controller over a store whose bridge keeps each wallpaper's pending state the way
  /// the engine does and records the order of what it was asked.
  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-property-preview-\(UUID().uuidString)")
    let previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    let defaults: UserDefaults
    let bridge = PreviewBridge(noPointer: .init())
    let sleeper = ManualSleeper()
    let store: BridgeStore
    let controller: WebPanelController
    /// What the store sent to its log.
    var log: [String] = []

    init() throws {
      setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      store = BridgeStore(bridge: bridge)
      bridge.store = store
      // Applying validates the wallpaper's files; a web page is the cheapest project that passes.
      // The kind the options report is what decides whether the desktop can show an edit.
      let kinds: [(String, BridgeWallpaperKind)] = [
        ("wp", .projectScene), ("wp2", .projectScene), ("wp3", .projectScene), ("web", .webpage), ("clip", .video),
      ]
      for (id, kind) in kinds {
        let project = ClientPaths.libraryURL.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"type":"web","file":"index.html"}"#.utf8).write(to: project.appendingPathComponent("project.json"))
        try Data("<!doctype html>".utf8).write(to: project.appendingPathComponent("index.html"))
        bridge.options[id] = BridgeSnapshotFixtures.options(
          wallpaperId: id, title: id, kind: kind, properties: [Self.property("mode", .bool, .bool(value: false)),
                                                                Self.property("note", .textInput, .string(value: ""))])
      }
      store.librarySnapshot.wallpapers = kinds.map {
        BridgeWallpaperEntry(
          id: $0.0, title: $0.0, kind: $0.1, supported: true, active: false, selected: false, previewPath: nil)
      }
      store.wallpaperOptionsSnapshot = bridge.options["wp"]
      let defaults = defaults
      store.showsPropertyEditsOnDesktop = { LivePropertyEditing.isEnabled(defaults: defaults) }
      store.desktopPropertyPreviews = PropertyPreviewScheduler(delay: .milliseconds(150), sleep: sleeper.closure)
      let workshop = WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root, defaults: defaults)
      controller = WebPanelController(
        store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
        appLanguage: .english())
      store.desktopPropertyPreviewLog = { [unowned self] in log.append($0) }
    }

    func tearDown() {
      controller.stop()
      store.desktopPropertyPreviews.cancelAll()
      if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
      try? FileManager.default.removeItem(at: root)
    }

    /// The inspector flips a switch property.
    func edit(_ value: Bool, id: String = "wp") async throws {
      try await controller.perform("property", body: ["id": id, "propertyID": "mode", "value": value])
    }

    func switchOn() async throws {
      try await controller.perform("setting", body: ["key": "livePropertyEdits", "value": true])
    }

    func switchOff() async throws {
      try await controller.perform("setting", body: ["key": "livePropertyEdits", "value": false])
    }

    /// Displays 1 and 2 show "wp" (2 mirrors 1), display 3 shows "wp2" and display 4 shows nothing.
    func showWallpapersOnDisplays() {
      func row(_ id: String, _ title: String, _ wallpaper: String, mirroring target: String? = nil) -> BridgeMonitorInfoRow {
        BridgeMonitorInfoRow(
          displayId: id, title: title, wallpaperId: wallpaper, wallpaperTitle: wallpaper, mirrorTargetDisplayId: target,
          mirrorTargetTitle: nil, scalingMode: "fill", targetFps: "30", audioResponse: false)
      }
      store.monitorInformationSnapshot = BridgeMonitorInformationSnapshot(rows: [
        row("1", "Left (1 - Primary)", "wp"),
        row("2", "Right (2 - Mirror)", "wp", mirroring: "1"),
        row("3", "Other (3 - Secondary)", "wp2"),
        row("4", "Empty (4 - Secondary)", ""),
      ])
    }

    /// The displays of `showWallpapersOnDisplays` that the Mission Control picture is not taken from.
    func displaysShowingEdits() -> [String] {
      ["1", "2", "3", "4"].filter { store.isShowingPropertyEdits(onDisplay: $0) }
    }

    func settle() async { for _ in 0..<60 { await Task.yield() } }

    /// Lets the quiet period pass, once for every time an edit started it over.
    func letTheEditsPause() async {
      for _ in 0..<8 {
        await settle()
        if sleeper.finishWaits() == 0 { break }
      }
      await settle()
    }

    private static func property(_ id: String, _ kind: BridgePropertyKind, _ value: BridgePropertyValue) -> BridgePropertyDescriptor {
      BridgePropertyDescriptor(
        id: id, kind: kind, labelHtml: id, value: value, defaultValue: value, slider: nil, comboOptions: [],
        fileFilter: nil, directoryMode: nil, dirty: false, canRestoreDefaults: true, enabled: true,
        assetManaged: false, assetMissing: false, assetSourcePath: nil)
    }
  }
}

/// Answers a wallpaper's options as the engine would after each call and records, in order, what the
/// panel and the store asked of the displays and of the draft.
private final class PreviewBridge: WallpaperBridge {
  struct Preview: Hashable {
    var wallpaperID: String
    var show: Bool
  }

  @MainActor weak var store: BridgeStore?
  @MainActor var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
  /// What the displays were asked to show, in order.
  @MainActor var previews: [Preview] = []
  /// Edits, reverts and applies the bridge received, in order, as "edit wp".
  @MainActor var events: [String] = []
  @MainActor var previewFailure: Error?

  override func wallpaperOptionsSnapshot(wallpaperId: String) async throws -> BridgeWallpaperOptionsSnapshot {
    try await current(wallpaperId)
  }

  override func editProperty(wallpaperId: String, propertyId: String, value: BridgePropertyValue) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await reply("edit", wallpaperId, dirty: true)
  }

  override func setPropertyPath(wallpaperId: String, propertyId: String, path: String?) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await reply("path", wallpaperId, dirty: true)
  }

  override func restorePropertyDefault(wallpaperId: String, propertyId: String) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await reply("restore", wallpaperId, dirty: true)
  }

  override func restoreAllPropertyDefaults(wallpaperId: String) async throws -> BridgeWallpaperMutationBundle {
    try await reply("restoreAll", wallpaperId, dirty: true)
  }

  override func cancelWallpaperOptions(wallpaperId: String) async throws -> BridgeWallpaperMutationBundle {
    try await reply("cancel", wallpaperId, dirty: false)
  }

  override func applyWallpaperOptions(wallpaperId: String, userInitiated: Bool) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await reply("apply", wallpaperId, dirty: false)
  }

  override func previewWallpaperProperties(wallpaperId: String, show: Bool) async throws {
    try await receivePreview(Preview(wallpaperID: wallpaperId, show: show))
  }

  override func refreshLibrary() async throws -> BridgeSnapshotBundle {
    try await library()
  }

  @MainActor private func current(_ id: String) throws -> BridgeWallpaperOptionsSnapshot {
    guard let options = options[id] else { throw CancellationError() }
    return options
  }

  @MainActor private func receivePreview(_ preview: Preview) throws {
    previews.append(preview)
    if let previewFailure { throw previewFailure }
  }

  /// The engine's reply to a call that changes the draft: the wallpaper's options afterwards.
  /// Only a call that edits is recorded under its name; the others do not matter to a test.
  @MainActor private func reply(_ event: String, _ id: String, dirty: Bool) throws -> BridgeWallpaperMutationBundle {
    if ["edit", "cancel", "apply"].contains(event) { events.append("\(event) \(id)") }
    var changed = try current(id)
    changed.dirty = dirty
    options[id] = changed
    let store = try XCTUnwrap(store)
    return BridgeWallpaperMutationBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: changed,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }

  @MainActor private func library() throws -> BridgeSnapshotBundle {
    let store = try XCTUnwrap(store)
    return BridgeSnapshotBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }
}
