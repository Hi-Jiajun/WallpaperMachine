import WebKit
import XCTest

@testable import WallpaperMachine

@MainActor
final class WebWallpaperHostLifecycleTests: XCTestCase {
  private final class PointerMonitor: WebWallpaperPointerMonitoring {
    var isActive = false
    func setActive(_ active: Bool) { isActive = active }
  }

  private final class Surface: WebWallpaperSurface {
    let page: WebWallpaperPage
    var frame: NSRect
    var posterLayer: CALayer? = CALayer()
    /// Hosts the page the way `WebWallpaperWindow` does when asked to, so a
    /// suspension can detach the view; otherwise the page has no container.
    private var container: NSView?
    init(_ frame: NSRect, _ page: WebWallpaperPage, attached: Bool = false) {
      self.frame = frame
      self.page = page
      page.webView.setFrameSize(frame.size)
      if attached {
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        page.attach(to: container)
        self.container = container
        posterLayer = container.layer
      }
    }
    func setScreenFrame(_ frame: NSRect) { self.frame = frame }
    func present() {}
    func retire() {}
  }

  private final class Model {
    var surfaces: [Surface] = []
    var states: [HostWallpaperState] = []
    var clock: TimeInterval = 0
    var revision: UInt64 = 0
    var refuseAudio = false
    var refreshRate = 60
    var subscriptions: [Bool] = []
    var deliveryChanges = 0
    var surfaceChanges = 0
    /// What the bridge would answer `reconcile()` with.
    var served: [BridgeWebWallpaper] = []
  }

  @MainActor private final class Fixture {
    let root: URL
    let model = Model()
    let host: WebWallpaperHost
    let pump = WebWallpaperAudioPump(read: { nil })
    let defaults: UserDefaults
    let center = NotificationCenter()
    init(attachedSurfaces: Bool = false, pageTiming: WebWallpaperPage.Timing = .init()) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try "<!doctype html><script>window.contentVersion = 1</script>".write(
        to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      let model = model
      host = WebWallpaperHost(fetch: { model.served },
        screens: { [(UInt32(7), NSRect(x: 0, y: 0, width: 320, height: 200))] },
        refreshRate: { _ in model.refreshRate },
        frameCenter: center,
        audioPump: pump, setAudioSubscribed: { _, _, subscribed in
          model.subscriptions.append(subscribed)
          if model.refuseAudio && subscribed { throw CancellationError() }
        }, imagePlacement: StillImagePlacementStore(defaults: defaults, library: root),
        pointerMonitor: PointerMonitor(), pageTiming: pageTiming, audioClock: { model.clock },
        contentRevision: { model.revision }, makeSurface: { frame, page in
          let surface = Surface(frame, page, attached: attachedSurfaces)
          model.surfaces.append(surface)
          return surface
        })
      host.onStateChanged = { model.states.append($0) }
      host.onDeliveryStateChanged = { model.deliveryChanges += 1 }
      host.onSurfacesChanged = { model.surfaceChanges += 1 }
    }
    var descriptor: BridgeWebWallpaper {
      .init(displayId: 7, startupRevision: 3, displayKey: "primary", audioSourceDisplayId: 7,
        wallpaperId: "wallpaper", title: "Test", projectPath: root.path, entryFile: "index.html",
        fps: 30, renderScale: 1, paused: false, volume: 1, muted: false, audioResponseEnabled: true,
        mediaIntegrationEnabled: false, propertiesJson: "{}")
    }
    func close() {
      host.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
      guard Date() < deadline else { throw NSError(domain: "WebHostFixture", code: 1) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func registerAudio(_ page: WebWallpaperPage) async throws {
    _ = try await page.webView.callAsyncJavaScript(
      "window.wallpaperRegisterAudioListener(bins => { window.lastAudio = bins[0]; });",
      arguments: [:], in: nil, contentWorld: .page)
  }

  func testStartupFailureRetryAndLateCallbacksKeepSurfaceIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    await fixture.host.apply([fixture.descriptor])
    let page = try XCTUnwrap(fixture.model.surfaces.last?.page)
    XCTAssertNil(page.webView.window)
    XCTAssertEqual(fixture.model.states.first?.phase, .loading)
    try await wait { fixture.model.states.last?.phase == .ready }
    XCTAssertEqual(fixture.model.states.last?.startupRevision, 3)
    XCTAssertEqual(fixture.model.states.last?.canRetry, false)
    page.webView(page.webView, didFail: nil, withError: NSError(domain: "fixture", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "late load failure"]))
    XCTAssertEqual(fixture.model.states.last?.phase, .failed)
    XCTAssertEqual(fixture.model.states.last?.canRetry, true)
    fixture.host.retry(wallpaperID: "another", displayID: 7)
    XCTAssertEqual(fixture.model.states.last?.phase, .failed)
    fixture.host.retry(wallpaperID: "wallpaper", displayID: 7)
    XCTAssertEqual(fixture.model.states.last?.phase, .loading)
    XCTAssertEqual(fixture.model.states.last?.canRetry, false)
    try await wait { fixture.model.states.last?.phase == .ready }
    let staleFailure = page.onFailure
    try "<!doctype html><script>window.contentVersion = 2</script>".write(
      to: fixture.root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    fixture.model.revision += 1
    var replacement = fixture.descriptor
    replacement.wallpaperId = "replacement"
    replacement.startupRevision = 4
    await fixture.host.apply([replacement])
    let count = fixture.model.states.count
    staleFailure?("retired document")
    XCTAssertEqual(fixture.model.states.count, count)
    XCTAssertEqual(fixture.model.states.last?.wallpaperID, "replacement")
  }

  func testFailuresBeforePageCreationDoNotOfferRetry() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    var invalidEntry = fixture.descriptor
    invalidEntry.entryFile = "../outside.html"
    var missingProject = fixture.descriptor
    missingProject.projectPath = fixture.root.appendingPathComponent("missing").path
    for descriptor in [invalidEntry, missingProject] {
      await fixture.host.apply([descriptor])
      XCTAssertTrue(fixture.model.surfaces.isEmpty)
      XCTAssertEqual(fixture.model.states.last?.phase, .failed)
      XCTAssertEqual(fixture.model.states.last?.canRetry, false)
      let count = fixture.model.states.count
      fixture.host.retry(wallpaperID: descriptor.wallpaperId, displayID: descriptor.displayId)
      XCTAssertEqual(fixture.model.states.count, count)
    }
  }

