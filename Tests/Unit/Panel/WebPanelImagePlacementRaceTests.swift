import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

@MainActor
final class WebPanelImagePlacementRaceTests: XCTestCase {
    func testResetWinsOverAnEarlierColdPlacementRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try TemporaryDefaults.make(for: self).defaults
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let id = "image-race.png"
        let project = library.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (bytes as Data).write(to: project.appendingPathComponent("image.png"))
        let manifest: [String: Any] = ["type": "web", "file": "index.html", "title": "Image",
            "general": ["properties": StillImageWallpaper.properties(fit: .fill)],
            "image": ["file": "image.png", "width": 4, "height": 2]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: project.appendingPathComponent("project.json"))
        try StillImageWallpaper.legacyPage(showing: "image.png", fit: .fill)
            .write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let gate = Gate(entered: expectation(description: "cold preparation held"))
        defer { gate.release() }
        let images = StillImagePlacementStore(defaults: defaults, library: library, beforeValidation: { gate.pause() })
        try images.set(StillImagePlacement(x: 0.7, y: 0.4, zoom: 1.2), wallpaperID: id, displayID: "primary")
        let store = BridgeStore(bridge: LayoutSnapshotBridge(noPointer: .init()))
        store.librarySnapshot.wallpapers = [.init(id: id, title: "Image", kind: .webpage,
            supported: true, active: false, selected: true, previewPath: nil)]
        store.settingsSnapshot.displays = [.init(displayId: "primary", title: "Display", enabled: true,
            mode: .standalone, mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: .fill,
            scalingFactor: 1, targetFps: 30, maxFps: 60, muted: false, volume: 1)]
        let workshop = WorkshopStore(downloader: WorkshopDownloadManager(sessionDirectory: root),
            supportDirectory: root, defaults: defaults)
        let controller = WebPanelController(store: store, navigation: ControlPanelNavigation(), workshop: workshop,
            defaults: defaults, appLanguage: .english(), imagePlacement: images)
        defer { controller.stop() }
        let set = Task { @MainActor in
            try await controller.performImagePlacement("imagePlacement", request: .init([
                "id": id, "displayID": "primary", "x": 0.1, "y": 0.9, "zoom": 2.0]))
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        let started = expectation(description: "newer reset registered")
        let reset = Task { @MainActor in
            started.fulfill()
            return try await controller.performImagePlacement("imagePlacementReset", request: .init([
                "id": id, "displayID": "primary"]))
        }
        await fulfillment(of: [started], timeout: 5)
        gate.release()
        _ = try await set.value
        _ = try await reset.value
        XCTAssertNil(images.placement(wallpaperID: id, displayID: "primary"))
        XCTAssertNil(StillImagePlacementStore(defaults: defaults, library: library)
            .placement(wallpaperID: id, displayID: "primary"))
        XCTAssertTrue(controller.imagePlacementRequests.isEmpty)
    }

    private final class Gate: @unchecked Sendable {
        let entered: XCTestExpectation
        private let condition = NSCondition()
        private var waiting = true
        private var first = true
        init(entered: XCTestExpectation) { self.entered = entered }
        func pause() {
            condition.lock()
            defer { condition.unlock() }
            guard first else { return }
            first = false
            entered.fulfill()
            while waiting { condition.wait() }
        }
        func release() {
            condition.lock()
            waiting = false
            condition.broadcast()
            condition.unlock()
        }
    }
}
