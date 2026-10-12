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
    init(_ frame: NSRect, _ page: WebWallpaperPage) {
      self.frame = frame
      self.page = page
      page.webView.setFrameSize(frame.size)
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
    var subscriptions: [Bool] = []
    var deliveryChanges = 0
  }

  @MainActor private final class Fixture {
    let root: URL
    let model = Model()
    let host: WebWallpaperHost
    let pump = WebWallpaperAudioPump(read: { nil })
    let defaults: UserDefaults
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try "<!doctype html><script>window.contentVersion = 1</script>".write(
        to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      let model = model
      host = WebWallpaperHost(fetch: { [] },
        screens: { [(UInt32(7), NSRect(x: 0, y: 0, width: 320, height: 200))] },
        audioPump: pump, setAudioSubscribed: { _, _, subscribed in
          model.subscriptions.append(subscribed)
          if model.refuseAudio && subscribed { throw CancellationError() }
        }, imagePlacement: StillImagePlacementStore(defaults: defaults, library: root),
        pointerMonitor: PointerMonitor(), audioClock: { model.clock },
        contentRevision: { model.revision }, makeSurface: { frame, page in
          let surface = Surface(frame, page)
          model.surfaces.append(surface)
          return surface
        })
      host.onStateChanged = { model.states.append($0) }
      host.onDeliveryStateChanged = { model.deliveryChanges += 1 }
    }
    var descriptor: BridgeWebWallpaper {
      .init(displayId: 7, startupRevision: 3, displayKey: "primary", audioSourceDisplayId: 7,
        wallpaperId: "wallpaper", title: "Test", projectPath: root.path, entryFile: "index.html",
        fps: 30, paused: false, volume: 1, muted: false, audioResponseEnabled: true,
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
}
