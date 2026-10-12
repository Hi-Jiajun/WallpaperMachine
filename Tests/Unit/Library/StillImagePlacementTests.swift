import Foundation
import XCTest
@testable import WallpaperMachine

@MainActor
final class StillImagePlacementTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    func testPlacementSurvivesRelaunchAndDisplaysRemainIndependent() throws {
        let store = StillImagePlacementStore(defaults: defaults)
        let left = try StillImagePlacement(x: 0, y: 0.3, zoom: 2)
        let right = try StillImagePlacement(x: 1, y: 0.8, zoom: 1.5)
        try store.set(left, wallpaperID: "image-a", displayID: "1")
        try store.set(right, wallpaperID: "image-a", displayID: "2")
        try store.set(right, wallpaperID: "image-b", displayID: "1")
        let reloaded = StillImagePlacementStore(defaults: defaults)
        XCTAssertEqual(reloaded.placement(wallpaperID: "image-a", displayID: "1"), left)
        XCTAssertEqual(reloaded.placement(wallpaperID: "image-a", displayID: "2"), right)
        try reloaded.reset(wallpaperID: "image-a", displayID: "1")
        let reset = StillImagePlacementStore(defaults: defaults)
        XCTAssertNil(reset.placement(wallpaperID: "image-a", displayID: "1"))
        XCTAssertEqual(reset.placement(wallpaperID: "image-a", displayID: "2"), right)
        XCTAssertEqual(reset.placement(wallpaperID: "image-b", displayID: "1"), right)
    }

    func testUnchangedPlacementDoesNotWakeHostsAndForgettingRemovesEveryDisplay() throws {
        let store = StillImagePlacementStore(defaults: defaults)
        let placement = try StillImagePlacement(x: 0.5, y: 0.5, zoom: 1)
        try store.set(placement, wallpaperID: "image-a", displayID: "1")
        try store.set(placement, wallpaperID: "image-a", displayID: "2")
        let count = PlacementPostCount()
        let token = NotificationCenter.default.addObserver(forName: StillImagePlacementStore.didChangeNotification,
            object: store, queue: nil) { _ in count.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.set(placement, wallpaperID: "image-a", displayID: "1")
        try store.reset(wallpaperID: "image-missing", displayID: "1")
        XCTAssertEqual(count.value, 0)
        try store.forget(["image-a"])
        XCTAssertEqual(count.value, 1)
        let reloaded = StillImagePlacementStore(defaults: defaults)
        XCTAssertNil(reloaded.placement(wallpaperID: "image-a", displayID: "1"))
        XCTAssertNil(reloaded.placement(wallpaperID: "image-a", displayID: "2"))
    }

    func testInvalidNumbersAndIdentitiesCannotBePersisted() throws {
        for invalid in [Double.nan, Double.infinity, -0.01, 1.01] {
            XCTAssertThrowsError(try StillImagePlacement(x: invalid, y: 0.5, zoom: 1))
            XCTAssertThrowsError(try StillImagePlacement(x: 0.5, y: invalid, zoom: 1))
        }
        for zoom in [Double.nan, Double.infinity, 0.99, 3.01] {
            XCTAssertThrowsError(try StillImagePlacement(x: 0.5, y: 0.5, zoom: zoom))
        }
        let placement = try StillImagePlacement(x: 0, y: 1, zoom: 3)
        let store = StillImagePlacementStore(defaults: defaults)
        XCTAssertThrowsError(try store.set(placement, wallpaperID: "../image-a", displayID: "1"))
        XCTAssertThrowsError(try store.set(placement, wallpaperID: "image-a", displayID: ""))
        XCTAssertNil(defaults.data(forKey: StillImagePlacementStore.storageKey))
        XCTAssertThrowsError(try JSONDecoder().decode(StillImagePlacement.self,
            from: Data(#"{"x":2,"y":0.5,"zoom":1}"#.utf8)))
    }

    func testCropProjectionPreservesFitAndAlignsRealOverflow() throws {
        let placement = try StillImagePlacement(x: 1, y: 0, zoom: 2)
        XCTAssertEqual(placement.projection(imageWidth: 400, imageHeight: 200,
            viewportWidth: 100, viewportHeight: 100, fit: .fill),
            CGRect(x: -300, y: 0, width: 400, height: 200))
        XCTAssertEqual(placement.projection(imageWidth: 400, imageHeight: 200,
            viewportWidth: 100, viewportHeight: 100, fit: .fit),
            CGRect(x: -100, y: 0, width: 200, height: 100))
        XCTAssertEqual(placement.projection(imageWidth: 400, imageHeight: 200,
            viewportWidth: 100, viewportHeight: 100, fit: .center),
            CGRect(x: -700, y: 0, width: 800, height: 400))
        let letterbox = try StillImagePlacement(x: 0.5, y: 1, zoom: 1)
        XCTAssertEqual(letterbox.projection(imageWidth: 400, imageHeight: 200,
            viewportWidth: 100, viewportHeight: 100, fit: .blur),
            CGRect(x: 0, y: 50, width: 100, height: 50))
        XCTAssertNil(letterbox.projection(imageWidth: 0, imageHeight: 200,
            viewportWidth: 100, viewportHeight: 100, fit: .fill))
    }

    func testEffectivePropertiesPreserveAuthorOptionsAndResetIsNotCenteredCustomization() throws {
        let json = #"{"fit":{"value":"fill-top"},"background":{"value":"0.1 0.2 0.3"},"file":{"value":"kept/photo.png"}}"#
        let customized = try StillImagePlacement(x: 0.5, y: 0.5, zoom: 1)
        let customJSON = try StillImagePlacement.merging(json, placement: customized)
        let custom = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(customJSON.utf8)) as? [String: Any])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for key in ["fit", "background", "file"] {
            XCTAssertEqual(custom[key] as? NSDictionary, original[key] as? NSDictionary)
        }
        let property = try XCTUnwrap(custom[StillImagePlacement.propertyKey] as? [String: Any])
        let value = try XCTUnwrap(property["value"] as? [String: Any])
        XCTAssertEqual(value["customized"] as? Bool, true)
        let resetJSON = try StillImagePlacement.merging(customJSON, placement: nil)
        let reset = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(resetJSON.utf8)) as? [String: Any])
        let resetProperty = try XCTUnwrap(reset[StillImagePlacement.propertyKey] as? [String: Any])
        XCTAssertEqual((resetProperty["value"] as? [String: Any])?["customized"] as? Bool, false)
        XCTAssertEqual(reset["fit"] as? NSDictionary, original["fit"] as? NSDictionary)
        XCTAssertThrowsError(try StillImagePlacement.merging("[]", placement: customized))
    }
}

private final class PlacementPostCount: @unchecked Sendable {
    var value = 0
}