  func testProjectScanFailureDoesNotRetryAnOlderLivePage() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    await fixture.host.apply([fixture.descriptor])
    try await wait { fixture.model.states.last?.phase == .ready }
    try FileManager.default.removeItem(at: fixture.root)
    fixture.model.revision += 1
    await fixture.host.apply([fixture.descriptor])
    XCTAssertEqual(fixture.model.states.last?.phase, .failed)
    XCTAssertEqual(fixture.model.states.last?.canRetry, false)
    let count = fixture.model.states.count
    fixture.host.retry(wallpaperID: "wallpaper", displayID: 7)
    XCTAssertEqual(fixture.model.states.count, count)
    XCTAssertEqual(fixture.model.surfaces.count, 1)
  }

  func testSamePathRefreshLoadsNewBytesButAnUnchangedRefreshReusesThePage() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    await fixture.host.apply([fixture.descriptor])
    let first = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { first.isLoaded }
    fixture.model.revision += 1
    await fixture.host.apply([fixture.descriptor])
    XCTAssertEqual(fixture.model.surfaces.count, 1)
    try "<!doctype html><script>window.contentVersion = 2</script>".write(
      to: fixture.root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    fixture.model.revision += 1
    // Only the final descriptor is observed; there is no intermediate empty assignment.
    await fixture.host.apply([fixture.descriptor])
    XCTAssertEqual(fixture.model.surfaces.count, 2)
    let second = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { second.isLoaded }
    XCTAssertNil(second.webView.window)
    let version = try await second.webView.callAsyncJavaScript("return window.contentVersion",
      arguments: [:], in: nil, contentWorld: .page) as? Int
    XCTAssertEqual(version, 2)
    fixture.model.revision += 1
    await fixture.host.apply([fixture.descriptor])
    XCTAssertEqual(fixture.model.surfaces.count, 2)
  }

