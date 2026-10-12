import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import WallpaperMachine

@MainActor
final class ControlPanelWindowSizingTests: XCTestCase {
  func testHostedPanelWindowKeepsItsSizeFloor() async throws {
    let bridge = SizingBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    let session = FileManager.default.temporaryDirectory.appendingPathComponent(
      "window-sizing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: session) }
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: session),
      supportDirectory: session, defaults: defaults)
    let updater = AppUpdateStore(currentVersion: "0.1.0", client: DisabledAppUpdateClient())
    let controller = NSHostingController(
      rootView: AnyView(
        ControlPanelView(
          store: store, navigation: ControlPanelNavigation(), workshop: workshop,
          pixiv: PixivStore(), updater: updater, imports: LibraryImportStore())))
    controller.sizingOptions = []
    let delegate = SizingDelegate()
    let window = ControlPanelWindow.make(contentViewController: controller, delegate: delegate)
    defer { window.close() }
    XCTAssertFalse(window.isVisible, "The window must stay offscreen")

    let minimum = ControlPanelWindow.minimumFrameSize(for: window)
    XCTAssertGreaterThanOrEqual(minimum.width, 760)
    XCTAssertGreaterThanOrEqual(minimum.height, 560)

    // Let SwiftUI attach to the window and apply whatever sizing it wants; the hosting
    // controller is known to zero `contentMinSize`, so the floor must not depend on it.
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))

    let clamped = ControlPanelWindow.clampedFrameSize(NSSize(width: 100, height: 80), for: window)
    XCTAssertEqual(clamped, minimum, "A tiny live-resize proposal must snap to the floor")
    let larger = NSSize(width: minimum.width + 200, height: minimum.height + 100)
    XCTAssertEqual(ControlPanelWindow.clampedFrameSize(larger, for: window), larger)

    window.setFrame(NSRect(x: 0, y: 0, width: 100, height: 80), display: false)
    ControlPanelWindow.constrainToScreen(window)
    XCTAssertGreaterThanOrEqual(window.frame.width, minimum.width, "Reopening must grow a shrunken frame")
    XCTAssertGreaterThanOrEqual(window.frame.height, minimum.height)
    XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 760)
    XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 560)
    XCTAssertFalse(window.isVisible, "The window must stay offscreen")
    await workshop.steamCMDSetup.shutdown()
  }

  func testColorPickerAnchorMatchesItsControlAcrossWindowLayouts() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: configuration)
    let controller = NSHostingController(rootView: ColorPickerHost(web: web).ignoresSafeArea())
    controller.sizingOptions = []
    let window = ControlPanelWindow.make(contentViewController: controller, delegate: nil)
    defer { window.close() }

    for size in [ControlPanelWindow.initialContentSize, ControlPanelWindow.minimumContentSize] {
      window.setContentSize(size)
      for fullScreen in [false, true, false] {
        ControlPanelWindow.setFullScreenLayout(fullScreen, for: window)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        // Wait for SwiftUI to size the representable without ordering a window.
        let content = try XCTUnwrap(window.contentView)
        let deadline = Date().addingTimeInterval(5)
        while web.convert(web.bounds, to: content) != content.bounds && Date() < deadline {
          try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(web.bounds.height, 400)
        XCTAssertEqual(web.convert(web.bounds, to: content), content.bounds,
          "The hosted panel must still fill the content area after resizing or changing chrome")

        for y in [CGFloat(24), web.bounds.midY, web.bounds.maxY - 48] {
          let control = NSRect(x: web.bounds.maxX - 100, y: y, width: 42, height: 24)
          // WebKit places its native color well directly in the content view using a
          // window-coordinate frame (WebKit bug 300025). That frame must land on the
          // same control, not its vertically mirrored position. No picker is opened.
          let pickerFrame = web.convert(control, to: nil)
          let anchor = content.convert(pickerFrame, to: web)
          XCTAssertEqual(anchor.minX, control.minX, accuracy: 0.5)
          XCTAssertEqual(anchor.minY, control.minY, accuracy: 0.5)
          XCTAssertEqual(anchor.size, control.size)
        }
        XCTAssertFalse(window.isVisible, "The window must stay offscreen")
      }
    }
  }

  func testHostedKeyViewLoopMovesForwardBackwardAndWrapsWithoutShowingWindow() async throws {
    let first = NSTextField(string: "First")
    let second = NSTextField(string: "Second")
    let controller = NSHostingController(rootView: KeyLoopHost(fields: [first, second]))
    controller.sizingOptions = []
    let window = ControlPanelWindow.make(contentViewController: controller, delegate: nil)
    defer { window.close() }
    window.layoutIfNeeded()
    let deadline = Date().addingTimeInterval(5)
    while (first.window !== window || second.window !== window) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard first.window === window, second.window === window else {
      XCTFail("Hosted fields did not attach to the test window before the deadline")
      return
    }
    controller.view.layoutSubtreeIfNeeded()
    window.recalculateKeyViewLoop()
    XCTAssertTrue(window.makeFirstResponder(first))
    XCTAssertTrue(window.firstResponder === first.currentEditor())
    try XCTUnwrap(first.currentEditor()).insertTab(nil)
    XCTAssertTrue(window.firstResponder === second.currentEditor(), "Tab must pass through the hosting wrapper")
    try XCTUnwrap(second.currentEditor()).insertTab(nil)
    XCTAssertTrue(window.firstResponder === first.currentEditor(), "The forward loop must wrap")
    try XCTUnwrap(first.currentEditor()).insertBacktab(nil)
    XCTAssertTrue(window.firstResponder === second.currentEditor(), "Shift-Tab must wrap backward")
    XCTAssertFalse(window.isVisible, "No desktop focus or window ordering is needed")
  }

  func testFullScreenLayoutKeepsNavigationReachableAndRestoresWindowedBounds() throws {
    let controller = NSViewController()
    controller.view = NSView(frame: NSRect(origin: .zero, size: ControlPanelWindow.initialContentSize))
    let navigation = NSButton(title: "Navigate", target: nil, action: nil)
    navigation.frame = NSRect(x: 120, y: controller.view.bounds.maxY - 42, width: 100, height: 32)
    navigation.autoresizingMask = [.minYMargin]
    controller.view.addSubview(navigation)
    let window = ControlPanelWindow.make(contentViewController: controller, delegate: nil)
    defer { window.close() }

    func navigationIsReachable() throws -> Bool {
      window.layoutIfNeeded()
      let root = try XCTUnwrap(window.contentView?.superview)
      let point = navigation.convert(
        NSPoint(x: navigation.bounds.midX, y: navigation.bounds.midY), to: root.superview)
      let hit = root.hitTest(point)
      return hit === navigation || hit?.isDescendant(of: navigation) == true
    }

    // Full-screen, a half-screen tile, and the minimum panel size. No Space transition
    // or window ordering: an opaque title bar reproduces the native obstruction offscreen.
    for size in [
      NSSize(width: 1920, height: 1080), NSSize(width: 960, height: 1080),
      ControlPanelWindow.minimumContentSize,
    ] {
      window.setFrame(NSRect(origin: .zero, size: size), display: false)
      window.layoutIfNeeded()
      let frame = window.frame
      let windowedLayout = window.contentLayoutRect
      XCTAssertTrue(try navigationIsReachable())

      window.titlebarAppearsTransparent = false
      ControlPanelWindow.setFullScreenLayout(true, for: window)
      window.layoutIfNeeded()
      XCTAssertEqual(window.frame, frame, "Changing chrome must not resize a full-screen tile")
      let content = controller.view.convert(controller.view.bounds, to: nil)
      XCTAssertTrue(window.contentLayoutRect.contains(content), "The page must stay below native chrome")
      XCTAssertTrue(try navigationIsReachable(), "Native chrome must not intercept navigation clicks")

      window.titlebarAppearsTransparent = true
      ControlPanelWindow.setFullScreenLayout(false, for: window)
      window.layoutIfNeeded()
      XCTAssertEqual(window.frame, frame, "Exiting must preserve the restored window bounds")
      XCTAssertEqual(window.contentLayoutRect, windowedLayout, "Restore the unified title-bar strip")
      XCTAssertTrue(try navigationIsReachable(), "Windowed navigation must remain clickable")
      XCTAssertFalse(window.isVisible, "The window must stay offscreen")
    }
  }
}

private struct KeyLoopHost: NSViewRepresentable {
  let fields: [NSTextField]

  func makeNSView(context: Context) -> NSStackView {
    let stack = NSStackView(views: fields)
    stack.orientation = .vertical
    return stack
  }
  func updateNSView(_ nsView: NSStackView, context: Context) {}
}

private struct ColorPickerHost: NSViewRepresentable {
  let web: WKWebView

  func makeNSView(context: Context) -> WKWebView { web }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private final class SizingDelegate: NSObject, NSWindowDelegate {}
private final class SizingBridge: WallpaperBridge {}
