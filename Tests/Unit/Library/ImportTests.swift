import Darwin
import XCTest
@testable import WallpaperMachine

final class ImportTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("managed/Library") }
    private let importer = WallpaperImportService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperMachine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func project(_ id: String, file: String = "movie.mp4", type: String = "video") throws -> URL {
        let url = root.appendingPathComponent("sources/\(id)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("video-content".utf8).write(to: url.appendingPathComponent("movie.mp4"))
        try JSONSerialization.data(withJSONObject: ["title": "Test \(id)", "type": type, "file": file])
            .write(to: url.appendingPathComponent("project.json"))
        return url
    }
    private func importOne(_ url: URL, policy: WallpaperImportService.DuplicatePolicy = .skip) async throws -> WallpaperImportService.Report {
        try await importer.importItems([url], into: library, duplicates: policy, progress: { _ in })
    }

    private func downloadedProject(_ id: String, staging: URL) throws -> URL {
        let source = try project(id)
        let destination = staging.appendingPathComponent("steamapps/workshop/content/431960/\(id)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private func assertDownloadRejected(_ id: String, staging: URL, library destination: URL? = nil,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await importer.importDownloadedItem(id, from: staging, into: destination ?? library)
            XCTFail("Unsafe or incomplete download was accepted", file: file, line: line)
        } catch {}
    }

    func testImportPreservesOriginalAndCompleteContent() async throws {
        let source = try project("123456")
        let report = try await importOne(source)
        XCTAssertEqual(report.importedIDs, ["123456"])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")),
                       try Data(contentsOf: library.appendingPathComponent("123456/movie.mp4")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("123456/project.json").path))
    }
    func testDuplicatesNeverOverwriteExistingWallpaper() async throws {
        let source = try project("123456")
        _ = try await importOne(source)
        try Data("different-content".utf8).write(to: source.appendingPathComponent("movie.mp4"))
        let skipped = try await importOne(source)
        XCTAssertEqual(skipped.skipped, ["123456"])
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("123456/movie.mp4"), encoding: .utf8), "video-content")
        let kept = try await importOne(source, policy: .keepBoth)
        XCTAssertEqual(kept.importedIDs.count, 1)
        XCTAssertNotEqual(kept.importedIDs.first, "123456")
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("\(try XCTUnwrap(kept.importedIDs.first))/movie.mp4"), encoding: .utf8), "different-content")
    }
    func testTraversalProjectIsRejectedWithoutLibraryEntry() async throws {
        let source = try project("escape", file: "../movie.mp4")
        let report = try await importOne(source)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("escape").path))
    }
    func testSymlinkContentIsRejectedWithoutPartialCommit() async throws {
        let source = try project("link")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside"), withDestinationURL: root)
        let report = try await importOne(source)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("link").path))
    }
    func testInvalidProjectDoesNotPreventValidSiblingImport() async throws {
        let invalid = try project("invalid", file: "missing.mp4")
        let valid = try project("valid")
        let result = try await importer.importItems([invalid, valid], into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(result.importedIDs, ["valid"])
        XCTAssertEqual(result.failures.count, 1)
    }
    func testImportFromManagedLibraryRejected() async throws {
        let source = try project("123")
        _ = try await importOne(source)
        let result = try await importOne(library.appendingPathComponent("123"), policy: .keepBoth)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }
    func testCancellationNeverCommitsIncompleteProject() async throws {
        let source = try project("cancelled")
        let task = Task {
            try await importer.importItems([source], into: library, duplicates: .skip, progress: { _ in })
        }
        task.cancel()
        let report = try await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("cancelled").path))
    }
    func testStandaloneVideoProducesPlayableManifest() async throws {
        let video = root.appendingPathComponent("My Video.mp4")
        try Data("video-content".utf8).write(to: video)
        let result = try await importOne(video)
        let id = try XCTUnwrap(result.importedIDs.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: library.appendingPathComponent("\(id)/project.json"))) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "video")
        XCTAssertEqual(json["file"] as? String, "My Video.mp4")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("\(id)/My Video.mp4")), try Data(contentsOf: video))
    }

    func testInvalidExistingDestinationIsNotReportedInstalled() async throws {
        let source = try project("123")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("not a wallpaper".utf8).write(to: library.appendingPathComponent("123"))
        let result = try await importOne(source)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testByteOrderMarkedManifestIsRejectedBeforeCommit() async throws {
        let source = try project("bom")
        let manifest = source.appendingPathComponent("project.json")
        let original = try Data(contentsOf: manifest)
        try (Data([0xEF, 0xBB, 0xBF]) + original).write(to: manifest)
        let result = try await importOne(source)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("bom").path))
    }

    func testDownloadedProjectMovesCompleteTreeWithoutCopying() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        let nested = source.appendingPathComponent("assets/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = nested.appendingPathComponent("texture.bin")
        try Data("nested-content".utf8).write(to: payload)
        let originalIdentity = try FileManager.default.attributesOfItem(atPath: payload.path)[.systemFileNumber] as? NSNumber
        try await importer.importDownloadedItem("123", from: staging, into: library)
        let installed = library.appendingPathComponent("123/assets/nested/texture.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: installed), Data("nested-content".utf8))
        XCTAssertEqual(try XCTUnwrap(originalIdentity),
                       try XCTUnwrap(FileManager.default.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? NSNumber))
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedUnsafeTreesNeverPublishPartialItems() async throws {
        for (id, specialFile) in [("123", false), ("124", true)] {
            let staging = root.appendingPathComponent("download-\(id)")
            let source = try downloadedProject(id, staging: staging)
            let nested = source.appendingPathComponent(".hidden/nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let unsafe = nested.appendingPathComponent("unsafe")
            if specialFile {
                XCTAssertEqual(unsafe.withUnsafeFileSystemRepresentation { mkfifo($0!, mode_t(0o600)) }, 0)
            } else {
                try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: root.appendingPathComponent("missing"))
            }
            await assertDownloadRejected(id, staging: staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("movie.mp4").path))
        }
    }

    func testDownloadedFixedAncestorsCannotTraverseSymbolicLinks() async throws {
        for component in ["", "steamapps", "steamapps/workshop", "steamapps/workshop/content", "steamapps/workshop/content/431960", "steamapps/workshop/content/431960/123"] {
            let staging = root.appendingPathComponent(UUID().uuidString)
            _ = try downloadedProject("123", staging: staging)
            let ancestor = component.isEmpty ? staging : staging.appendingPathComponent(component)
            let original = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: ancestor, to: original)
            try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: original)
            await assertDownloadRejected("123", staging: staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("123").path))
        }
    }

    func testDownloadedIncompleteContentNeverPublishes() async throws {
        for (id, damage) in [("123", "manifest"), ("124", "missing"), ("125", "empty")] {
            let staging = root.appendingPathComponent("download-\(id)")
            let source = try downloadedProject(id, staging: staging)
            switch damage {
            case "manifest":
                try Data("{\"type\":".utf8).write(to: source.appendingPathComponent("project.json"))
            case "missing":
                try FileManager.default.removeItem(at: source.appendingPathComponent("movie.mp4"))
            default:
                try Data().write(to: source.appendingPathComponent("movie.mp4"))
            }
            await assertDownloadRejected(id, staging: staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testDownloadedCancellationPreservesStagedContent() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        let importer = self.importer
        let library = self.library
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await importer.importDownloadedItem("123", from: staging, into: library)
        }
        do {
            try await task.value
            XCTFail("Cancelled download was published")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("123").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedDuplicatePreservesExistingAndStagedContent() async throws {
        let source = try project("123")
        _ = try await importOne(source)
        try FileManager.default.removeItem(at: source)
        let staging = root.appendingPathComponent("download")
        let downloaded = try downloadedProject("123", staging: staging)
        try Data("replacement".utf8).write(to: downloaded.appendingPathComponent("movie.mp4"))
        try await importer.importDownloadedItem("123", from: staging, into: library)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")), Data("video-content".utf8))
        XCTAssertEqual(try Data(contentsOf: downloaded.appendingPathComponent("movie.mp4")), Data("replacement".utf8))
    }

    func testDownloadedInvalidOrLinkedExistingDestinationIsRejected() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let destination = library.appendingPathComponent("123")
        try Data("existing-invalid".utf8).write(to: destination)
        await assertDownloadRejected("123", staging: staging)
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing-invalid".utf8))
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        await assertDownloadRejected("123", staging: staging)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), source.path)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedInvalidIDsAndOverlappingRootsAreRejected() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        for invalid in ["../123", "+123", "0", "１２３", "18446744073709551616"] {
            await assertDownloadRejected(invalid, staging: staging)
        }
        await assertDownloadRejected("123", staging: staging, library: staging)
        await assertDownloadRejected("123", staging: staging, library: staging.appendingPathComponent("managed"))
        await assertDownloadRejected("123", staging: staging, library: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("123").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedUpdateReplacesTheInstalledTreeAndLeavesTheOldInStaging() async throws {
        let firstStaging = root.appendingPathComponent("download-first")
        _ = try downloadedProject("123", staging: firstStaging)
        try await importer.importDownloadedItem("123", from: firstStaging, into: library)
        let updateStaging = root.appendingPathComponent("download-update")
        let update = try downloadedProject("123", staging: updateStaging)
        try Data("updated-content".utf8).write(to: update.appendingPathComponent("movie.mp4"))

        try await importer.importDownloadedItem("123", from: updateStaging, into: library, replacing: true)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")), Data("updated-content".utf8))
        // The old tree is swapped into staging, which the downloader clears with the rest of it.
        XCTAssertEqual(try Data(contentsOf: update.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    /// The replaced tree goes to staging, which is cleared, so only an installed wallpaper may go.
    func testAnUpdateLeavesAFolderThatIsNotAnInstalledWallpaperAlone() async throws {
        let folder = library.appendingPathComponent("789")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let staging = root.appendingPathComponent("download-update")
        let update = try downloadedProject("789", staging: staging)
        do {
            try await importer.importDownloadedItem("789", from: staging, into: library, replacing: true)
            XCTFail("a folder that is not an installed wallpaper must not be replaced")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("notes.txt")), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: update.appendingPathComponent("project.json").path))
    }

    func testReplacingWithNothingInstalledStillPublishes() async throws {
        let staging = root.appendingPathComponent("download-new")
        _ = try downloadedProject("456", staging: staging)
        try await importer.importDownloadedItem("456", from: staging, into: library, replacing: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("456/project.json").path))
    }

    func testConcurrentDownloadedPublicationsKeepOneWholeProject() async throws {
        let firstStaging = root.appendingPathComponent("download-first")
        let secondStaging = root.appendingPathComponent("download-second")
        let first = try downloadedProject("123", staging: firstStaging)
        let second = try downloadedProject("123", staging: secondStaging)
        try Data("second-content".utf8).write(to: second.appendingPathComponent("movie.mp4"))
        try Data("first".utf8).write(to: first.appendingPathComponent("marker"))
        try Data("second".utf8).write(to: second.appendingPathComponent("marker"))
        let otherImporter = WallpaperImportService()
        async let firstImport: Void = importer.importDownloadedItem("123", from: firstStaging, into: library)
        async let secondImport: Void = otherImporter.importDownloadedItem("123", from: secondStaging, into: library)
        _ = try await (firstImport, secondImport)
        let firstRemains = FileManager.default.fileExists(atPath: first.path)
        let secondRemains = FileManager.default.fileExists(atPath: second.path)
        XCTAssertNotEqual(firstRemains, secondRemains)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")),
                       Data((firstRemains ? "second-content" : "video-content").utf8))
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/marker")),
                       Data((firstRemains ? "second" : "first").utf8))
    }

    // MARK: Workshop presets

    /// A web wallpaper with two properties, as a Workshop preset's base.
    private func presetBase(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: url.appendingPathComponent("index.html"))
        try Data("base-preview".utf8).write(to: url.appendingPathComponent("preview.jpg"))
        let manifest: [String: Any] = [
            "title": "Fluid", "type": "web", "file": "index.html", "preview": "preview.jpg", "workshopid": "100",
            "general": ["supportsaudioprocessing": true, "properties": [
                "speed": ["type": "slider", "value": 1],
                "backgroundimage": ["type": "file", "value": ""],
                "group": ["type": "group"],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("project.json"))
    }

    /// A Workshop preset of item 100: no type, its own preview and a picture its values point at.
    private func preset(at url: URL, dependency: Any = "100") throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("preset-preview".utf8).write(to: url.appendingPathComponent("preview.gif"))
        try Data("picture".utf8).write(to: url.appendingPathComponent("files/bg.png"))
        let manifest: [String: Any] = [
            "title": "Purple Ink", "dependency": dependency, "preview": "preview.gif", "workshopid": "200",
            "preset": ["speed": 7, "backgroundimage": "files/bg.png", "group": NSNull(), "undeclared": 3],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("project.json"))
    }

    private func content(_ staging: URL, _ id: String) -> URL {
        staging.appendingPathComponent("steamapps/workshop/content/431960/\(id)")
    }

    private func assertAssembledPreset(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let installed = library.appendingPathComponent(id)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("index.html")), Data("<html></html>".utf8), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("files/bg.png")), Data("picture".utf8), file: file, line: line)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: installed.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertEqual(manifest["type"] as? String, "web", file: file, line: line)
        XCTAssertEqual(manifest["file"] as? String, "index.html", file: file, line: line)
        XCTAssertEqual(manifest["title"] as? String, "Purple Ink", file: file, line: line)
        XCTAssertEqual(manifest["preview"] as? String, "preview.gif", file: file, line: line)
        XCTAssertEqual(manifest["workshopid"] as? String, "200", file: file, line: line)
        XCTAssertEqual(manifest["dependency"] as? String, "100", file: file, line: line)
        let general = try XCTUnwrap(manifest["general"] as? [String: Any])
        XCTAssertEqual(general["supportsaudioprocessing"] as? Bool, true, file: file, line: line)
        let properties = try XCTUnwrap(general["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["speed"]?["value"] as? Int, 7, file: file, line: line)
        XCTAssertEqual(properties["backgroundimage"]?["value"] as? String, "files/bg.png", file: file, line: line)
        XCTAssertNil(properties["group"]?["value"], "A heading takes no value", file: file, line: line)
        XCTAssertNil(properties["undeclared"], "Only the base's own properties take values", file: file, line: line)
    }

    func testDownloadedPresetIsAssembledOnTheBaseDownloadedWithIt() async throws {
        let staging = root.appendingPathComponent("download-preset")
        try preset(at: content(staging, "200"))
        let found = try await importer.presetBaseToDownload("200", in: staging, library: library)
        XCTAssertEqual(found, "100")
        try presetBase(at: content(staging, "100"))
        let fetched = try await importer.presetBaseToDownload("200", in: staging, library: library)
        XCTAssertNil(fetched, "A base already in staging is not fetched again")
        try await importer.importDownloadedItem("200", from: staging, into: library)
        try assertAssembledPreset("200")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("100").path))
    }

    func testDownloadedPresetReusesAnInstalledBaseWithoutChangingIt() async throws {
        try presetBase(at: library.appendingPathComponent("100"))
        let original = try Data(contentsOf: library.appendingPathComponent("100/project.json"))
        let staging = root.appendingPathComponent("download-preset")
        try preset(at: content(staging, "200"), dependency: 100)
        let found = try await importer.presetBaseToDownload("200", in: staging, library: library)
        XCTAssertNil(found)
        try await importer.importDownloadedItem("200", from: staging, into: library, replacing: true)
        try assertAssembledPreset("200")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("100/project.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("100/files").path))
    }

    func testOrdinaryDownloadNeedsNoBase() async throws {
        let staging = root.appendingPathComponent("download")
        _ = try downloadedProject("123", staging: staging)
        let found = try await importer.presetBaseToDownload("123", in: staging, library: library)
        XCTAssertNil(found)
    }

    func testPresetWithoutAUsableBaseIsNeverPublished() async throws {
        let missing = root.appendingPathComponent("download-missing")
        try preset(at: content(missing, "200"))
        await assertDownloadRejected("200", staging: missing)
        let nested = root.appendingPathComponent("download-nested")
        try preset(at: content(nested, "200"))
        try preset(at: content(nested, "100"), dependency: "50")
        await assertDownloadRejected("200", staging: nested)
        let itself = root.appendingPathComponent("download-itself")
        try preset(at: content(itself, "200"), dependency: "200")
        do {
            _ = try await importer.presetBaseToDownload("200", in: itself, library: library)
            XCTFail("A preset of itself has no base to fetch")
        } catch {}
        await assertDownloadRejected("200", staging: itself)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("200").path))
    }

    func testImportedPresetIsAssembledFromItsSteamLibrarySiblingNonDestructively() async throws {
        let steamContent = root.appendingPathComponent("Steam/steamapps/workshop/content/431960")
        try presetBase(at: steamContent.appendingPathComponent("100"))
        try preset(at: steamContent.appendingPathComponent("200"))
        let report = try await importOne(steamContent.appendingPathComponent("200"))
        XCTAssertEqual(report.importedIDs, ["200"], "\(report.failures)")
        try assertAssembledPreset("200")
        XCTAssertTrue(FileManager.default.fileExists(atPath: steamContent.appendingPathComponent("200/files/bg.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: steamContent.appendingPathComponent("100/index.html").path))
        let orphan = root.appendingPathComponent("orphan/300")
        try preset(at: orphan)
        let failed = try await importOne(orphan)
        XCTAssertTrue(failed.importedIDs.isEmpty)
        XCTAssertEqual(failed.failures.count, 1)
    }

    // MARK: Where projects are found

    private func videoProject(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("content of \(url.lastPathComponent)".utf8).write(to: url.appendingPathComponent("movie.mp4"))
        try JSONSerialization.data(withJSONObject: ["title": url.lastPathComponent, "type": "video", "file": "movie.mp4"])
            .write(to: url.appendingPathComponent("project.json"))
    }

    private func sceneProject(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("scene.json"))
        try Data("PKGV".utf8).write(to: url.appendingPathComponent("scene.pkg"))
        try JSONSerialization.data(withJSONObject: ["title": url.lastPathComponent, "type": "scene", "file": "scene.json"])
            .write(to: url.appendingPathComponent("project.json"))
    }

    /// Imports `source` into a library of its own and returns the ids it added, sorted.
    private func idsImported(from source: URL, file: StaticString = #filePath, line: UInt = #line) async throws -> [String] {
        let report = try await importer.importItems([source], into: freshLibrary(), duplicates: .skip, progress: { _ in })
        XCTAssertEqual(report.failures, [], file: file, line: line)
        return report.importedIDs.sorted()
    }

    private func freshLibrary() -> URL {
        root.appendingPathComponent("libraries/\(UUID().uuidString)/Library")
    }

    private func assertRefused(_ source: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let library = freshLibrary()
        let report = try await importer.importItems([source], into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(report.failures.count, 1, "\(source.path)", file: file, line: line)
        XCTAssertTrue(report.importedIDs.isEmpty, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [], file: file, line: line)
    }

    func testAWallpaperEngineInstallInAnyChosenFolderImportsItsProjectsByFolderName() async throws {
        let steam = root.appendingPathComponent("Steam")
        let install = steam.appendingPathComponent("steamapps/common/wallpaper_engine")
        let projects = install.appendingPathComponent("projects")
        try videoProject(at: projects.appendingPathComponent("myprojects/mine-a"))
        try videoProject(at: projects.appendingPathComponent("myprojects/mine-b"))
        try videoProject(at: projects.appendingPathComponent("defaultprojects/default-a"))
        // Only project folders count: a stray folder and a file beside them are not wallpapers.
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("myprojects/empty"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: projects.appendingPathComponent("myprojects/readme.txt"))

        let everything = ["default-a", "mine-a", "mine-b"]
        let selections: [(URL, [String])] = [
            (steam, everything),
            (steam.appendingPathComponent("steamapps"), everything),
            (steam.appendingPathComponent("steamapps/common"), everything),
            (install, everything),
            (projects, everything),
            (projects.appendingPathComponent("myprojects"), ["mine-a", "mine-b"]),
            (projects.appendingPathComponent("defaultprojects"), ["default-a"]),
        ]
        for (selection, expected) in selections {
            let ids = try await idsImported(from: selection)
            XCTAssertEqual(ids, expected, selection.path)
        }
        // The copy is complete, not just the manifest.
        let library = freshLibrary()
        _ = try await importer.importItems([steam], into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("default-a/movie.mp4"), encoding: .utf8),
                       "content of default-a")
    }

    func testACopiedWallpaperEngineFolderImportsFromItselfOrItsParent() async throws {
        let copy = root.appendingPathComponent("From my PC")
        let folder = copy.appendingPathComponent("Wallpaper Engine")
        try videoProject(at: folder.appendingPathComponent("projects/myprojects/copied-1"))
        try videoProject(at: folder.appendingPathComponent("projects/defaultprojects/copied-2"))
        for selection in [copy, folder, folder.appendingPathComponent("projects")] {
            let ids = try await idsImported(from: selection)
            XCTAssertEqual(ids, ["copied-1", "copied-2"], selection.path)
        }
    }

    func testASteamLibraryImportsItsWorkshopItemsTogetherWithWallpaperEngineProjects() async throws {
        let steam = root.appendingPathComponent("Steam/steamapps")
        try videoProject(at: steam.appendingPathComponent("workshop/content/431960/555"))
        try videoProject(at: steam.appendingPathComponent("common/wallpaper_engine/projects/myprojects/mine"))
        let ids = try await idsImported(from: root.appendingPathComponent("Steam"))
        XCTAssertEqual(ids, ["555", "mine"])
    }

    func testAProjectsFolderLinkedFromOutsideTheChosenFolderIsNotFollowed() async throws {
        let elsewhere = root.appendingPathComponent("Elsewhere")
        try videoProject(at: elsewhere.appendingPathComponent("projects/myprojects/outside"))
        // The same layout inside the chosen folder is imported.
        try videoProject(at: root.appendingPathComponent("Inside/Wallpaper Engine/projects/myprojects/inside"))
        let found = try await idsImported(from: root.appendingPathComponent("Inside"))
        XCTAssertEqual(found, ["inside"])
        let pick = root.appendingPathComponent("Pick/Wallpaper Engine")
        try FileManager.default.createDirectory(at: pick, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pick.appendingPathComponent("projects"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("projects"))
        try await assertRefused(root.appendingPathComponent("Pick"))
        try await assertRefused(pick)
    }

    func testSelectingSceneOrProjectFileImportsItsFolder() async throws {
        let scene = root.appendingPathComponent("sources/scene-100")
        try sceneProject(at: scene)
        for name in ["project.json", "scene.json", "scene.pkg"] {
            let library = freshLibrary()
            let report = try await importer.importItems(
                [scene.appendingPathComponent(name)], into: library, duplicates: .skip, progress: { _ in })
            XCTAssertEqual(report.importedIDs, ["scene-100"], "\(name): \(report.failures)")
            XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("scene-100/scene.pkg")), Data("PKGV".utf8))
        }
        // A package's extension is matched without regard to case.
        let video = root.appendingPathComponent("sources/video-200")
        try videoProject(at: video)
        try Data("PKGV".utf8).write(to: video.appendingPathComponent("extra.PKG"))
        let ids = try await idsImported(from: video.appendingPathComponent("extra.PKG"))
        XCTAssertEqual(ids, ["video-200"])
        // The folder and one of its files chosen together are one project.
        let report = try await importer.importItems(
            [scene, scene.appendingPathComponent("scene.pkg")], into: freshLibrary(), duplicates: .skip, progress: { _ in })
        XCTAssertEqual(report.importedIDs, ["scene-100"])
        XCTAssertEqual(report.failures, [])
    }

    func testProjectFileWithoutSiblingManifestIsStillRefused() async throws {
        let loose = root.appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        for name in ["scene.json", "scene.pkg", "data.pkg"] {
            try Data("x".utf8).write(to: loose.appendingPathComponent(name))
            try await assertRefused(loose.appendingPathComponent(name))
        }
        // Any other JSON file next to a manifest is not a project file either.
        let project = root.appendingPathComponent("sources/with-extras")
        try videoProject(at: project)
        try Data("{}".utf8).write(to: project.appendingPathComponent("notes.json"))
        try await assertRefused(project.appendingPathComponent("notes.json"))
    }

    func testSymlinkedProjectFileOrParentIsRejected() async throws {
        let real = root.appendingPathComponent("sources/real")
        try sceneProject(at: real)
        let links = root.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        // The folder is a link to a project: choosing a file inside it is as refused as choosing the link.
        try FileManager.default.createSymbolicLink(at: links.appendingPathComponent("folder-link"), withDestinationURL: real)
        try await assertRefused(links.appendingPathComponent("folder-link/project.json"))
        try await assertRefused(links.appendingPathComponent("folder-link/scene.pkg"))
        // The chosen file itself is a link.
        let holder = links.appendingPathComponent("holder")
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: holder.appendingPathComponent("project.json"),
                                                   withDestinationURL: real.appendingPathComponent("project.json"))
        try await assertRefused(holder.appendingPathComponent("project.json"))
        // The manifest beside a package is a link.
        let sibling = links.appendingPathComponent("sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("PKGV".utf8).write(to: sibling.appendingPathComponent("scene.pkg"))
        try FileManager.default.createSymbolicLink(at: sibling.appendingPathComponent("project.json"),
                                                   withDestinationURL: real.appendingPathComponent("project.json"))
        try await assertRefused(sibling.appendingPathComponent("scene.pkg"))
    }
}
