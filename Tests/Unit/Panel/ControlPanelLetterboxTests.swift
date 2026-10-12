import XCTest

@testable import WallpaperMachine

/// The Black bars card in the real page: drawn from the snapshot's `videoLetterbox`, only for an
/// installed video. Offscreen; the frames come from an injected source, so nothing is decoded.
@MainActor
final class ControlPanelLetterboxTests: ControlPanelTestCase {
  func testCardShowsTheMeasuredBarsAndTheFactorForTheTargetDisplayOnlyForAVideo() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("panel-letterbox-page-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("clip.mp4")
    try Data("x".utf8).write(to: video)
    let letterbox = VideoLetterboxStore(
      probe: VideoLetterboxProbe(frames: { _ in LetterboxFixtures.frames(top: 23, bottom: 23) }, timeout: .seconds(600)),
      entry: { _, _ in video })
    letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1080) }

    let fixture = makeStore()
    let panel = try PanelFixture(store: fixture.store, bridge: fixture.bridge, displayTitles: .renderer, letterbox: letterbox)
    do {
      try await panel.start()
      try await panel.finishWelcome()
      let store = panel.store
      store.librarySnapshot.wallpapers = [
        .init(id: "clip", title: "Clip", kind: .video, supported: true, active: false, selected: true, previewPath: nil),
        .init(id: "scene", title: "Scene", kind: .projectScene, supported: true, active: false, selected: false, previewPath: nil),
      ]
      store.appSnapshot.selectedWallpaperId = "clip"
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "clip", kind: .video)
      panel.show()
      let card = "document.querySelector('#inspector [data-key=\"letterbox-clip\"]')"
      try await panel.waitJS("\(card) !== null")
      try await panel.expectJS("return \(card).textContent.includes('Look for black bars')", equals: true)
      try await panel.expectJS("return \(card).querySelector('[data-action=\"videoLetterboxCheck\"]').disabled", equals: false)

      await letterbox.check(wallpaperID: "clip", displayID: "primary", libraryRevision: store.libraryRefreshRevision)
      try await panel.waitJS("\(card).textContent.includes('Black bars found at the top and bottom, about 13% of the picture on each side.')")
      // 23 of 180 rows a side on a 16:9 display: 180 / 134 plus half a percent, rounded up.
      try await panel.expectJS("return \(card).textContent.includes('With Fill on this display, a scale factor of ×1.35 hides them.')", equals: true)
      try await panel.expectJS("return \(card).textContent.includes('Look again')", equals: true)

      store.appSnapshot.selectedWallpaperId = "scene"
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "scene", kind: .projectScene)
      try await panel.waitJS("document.querySelector('#inspector [data-key^=\"letterbox-\"]') === null")
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }
}
