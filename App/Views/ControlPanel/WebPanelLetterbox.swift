import AppKit
import Foundation

@MainActor
extension WebPanelController {
  func performLetterbox(_ action: String, request: WebPanelRequest) async throws -> Bool {
    guard action == "videoLetterboxCheck" else { return false }
    let id = try wallpaperID(request)
    let displayID = try request.string("displayID")
    guard let context = letterboxContext(), context.wallpaperID == id, context.displayID == displayID,
          context.eligible else { throw WebPanelRequest.invalid }
    await letterbox.check(wallpaperID: id, displayID: displayID, libraryRevision: store.libraryRefreshRevision)
    return true
  }

  func trackLetterboxDependencies() {
    _ = letterbox.changes
  }

  /// The black-bar card for the selected installed video, or nil for anything else. Built from
  /// the in-memory result and the target display's size: no file is read and no probe starts
  /// here. The suggested scale factor is computed now, not stored, because it depends on which
  /// display is the target.
  func letterboxSnapshot() -> [String: Any]? {
    letterbox.select(store.appSnapshot.selectedWallpaperId)
    guard let context = letterboxContext() else { return nil }
    let id = context.wallpaperID, displayID = context.displayID
    var payload: [String: Any] = ["wallpaperID": id, "displayID": displayID, "eligible": context.eligible]
    if let mode = context.scalingMode, let factor = context.scalingFactor {
      payload["current"] = ["scalingMode": Self.scaling(mode), "scalingFactor": factor]
    }
    switch letterbox.phase(for: id, revision: store.libraryRefreshRevision) {
    case .idle:
      payload["state"] = "idle"
    case .checking:
      payload["state"] = "checking"
    case .failed(let failure):
      payload["state"] = "failed"
      switch failure {
      case .unreadable: payload["reason"] = "unreadable"
      case .noVideoTrack: payload["reason"] = "noVideo"
      case .timedOut: payload["reason"] = "timedOut"
      case .fileChanged: payload["reason"] = "changed"
      }
    case .done(let report):
      switch report.verdict {
      case .none:
        payload["state"] = "none"
      case .bars(let bars):
        payload["state"] = "bars"
        payload["bars"] = Self.barsPayload(bars)
        // Fill is the only mode in which a scale factor crops the bars off the display.
        if context.scalingMode == .fill, let viewport = letterbox.viewportProvider(displayID) {
          switch LetterboxZoom.outcome(bars: bars, aspect: report.aspect, viewport: viewport) {
          case .alreadyHidden: payload["suggestion"] = ["kind": "hidden"]
          case .factor(let factor): payload["suggestion"] = ["kind": "factor", "factor": factor]
          case .implausible: payload["suggestion"] = ["kind": "implausible"]
          }
        }
      case .uneven(let bars):
        payload["state"] = "uneven"
        payload["bars"] = Self.barsPayload(bars)
      case .indeterminate(let reason):
        payload["state"] = "unclear"
        switch reason {
        case .tooDark: payload["reason"] = "dark"
        case .tooFewFrames: payload["reason"] = "fewFrames"
        case .disagree: payload["reason"] = "disagree"
        case .implausible: payload["reason"] = "implausible"
        }
      }
    }
    return payload
  }

  private struct LetterboxContext {
    let wallpaperID: String
    let displayID: String
    let eligible: Bool
    let scalingMode: BridgeScalingMode?
    let scalingFactor: Double?
  }

  private func letterboxContext() -> LetterboxContext? {
    guard let id = store.appSnapshot.selectedWallpaperId,
          let entry = store.librarySnapshot.wallpapers.first(where: { $0.id == id }),
          entry.kind == .video else { return nil }
    let displayID = navigation.targetDisplayID
    let display = store.settingsSnapshot.displays.first { $0.displayId == displayID }
    let options = store.wallpaperOptionsSnapshot.flatMap { $0.wallpaperId == id ? $0 : nil }
    let configuration = options?.displayConfigurations.first { $0.displayId == displayID }
    return LetterboxContext(
      wallpaperID: id, displayID: displayID,
      eligible: display?.enabled == true && display?.mode == .standalone && options != nil,
      scalingMode: configuration?.scalingMode ?? display?.scalingMode,
      scalingFactor: configuration?.scalingFactor ?? display?.scalingFactor)
  }

  private static func barsPayload(_ bars: LetterboxDetector.Bars) -> [String: Double] {
    ["top": bars.top, "bottom": bars.bottom, "left": bars.left, "right": bars.right]
  }

  /// The installed video file for the check, found through the same library validation the live
  /// preview uses instead of a third copy of the path checks.
  static func letterboxStore(for store: BridgeStore) -> VideoLetterboxStore {
    let letterbox = VideoLetterboxStore(entry: { [weak store] id, displayID in
      guard let store else { throw CancellationError() }
      let request = try await store.wallpaperPreviewRequestAsync(id: id, displayID: displayID)
      let validated = try await WallpaperPreviewLoader().validate(request)
      guard validated.kind == .video else { throw VideoLetterboxProbe.Failure.noVideoTrack }
      return validated.projectURL.appendingPathComponent(validated.entryFile)
    })
    letterbox.viewportProvider = { [weak store] displayID in
      guard let store else { return nil }
      let title = store.settingsSnapshot.displays.first { $0.displayId == displayID }?.title ?? ""
      guard let screen = DisplayGeometry.screen(displayID: displayID, title: title),
            screen.frame.width > 0, screen.frame.height > 0 else { return nil }
      return screen.frame.size
    }
    return letterbox
  }
}
