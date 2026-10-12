import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WallpaperMachine

final class StillImagePageUpgradeTests: XCTestCase {
    private var library: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: library)
        defaults = nil
        library = nil
    }

    func testLegacyImportedDisplayCopyUpgradesWithoutChangingImageOrManifest() throws {
        let id = "image-large.heic"
        let project = try package(id: id, original: "image.heic", showing: "display.jpg", fit: .blur)
        let originalURL = project.appendingPathComponent("image.heic")
        let displayedURL = project.appendingPathComponent("display.jpg")
        let original = try Data(contentsOf: originalURL)
        let display = try Data(contentsOf: displayedURL)
        let manifest = try Data(contentsOf: project.appendingPathComponent("project.json"))
        let before = try XCTUnwrap(StillImagePageUpgrade.inspect(wallpaperID: id, project: project, library: library))
        XCTAssertTrue(before.upgraded)
        let result = try XCTUnwrap(StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
        XCTAssertTrue(result.upgraded)
        XCTAssertEqual(result.imageFile, "display.jpg")
        XCTAssertEqual(result.fit, .blur)
        XCTAssertEqual(result.imagePixelSize, CGSize(width: 2, height: 1))
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        XCTAssertEqual(try Data(contentsOf: displayedURL), display)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("project.json")), manifest)
        let current = try XCTUnwrap(StillImagePageUpgrade.inspect(wallpaperID: id, project: project, library: library))
        XCTAssertFalse(current.upgraded)
        XCTAssertEqual(current.imageFile, "display.jpg")
        let unchanged = try XCTUnwrap(StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
        XCTAssertFalse(unchanged.upgraded)
    }

    func testLegacyPixivUsesItsActualOriginalPathAndFit() throws {
        let id = "pixiv-123-p1"
        let project = try package(id: id, original: "illustration.png", showing: "illustration.png", fit: .fillTop, pixiv: true)
        let result = try XCTUnwrap(StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
        XCTAssertEqual(result.imageFile, "illustration.png")
        XCTAssertEqual(result.fit, .fillTop)
        XCTAssertTrue(result.upgraded)
    }

    func testAnExistingUnusedDisplayCopyDoesNotChangeWhatLegacyPageShows() throws {
        let id = "image-small.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .center)
        try png(width: 2, height: 1).write(to: project.appendingPathComponent("display.jpg"))
        let result = try XCTUnwrap(StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
        XCTAssertEqual(result.imageFile, "image.png")
        XCTAssertEqual(result.imagePixelSize, CGSize(width: 4, height: 2))
    }

    func testAnAuthorEditAfterInspectionCannotBeOverwrittenByTheCapturedGeneratedTemplate() throws {
        let id = "image-edited-during-upgrade.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .fill)
        let page = project.appendingPathComponent("index.html")
        let authored = Data("<html>new author content</html>".utf8)
        let result = try StillImagePageUpgrade.evaluate(wallpaperID: id, project: project, library: library,
            expectedStamp: StillImagePageUpgrade.stamp(project: project), upgrade: true,
            beforeValidation: { try authored.write(to: page, options: .atomic) })
        XCTAssertNil(result.result)
        XCTAssertNil(result.stamp)
        XCTAssertFalse(result.pageUpgraded)
        XCTAssertEqual(try Data(contentsOf: page), authored)
    }

    func testAnAuthorEditedPageIsNeverRewrittenEvenWithGeneratedProvenance() throws {
        let id = "image-edited.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .fill)
        let pageURL = project.appendingPathComponent("index.html")
        let authored = Data("<!doctype html><html><body>My authored wallpaper</body></html>".utf8)
        try authored.write(to: pageURL)
        XCTAssertNil(try StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
        XCTAssertEqual(try Data(contentsOf: pageURL), authored)
    }

    func testIdentifierAloneDoesNotAuthorizeUpgrade() throws {
        let id = "image-author.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .fill)
        let manifestURL = project.appendingPathComponent("project.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["image"] = nil
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let page = try Data(contentsOf: project.appendingPathComponent("index.html"))
        XCTAssertNil(try StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("index.html")), page)
    }

    func testPathEscapeAndSymlinkedResourcesNeverAuthorizeUpgrade() throws {
        let id = "image-safe.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .fill)
        XCTAssertNil(try StillImagePageUpgrade.prepare(wallpaperID: "../image-safe.png", project: project, library: library))
        let external = library.appendingPathComponent("outside.png")
        try png(width: 4, height: 2).write(to: external)
        let imageURL = project.appendingPathComponent("image.png")
        try FileManager.default.removeItem(at: imageURL)
        try FileManager.default.createSymbolicLink(at: imageURL, withDestinationURL: external)
        let page = try Data(contentsOf: project.appendingPathComponent("index.html"))
        XCTAssertNil(try StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("index.html")), page)
    }

    func testSymlinkedPageCannotModifyAnotherProject() throws {
        let id = "image-safe.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .fill)
        let target = library.appendingPathComponent("author.html")
        let original = Data(StillImageWallpaper.legacyPage(showing: "image.png", fit: .fill).utf8)
        try original.write(to: target)
        let page = project.appendingPathComponent("index.html")
        try FileManager.default.removeItem(at: page)
        try FileManager.default.createSymbolicLink(at: page, withDestinationURL: target)
        XCTAssertNil(try StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testOversizedManifestAndMismatchedPixivIdentityStayUnsupported() throws {
        let id = "pixiv-123-p1"
        let project = try package(id: id, original: "illustration.png", showing: "illustration.png", fit: .fit, pixiv: true)
        let manifestURL = project.appendingPathComponent("project.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var provenance = try XCTUnwrap(manifest["pixiv"] as? [String: Any])
        provenance["id"] = "999"
        manifest["pixiv"] = provenance
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertNil(try StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
        try Data(repeating: 32, count: StillImagePageUpgrade.maximumMetadataBytes + 1).write(to: manifestURL)
        XCTAssertNil(try StillImagePageUpgrade.prepare(wallpaperID: id, project: project, library: library))
    }

    @MainActor
    func testActualResourcesInvalidateDimensionsEligibilityAndRecoverWithoutManifestChanges() async throws {
        let cases: [(id: String, original: String, showing: String, pixiv: Bool)] = [
            ("image-resource.png", "image.png", "image.png", false),
            ("pixiv-123-p1", "illustration.png", "illustration.png", true),
            ("image-display.heic", "image.heic", "display.jpg", false),
        ]
        for fixture in cases {
            let project = try package(id: fixture.id, original: fixture.original,
                showing: fixture.showing, fit: .fill, pixiv: fixture.pixiv)
            let store = StillImagePlacementStore(defaults: defaults, library: library)
            let manifest = try Data(contentsOf: project.appendingPathComponent("project.json"))
            let first = try await store.prepare(wallpaperID: fixture.id)
            XCTAssertEqual(first?.imagePixelSize, fixture.showing == fixture.original
                ? CGSize(width: 4, height: 2) : CGSize(width: 2, height: 1))
            let image = project.appendingPathComponent(fixture.showing)
            let modified = try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try png(width: 3, height: 6).write(to: image, options: .atomic)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: image.path) }
            XCTAssertNil(store.generatedImage(wallpaperID: fixture.id), "old dimensions must disappear immediately")
            let replaced = try await store.prepare(wallpaperID: fixture.id)
            XCTAssertEqual(replaced?.imagePixelSize, CGSize(width: 3, height: 6))
            XCTAssertEqual(replaced?.imageAspectRatio, 0.5)
            XCTAssertEqual(store.generatedImage(wallpaperID: fixture.id)?.imagePixelSize, CGSize(width: 3, height: 6))

            try FileManager.default.removeItem(at: image)
            XCTAssertNil(store.generatedImage(wallpaperID: fixture.id))
            let deleted = try await store.prepare(wallpaperID: fixture.id)
            XCTAssertNil(deleted, "a generated page whose actual resource is missing is unsupported")
            try Data("not an image".utf8).write(to: image)
            XCTAssertNil(store.generatedImage(wallpaperID: fixture.id))
            let corrupted = try await store.prepare(wallpaperID: fixture.id)
            XCTAssertNil(corrupted, "manifest dimensions cannot certify unreadable image bytes")

            try png(width: 5, height: 2).write(to: image, options: .atomic)
            XCTAssertNil(store.generatedImage(wallpaperID: fixture.id))
            let restored = try await store.prepare(wallpaperID: fixture.id)
            XCTAssertEqual(restored?.imagePixelSize, CGSize(width: 5, height: 2))
            XCTAssertEqual(restored?.imageAspectRatio, 2.5)
            XCTAssertEqual(restored?.upgraded, false, "resource recovery must not rewrite an already-current page")
            XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("project.json")), manifest)
        }
    }

    @MainActor
    func testConcurrentColdPreparesPublishOneUpgradeAndCoherentCurrentMetadata() async throws {
        let id = "image-concurrent.png"
        _ = try package(id: id, original: "image.png", showing: "image.png", fit: .fit)
        let gate = ImagePreparationGate(entered: expectation(description: "first candidate inspected"))
        defer { gate.release() }
        let store = StillImagePlacementStore(defaults: defaults, library: library, beforeValidation: { gate.pauseFirst() })
        let posts = ImagePreparationPosts()
        let observer = NotificationCenter.default.addObserver(forName: StillImagePlacementStore.didChangeNotification,
            object: store, queue: nil) { posts.record($0) }
        defer { NotificationCenter.default.removeObserver(observer) }
        let first = Task { @MainActor in try await store.prepare(wallpaperID: id) }
        await fulfillment(of: [gate.entered], timeout: 5)
        let secondEntered = expectation(description: "second caller joins the first flight")
        let second = Task { @MainActor in
            secondEntered.fulfill()
            return try await store.prepare(wallpaperID: id)
        }
        await fulfillment(of: [secondEntered], timeout: 5)
        XCTAssertNil(store.generatedImage(wallpaperID: id))
        gate.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult?.upgraded, true)
        XCTAssertEqual(secondResult?.upgraded, true)
        XCTAssertEqual(firstResult?.imagePixelSize, CGSize(width: 4, height: 2))
        XCTAssertEqual(secondResult?.imagePixelSize, firstResult?.imagePixelSize)
        XCTAssertEqual(store.generatedImage(wallpaperID: id)?.upgraded, false,
            "awaiting prepare must already have published current metadata")
        let cached = try await store.prepare(wallpaperID: id)
        XCTAssertEqual(cached?.upgraded, false)
        try store.set(StillImagePlacement(x: 0.1, y: 0.9, zoom: 2), wallpaperID: id, displayID: "1")
        try store.reset(wallpaperID: id, displayID: "1")
        XCTAssertEqual(posts.upgrades.count, 1, "drag, reset, and cached prepare never reload documents")
        XCTAssertEqual(posts.upgrades.first?.wallpaperID, id)
        XCTAssertEqual(posts.upgrades.first?.metadataOnly, false,
            "an upgrade is not an inspector-only refresh")
    }

    @MainActor
    func testPrepareJoiningColdInspectionCannotOverwriteUpgradeWithLateUnsupportedResult() async throws {
        let id = "image-inspector-race.png"
        _ = try package(id: id, original: "image.png", showing: "image.png", fit: .blur)
        let gate = ImagePreparationGate(entered: expectation(description: "inspector candidate captured"))
        defer { gate.release() }
        let store = StillImagePlacementStore(defaults: defaults, library: library, beforeValidation: { gate.pauseFirst() })
        let posts = ImagePreparationPosts()
        let observer = NotificationCenter.default.addObserver(forName: StillImagePlacementStore.didChangeNotification,
            object: store, queue: nil) { posts.record($0) }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertNil(store.generatedImage(wallpaperID: id))
        await fulfillment(of: [gate.entered], timeout: 5)
        let joined = expectation(description: "prepare joins inspection")
        let preparation = Task { @MainActor in
            joined.fulfill()
            return try await store.prepare(wallpaperID: id)
        }
        await fulfillment(of: [joined], timeout: 5)
        gate.release()
        let result = try await preparation.value
        XCTAssertEqual(result?.upgraded, true)
        XCTAssertEqual(result?.fit, .blur)
        XCTAssertEqual(store.generatedImage(wallpaperID: id)?.imagePixelSize, CGSize(width: 4, height: 2))
        XCTAssertEqual(store.generatedImage(wallpaperID: id)?.upgraded, false)
        XCTAssertEqual(posts.upgrades.count, 1)
    }

    @MainActor
    func testChangedNilCannotPoisonARecoveredGeneratedPage() async throws {
        let id = "image-recovered.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .fill)
        let page = project.appendingPathComponent("index.html")
        try Data("<html>authored page</html>".utf8).write(to: page)
        let gate = ImagePreparationGate(entered: expectation(description: "unsupported version inspected"))
        defer { gate.release() }
        let store = StillImagePlacementStore(defaults: defaults, library: library, beforeValidation: { gate.pauseFirst() })
        let first = Task { @MainActor in try await store.prepare(wallpaperID: id) }
        await fulfillment(of: [gate.entered], timeout: 5)
        let recovered = Data(StillImageWallpaper.legacyPage(showing: "image.png", fit: .fill).utf8)
        try recovered.write(to: page, options: .atomic)
        gate.release()
        let outdated = try await first.value
        XCTAssertNil(outdated)
        XCTAssertEqual(try Data(contentsOf: page), recovered, "old inspection must not modify a different version")
        let prepared = try await store.prepare(wallpaperID: id)
        XCTAssertEqual(prepared?.upgraded, true)
        XCTAssertEqual(prepared?.imagePixelSize, CGSize(width: 4, height: 2))
        XCTAssertEqual(store.generatedImage(wallpaperID: id)?.upgraded, false)
    }

    @MainActor
    func testChangedResourceCannotPublishStaleDimensionsOrCommitAnOldCandidate() async throws {
        let id = "image-replaced-during-prepare.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .center)
        let page = project.appendingPathComponent("index.html")
        let originalPage = try Data(contentsOf: page)
        let gate = ImagePreparationGate(entered: expectation(description: "old dimensions captured"))
        defer { gate.release() }
        let store = StillImagePlacementStore(defaults: defaults, library: library, beforeValidation: { gate.pauseFirst() })
        let first = Task { @MainActor in try await store.prepare(wallpaperID: id) }
        await fulfillment(of: [gate.entered], timeout: 5)
        try png(width: 3, height: 6).write(to: project.appendingPathComponent("image.png"), options: .atomic)
        gate.release()
        let outdated = try await first.value
        XCTAssertNil(outdated)
        XCTAssertEqual(try Data(contentsOf: page), originalPage)
        let prepared = try await store.prepare(wallpaperID: id)
        XCTAssertEqual(prepared?.upgraded, true)
        XCTAssertEqual(prepared?.imagePixelSize, CGSize(width: 3, height: 6))
        XCTAssertEqual(store.generatedImage(wallpaperID: id)?.imageAspectRatio, 0.5)
    }

    @MainActor
    func testForgetDuringInspectionPublicationCannotRestartPreparationForTheDepartedWallpaper() async throws {
        let id = "image-forgotten-inspector.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .fill)
        let originalPage = try Data(contentsOf: project.appendingPathComponent("index.html"))
        let gate = ImagePreparationGate(entered: expectation(description: "inspection held before publication"))
        defer { gate.release() }
        let store = StillImagePlacementStore(defaults: defaults, library: library, beforeValidation: { gate.pauseFirst() })
        let observer = NotificationCenter.default.addObserver(forName: StillImagePlacementStore.didChangeNotification,
            object: store, queue: nil) { note in
                guard note.userInfo?["metadataOnly"] as? Bool == true else { return }
                MainActor.assumeIsolated {
                    do { try store.forget([id]) }
                    catch { XCTFail("Forgetting the wallpaper failed: \(error)") }
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertNil(store.generatedImage(wallpaperID: id))
        await fulfillment(of: [gate.entered], timeout: 5)
        let joined = expectation(description: "placement caller awaiting inspection")
        let preparation = Task { @MainActor in
            joined.fulfill()
            return try await store.prepare(wallpaperID: id)
        }
        await fulfillment(of: [joined], timeout: 5)
        gate.release()
        do {
            _ = try await preparation.value
            XCTFail("the forgotten inspector waiter must not start a fresh upgrade")
        } catch is CancellationError {
            // A lifecycle fence is required after awaiting inspection, not only inside IO.
        }
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("index.html")), originalPage)
    }

    @MainActor
    func testForgetFencesOldCompletionEvenWhenANewPreparationHasAlreadySucceeded() async throws {
        let id = "image-forgotten.png"
        let project = try package(id: id, original: "image.png", showing: "image.png", fit: .fillTop)
        let gate = ImagePreparationGate(entered: expectation(description: "departed wallpaper inspected"))
        defer { gate.release() }
        let store = StillImagePlacementStore(defaults: defaults, library: library, beforeValidation: { gate.pauseFirst() })
        let posts = ImagePreparationPosts()
        let observer = NotificationCenter.default.addObserver(forName: StillImagePlacementStore.didChangeNotification,
            object: store, queue: nil) { posts.record($0) }
        defer { NotificationCenter.default.removeObserver(observer) }
        let departed = Task { @MainActor in try await store.prepare(wallpaperID: id) }
        await fulfillment(of: [gate.entered], timeout: 5)
        try store.forget([id])
        try png(width: 5, height: 2).write(to: project.appendingPathComponent("image.png"), options: .atomic)
        let current = try await store.prepare(wallpaperID: id)
        XCTAssertEqual(current?.imagePixelSize, CGSize(width: 5, height: 2))
        XCTAssertEqual(current?.upgraded, true)
        gate.release()
        do {
            _ = try await departed.value
            XCTFail("a forgotten preparation must not revive its result")
        } catch is CancellationError {
            // The old flight cannot overwrite or remove the newer lifecycle's publication.
        }
        XCTAssertEqual(store.generatedImage(wallpaperID: id)?.imagePixelSize, CGSize(width: 5, height: 2))
        XCTAssertEqual(store.generatedImage(wallpaperID: id)?.upgraded, false)
        XCTAssertEqual(posts.upgrades.count, 1)
    }

    private func package(id: String, original: String, showing: String, fit: StillImageWallpaper.Fit,
                         pixiv: Bool = false) throws -> URL {
        let folder = library.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try png(width: 4, height: 2).write(to: folder.appendingPathComponent(original))
        if showing != original { try png(width: 2, height: 1).write(to: folder.appendingPathComponent(showing)) }
        var provenance: [String: Any] = ["file": original, "width": 4, "height": 2]
        if pixiv { provenance["id"] = "123"; provenance["page"] = 1 }
        let manifest: [String: Any] = ["type": "web", "file": "index.html",
            "general": ["properties": StillImageWallpaper.properties(fit: fit)],
            pixiv ? "pixiv" : "image": provenance]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("project.json"))
        try Data(StillImageWallpaper.legacyPage(showing: showing, fit: fit).utf8)
            .write(to: folder.appendingPathComponent("index.html"))
        return folder
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class ImagePreparationGate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var used = false

    init(entered: XCTestExpectation) { self.entered = entered }

    func pauseFirst() {
        lock.lock()
        let shouldPause = !used
        used = true
        lock.unlock()
        guard shouldPause else { return }
        entered.fulfill()
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

private final class ImagePreparationPosts: @unchecked Sendable {
    struct Upgrade {
        let wallpaperID: String?
        let metadataOnly: Bool
    }
    private let lock = NSLock()
    private var recorded: [Upgrade] = []

    var upgrades: [Upgrade] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ note: Notification) {
        guard note.userInfo?["pageUpgraded"] as? Bool == true else { return }
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Upgrade(wallpaperID: note.userInfo?["wallpaperID"] as? String,
            metadataOnly: note.userInfo?["metadataOnly"] as? Bool == true))
    }
}