  /// WebKit fixes a page's drawing cadence when its web view is created, so a
  /// frame rate that reaches or leaves the display's refresh rebuilds the page,
  /// and a change on the same side of it keeps the running document.
  func testFrameRateCrossingTheDisplayRefreshRebuildsThePage() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    fixture.model.refreshRate = 120
    var descriptor = fixture.descriptor
    descriptor.fps = 60
    await fixture.host.apply([descriptor])
    let first = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { first.isLoaded }
    descriptor.fps = 90
    await fixture.host.apply([descriptor])
    XCTAssertEqual(fixture.model.surfaces.map(\.page.rendersAtDisplayRefresh), [false])
    descriptor.fps = 120
    await fixture.host.apply([descriptor])
    XCTAssertEqual(fixture.model.surfaces.map(\.page.rendersAtDisplayRefresh), [false, true])
    let fast = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { fast.isLoaded }
    descriptor.paused = true
    await fixture.host.apply([descriptor])
    XCTAssertEqual(fixture.model.surfaces.count, 2)
    // A lower ceiling, such as the battery frame rate, must not leave the page
    // drawing at the full refresh.
    descriptor.fps = 30
    await fixture.host.apply([descriptor])
    XCTAssertEqual(fixture.model.surfaces.map(\.page.rendersAtDisplayRefresh), [false, true, false])
  }

  func testOnlyAFrameRateThatReachesAFastDisplaysRefreshDrawsAtIt() {
    let cases: [(fps: UInt32, refresh: Int, expected: Bool)] = [
      (60, 120, false), (119, 120, false), (120, 120, true), (144, 144, true), (90, 90, true),
      (60, 60, false), (48, 48, false), (60, 0, false),
    ]
    for (fps, refresh, expected) in cases {
      XCTAssertEqual(
        WebWallpaperHost.rendersAtDisplayRefresh(fps: fps, refreshRate: refresh), expected,
        "\(fps) fps on a \(refresh) Hz display")
    }
  }

  func testAudioNeedsConfirmationAndSuccessfulDeliveryAndExpires() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    await fixture.host.apply([fixture.descriptor])
    let page = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { page.isLoaded }
    try await registerAudio(page)
    try await wait { fixture.host.audioSubscribedDisplayIDs == [7] }
    XCTAssertEqual(fixture.host.deliveryStatus.audioStates["wallpaper"], .subscribed)
    fixture.pump.onSpectrum?(.init(generation: 1, stereo: true, bins: Array(repeating: 0.4, count: 128)))
    try await wait { fixture.host.deliveryStatus.audioStates["wallpaper"] == .delivering }
    XCTAssertNil(fixture.host.deliveryStatus.audioStates["other"])
    fixture.model.clock = 3
    fixture.host.expireAudioDeliveries()
    XCTAssertEqual(fixture.host.deliveryStatus.audioStates["wallpaper"], .subscribed)
    fixture.host.setPresentationSuspended(true)
    XCTAssertEqual(fixture.host.deliveryStatus.audioStates["wallpaper"], .idle)
    XCTAssertTrue(fixture.host.audioSubscribedDisplayIDs.isEmpty)
  }

  func testFailedSubscriptionNeverDeliversEvenWhenASpectrumExists() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    fixture.model.refuseAudio = true
    await fixture.host.apply([fixture.descriptor])
    let page = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { page.isLoaded }
    try await registerAudio(page)
    try await wait { fixture.host.deliveryStatus.audioStates["wallpaper"] == .failed }
    XCTAssertTrue(fixture.host.audioSubscribedDisplayIDs.isEmpty)
    XCTAssertFalse(fixture.pump.isPolling)
    fixture.pump.onSpectrum?(.init(generation: 1, stereo: true, bins: Array(repeating: 0.4, count: 128)))
    XCTAssertEqual(fixture.host.deliveryStatus.audioStates["wallpaper"], .failed)
  }

  // MARK: - pause suspends the page

  /// The bridge's `paused` flag also carries battery Pause, so this is the path
  /// a pause the user never pressed takes.
  func testPauseDescriptorSuspendsThePageAndReleasesThePointerMonitor() async throws {
    let fixture = try Fixture(pageTiming: .init(firstFrameGrace: .zero))
    defer { fixture.close() }
    await fixture.host.apply([fixture.descriptor])
    let page = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { page.isLoaded && fixture.host.isPointerMonitorActive }
    XCTAssertFalse(page.hostSuspended)

    var paused = fixture.descriptor
    paused.paused = true
    await fixture.host.apply([paused])
    XCTAssertTrue(page.hostSuspended, "a paused page is suspended by the host, not left to setPaused")
    XCTAssertFalse(fixture.host.isPointerMonitorActive, "a suspended page keeps no global pointer monitor")

    await fixture.host.apply([fixture.descriptor])
    XCTAssertFalse(page.hostSuspended)
    XCTAssertTrue(fixture.host.isPointerMonitorActive)
  }

  /// The bridge folds presentation into a descriptor's `paused`, and a presentation
  /// change returns no snapshot to carry that. A descriptor read while the desktop
  /// is covered says paused; once the bridge has resumed, reading the descriptors
  /// again is the only thing that lets the page run, so the owner of the
  /// presentation change calls `reconcile()` after it.
  func testAPausedFlagReadWhileCoveredEndsWithTheCoverOnceTheDescriptorsAreReadAgain() async throws {
    let fixture = try Fixture(pageTiming: .init(firstFrameGrace: .zero))
    defer { fixture.close() }
    await fixture.host.apply([fixture.descriptor])
    let page = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { page.isLoaded && fixture.host.isPointerMonitorActive }

    fixture.host.setPresentationSuspended(true)
    var covered = fixture.descriptor
    covered.paused = true
    await fixture.host.apply([covered])
    XCTAssertTrue(page.hostSuspended)
    XCTAssertFalse(fixture.host.isPointerMonitorActive)

    fixture.host.setPresentationSuspended(false)
    fixture.model.served = [fixture.descriptor]  // the bridge has committed the resume
    fixture.host.reconcile()
    try await wait { !page.hostSuspended }
    XCTAssertFalse(page.hostSuspended, "nothing but the presentation paused it, so it runs again")
    try await wait { fixture.host.isPointerMonitorActive }
    XCTAssertTrue(fixture.host.isPointerMonitorActive)
  }

  /// An edit reaches a paused wallpaper too. The page draws it inside the window,
  /// is detached again with the new frame, and only then are the Space posters
  /// read again, so they come from the frame that shows the edit.
  func testAnEditToAPausedWallpaperRefreshesTheSpacePostersOnceItIsDrawn() async throws {
    let fixture = try Fixture(attachedSurfaces: true, pageTiming: .init(firstFrameGrace: .milliseconds(100)))
    defer { fixture.close() }
    var paused = fixture.descriptor
    paused.paused = true
    await fixture.host.apply([paused])
    let page = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { page.hostSuspended && page.suspensionPoster != nil }
    let earlier = try XCTUnwrap(page.suspensionPoster)
    let before = fixture.model.surfaceChanges

    var edited = paused
    edited.propertiesJson = #"{"theme":{"type":"text","value":"dark"}}"#
    await fixture.host.apply([edited])
    try await wait { fixture.model.surfaceChanges > before }
    XCTAssertTrue(page.hostSuspended, "the page is paused again when the posters are read")
    let refreshed = try XCTUnwrap(page.suspensionPoster)
    XCTAssertTrue(refreshed !== earlier, "and they are answered from the frame taken after the edit")
  }

  /// The grace expires without any host call, so only the page's own report can
  /// tell the host that the pointer monitor is no longer needed.
  func testTheFirstFrameGraceExpiringReleasesThePointerMonitor() async throws {
    let fixture = try Fixture(pageTiming: .init(firstFrameGrace: .milliseconds(100)))
    defer { fixture.close() }
    var paused = fixture.descriptor
    paused.paused = true
    await fixture.host.apply([paused])
    let page = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { page.hostSuspended }
    XCTAssertTrue(page.isLoaded, "the page loaded before it was suspended")
    XCTAssertFalse(fixture.host.isPointerMonitorActive)
  }

  /// The scale arrives with the descriptor, follows every change of it without a
  /// reload, and is part of a document that is loaded again afterwards.
  func testRenderScaleFollowsTheDescriptorAndIsReplayedAfterAReload() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    await fixture.host.apply([fixture.descriptor])
    let page = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { page.isLoaded }
    let native = try await pageRatio(page)
    let generation = page.documentGeneration

    var scaled = fixture.descriptor
    scaled.renderScale = 0.5
    await fixture.host.apply([scaled])
    try await waitForRatio(page, native * 0.5)
    XCTAssertEqual(page.documentGeneration, generation, "a scale change must not reload the page")

    scaled.renderScale = 0.75
    await fixture.host.apply([scaled])
    try await waitForRatio(page, native * 0.75)

    // A reload, as after a crash restart, starts from the descriptor's scale.
    page.load()
    try await wait { page.isLoaded }
    try await waitForRatio(page, native * 0.75)

    await fixture.host.apply([fixture.descriptor])
    try await waitForRatio(page, native)
  }

  func testAWallpaperOpenedWithAScaleIsScaledFromItsFirstRead() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try "<!doctype html><script>window.firstRatio = window.devicePixelRatio</script>".write(
      to: fixture.root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    var scaled = fixture.descriptor
    scaled.renderScale = 0.5
    await fixture.host.apply([scaled])
    let page = try XCTUnwrap(fixture.model.surfaces.last?.page)
    try await wait { page.isLoaded }

    // Back at full scale the ratio is the display's own, which the page's very
    // first read must have been half of.
    await fixture.host.apply([fixture.descriptor])
    let deadline = Date().addingTimeInterval(10)
    var doubled = false
    while !doubled && Date() < deadline {
      let value = try? await page.webView.callAsyncJavaScript(
        "return window.devicePixelRatio === window.firstRatio * 2", arguments: [:], in: nil,
        contentWorld: .page)
      doubled = value as? Bool == true
      if !doubled { try await Task.sleep(for: .milliseconds(25)) }
    }
    XCTAssertTrue(doubled, "the first read saw half the display's ratio")
  }

  private func pageNumber(_ page: WebWallpaperPage, _ expression: String) async throws -> Double {
    let value = try await page.webView.callAsyncJavaScript(
      "return \(expression)", arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? Double)
  }

  private func pageRatio(_ page: WebWallpaperPage) async throws -> Double {
    try await pageNumber(page, "window.devicePixelRatio")
  }

  private func waitForRatio(_ page: WebWallpaperPage, _ expected: Double) async throws {
    let deadline = Date().addingTimeInterval(10)
    var seen: Double?
    while Date() < deadline {
      seen = try? await pageRatio(page)
      if let seen, abs(seen - expected) < 1e-9 { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("the page's devicePixelRatio is \(String(describing: seen)), expected \(expected)")
  }

  func testASuspendedPageAnswersPosterRequestsFromItsSuspensionPoster() async throws {
    let fixture = try Fixture(attachedSurfaces: true, pageTiming: .init(firstFrameGrace: .zero))
    defer { fixture.close() }
    fixture.host.start()
    await fixture.host.apply([fixture.descriptor])
    let surface = try XCTUnwrap(fixture.model.surfaces.last)
    let page = surface.page
    try await wait { page.isLoaded }

    var paused = fixture.descriptor
    paused.paused = true
    await fixture.host.apply([paused])
    try await wait { page.suspensionPoster != nil }
    XCTAssertFalse(page.isInWindowTree)
    let poster = try XCTUnwrap(page.suspensionPoster)
    let expected = try XCTUnwrap(WebWallpaperHost.rgbaPixels(of: poster))
    // A snapshot of the detached view would now come out at another size, so
    // only the stored frame can produce the expected one.
    page.webView.setFrameSize(NSSize(width: 40, height: 30))

    var frames: [(width: Int, height: Int, context: String)] = []
    let observer = fixture.center.addObserver(
      forName: DesktopPosterNotification.ready, object: nil, queue: .main
    ) { note in
      guard let info = note.userInfo, let width = info["width"] as? Int, let height = info["height"] as? Int
      else { return }
      frames.append((width, height, info["context"] as? String ?? ""))
    }
    defer { fixture.center.removeObserver(observer) }
    fixture.center.post(
      name: DesktopPosterNotification.request, object: surface.posterLayer,
      userInfo: ["context": "space-change"])
    try await wait { !frames.isEmpty }
    XCTAssertEqual(frames.first?.width, expected.width)
    XCTAssertEqual(frames.first?.height, expected.height)
    XCTAssertEqual(frames.first?.context, "space-change")
  }
}
