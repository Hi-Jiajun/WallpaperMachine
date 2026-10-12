import Darwin
import Foundation

/// Copies user imports non-destructively and adopts validated private Steam downloads.
actor WallpaperImportService {
    enum DuplicatePolicy: String, CaseIterable, Identifiable, Sendable {
        case skip = "Skip existing"
        case keepBoth = "Keep both copies"
        var id: String { rawValue }
    }

    struct Report: Sendable {
        var importedIDs: [String] = []
        var skipped: [String] = []
        var failures: [String] = []
        var cancelled = false
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi"]
    static let webExtensions: Set<String> = ["html", "htm"]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif",
    ]
    /// Pictures a web view shows as they are. Any other format is shown from a JPEG copy, so a
    /// wallpaper never depends on which formats this macOS release's WebKit happens to decode.
    static let webImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]
    /// A picture is read into memory whole to measure and scale it.
    static let maximumImageBytes = 512 * 1024 * 1024
    /// Library ids of imported pictures start with this, so the panel can tell a still image
    /// it packaged from a web wallpaper someone wrote.
    static let imageIDPrefix = "image-"
    nonisolated static let stagingPrefix = ".WallpaperMachine-import-"
    nonisolated static let stagingOwnerName = ".owner"
    nonisolated private static let stagingOwnerMarker = Data("WallpaperMachine local import v1\n".utf8)

    private let downscale: @Sendable (Data, Int) throws -> Data

    /// `downscale` re-encodes an image as a JPEG no larger than the given pixel size; the app
    /// uses the thumbnail cache's ImageIO encoder, which also proves the bytes decode.
    init(
        downscale: @escaping @Sendable (Data, Int) throws -> Data = {
            try WorkshopThumbnailCache.encodeThumbnail($0, maxPixelSize: $1)
        }
    ) {
        self.downscale = downscale
    }

    func importItems(
        _ sources: [URL], into library: URL, duplicates: DuplicatePolicy,
        progress: @Sendable (String) async -> Void
    ) async throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let managedRoot = library.resolvingSymlinksInPath().standardizedFileURL
        // A sibling staging directory is on the same volume but invisible to the library scanner.
        let staging = managedRoot.deletingLastPathComponent()
            .appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let claim = try Self.claimStaging(staging)
        defer { close(claim) }
        var report = Report()
        var seen = Set<String>()

        for source in sources {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                try Task.checkCancellation()
                let candidates = try discover(source)
                for candidate in candidates {
                    try Task.checkCancellation()
                    let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
                    guard seen.insert(canonical.path).inserted else { continue }
                    await progress(String(localized: "Importing \(candidate.lastPathComponent)…"))
                    do {
                        guard !isWithin(canonical, managedRoot), !isWithin(managedRoot, canonical) else {
                            throw ImportError(message: String(localized: "Choose a source outside WallpaperMachine’s managed library."))
                        }
                        let isDirectory = try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                        let ext = candidate.pathExtension.lowercased()
                        let isImage = !isDirectory && Self.imageExtensions.contains(ext)
                        let preferredID = isDirectory ? candidate.lastPathComponent
                            : (isImage ? Self.imageIDPrefix : "local-") + candidate.lastPathComponent
                        guard isSafeRelativePath(preferredID), !preferredID.contains("/") else {
                            throw ImportError(message: String(localized: "The folder name cannot be used as a library identifier."))
                        }
                        var id = preferredID
                        var destination = managedRoot.appendingPathComponent(id, isDirectory: true)
                        if fm.fileExists(atPath: destination.path) {
                            if duplicates == .skip {
                                try validateProject(at: destination)
                                report.skipped.append(candidate.lastPathComponent)
                                continue
                            }
                            id += "-" + UUID().uuidString
                            destination = managedRoot.appendingPathComponent(id, isDirectory: true)
                        }
                        let staged = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        defer { try? fm.removeItem(at: staged) }
                        if isDirectory, let preset = presetManifest(at: candidate) {
                            // A Steam library keeps the preset's base next to it; the managed library may hold it too.
                            let base = try presetBase(of: preset, among: [
                                candidate.deletingLastPathComponent().appendingPathComponent(preset.dependency, isDirectory: true),
                                managedRoot.appendingPathComponent(preset.dependency, isDirectory: true),
                            ])
                            try copySafely(base, to: staged)
                            try overlay(candidate, onto: staged) { try self.copySafely($0, to: $1) }
                            try writePresetManifest(preset, into: staged, workshopID: nil)
                        } else if isDirectory {
                            try validateProject(at: candidate)
                            try copySafely(candidate, to: staged)
                        } else if isImage {
                            try packageImage(candidate, extension: ext, into: staged)
                        } else {
                            guard Self.videoExtensions.contains(ext) || Self.webExtensions.contains(ext) else {
                                throw ImportError(message: String(localized: "Choose a video, image, HTML file, or Wallpaper Engine project folder."))
                            }
                            try fm.createDirectory(at: staged, withIntermediateDirectories: false)
                            try copySafely(candidate, to: staged.appendingPathComponent(candidate.lastPathComponent))
                            let manifest: [String: Any] = [
                                "title": candidate.deletingPathExtension().lastPathComponent,
                                "type": Self.videoExtensions.contains(ext) ? "video" : "web",
                                "file": candidate.lastPathComponent,
                                "general": ["properties": [String: String]()]
                            ]
                            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                            try data.write(to: staged.appendingPathComponent("project.json"), options: .atomic)
                        }
                        try validateProject(at: staged)
                        try Task.checkCancellation()
                        // moveItem never overwrites a concurrently created destination.
                        try fm.moveItem(at: staged, to: destination)
                        report.importedIDs.append(id)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        report.failures.append("\(candidate.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            } catch is CancellationError {
                report.cancelled = true
                break
            } catch {
                report.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    nonisolated static func stagingRoot(forLibrary library: URL) -> URL {
        library.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
    }

    /// Held across every await and copy. A second instance's startup sweep must not
    /// infer ownership from an idle-looking directory while an import is running.
    nonisolated static func claimStaging(_ staging: URL) throws -> Int32 {
        let owner = staging.appendingPathComponent(stagingOwnerName)
        let descriptor = open(owner.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        let written = stagingOwnerMarker.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == stagingOwnerMarker.count else {
            close(descriptor)
            throw CocoaError(.fileWriteUnknown)
        }
        return descriptor
    }

    /// Claimed directories are removable only after their lock is released. Older
    /// versions wrote no claim, so those need a fully inspectable, day-old tree.
    nonisolated static func removeAbandonedStaging(in root: URL, legacyQuietFor quiet: TimeInterval = 86_400) {
        let files = FileManager.default
        guard let candidates = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let deadline = Date().addingTimeInterval(-max(0, quiet)).timeIntervalSince1970
        for staging in candidates where staging.lastPathComponent.hasPrefix(stagingPrefix) {
            let suffix = String(staging.lastPathComponent.dropFirst(stagingPrefix.count))
            var metadata = stat()
            guard UUID(uuidString: suffix) != nil, lstat(staging.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR else { continue }
            let descriptor = open(staging.appendingPathComponent(stagingOwnerName).path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            if descriptor >= 0 {
                defer { close(descriptor) }
                var ownerInfo = stat()
                guard fstat(descriptor, &ownerInfo) == 0, ownerInfo.st_mode & S_IFMT == S_IFREG,
                      ownerInfo.st_size == stagingOwnerMarker.count else { continue }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                guard let marker = try? handle.read(upToCount: stagingOwnerMarker.count + 1),
                      marker == stagingOwnerMarker else { continue }
                try? files.removeItem(at: staging)
            } else if errno == ENOENT, legacyStagingIsQuiet(staging, before: deadline) {
                try? files.removeItem(at: staging)
            }
        }
    }

    nonisolated private static func legacyStagingIsQuiet(_ root: URL, before deadline: TimeInterval) -> Bool {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, Double(rootInfo.st_mtimespec.tv_sec) < deadline else { return false }
        var readable = true
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in readable = false; return false }) else { return false }
        var visited = 0
        for case let file as URL in entries {
            visited += 1
            var info = stat()
            guard visited <= 200_000, lstat(file.path, &info) == 0,
                  Double(info.st_mtimespec.tv_sec) < deadline else { return false }
        }
        return readable
    }

    /// Packages one picture as a `StillImageWallpaper` in `staged`. The original keeps its bytes
    /// under a fixed name, so no file name from disk reaches the page's markup, and the title
    /// is the file's name.
    private func packageImage(_ source: URL, extension ext: String, into staged: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= Self.maximumImageBytes else {
            throw ImportError(message: String(localized: "Images must be regular files between 1 byte and 512 MB."))
        }
        let image = try Data(contentsOf: source, options: .mappedIfSafe)
        let unreadable = ImportError(message: String(localized: "This image could not be read. Choose a picture that opens in Preview."))
        guard let pixels = StillImageWallpaper.pixelSize(of: image) else { throw unreadable }
        let longest = max(pixels.width, pixels.height)
        let preview: Data
        var display: Data?
        do {
            preview = try downscale(image, StillImageWallpaper.previewPixels)
            if !Self.webImageExtensions.contains(ext) || longest > StillImageWallpaper.displayPixels {
                display = try downscale(image, min(longest, StillImageWallpaper.displayPixels))
            }
        } catch {
            throw unreadable
        }
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        let imageFile = "image.\(ext)"
        try image.write(to: staged.appendingPathComponent(imageFile))
        try preview.write(to: staged.appendingPathComponent(StillImageWallpaper.previewFile))
        if let display { try display.write(to: staged.appendingPathComponent(StillImageWallpaper.displayFile)) }
        let fit = StillImageWallpaper.Fit.preferred(width: pixels.width, height: pixels.height)
        try Data(StillImageWallpaper.page(showing: display == nil ? imageFile : StillImageWallpaper.displayFile, fit: fit).utf8)
            .write(to: staged.appendingPathComponent(StillImageWallpaper.entryFile))
        let manifest: [String: Any] = [
            "title": source.deletingPathExtension().lastPathComponent,
            "type": "web",
            "file": StillImageWallpaper.entryFile,
            "preview": StillImageWallpaper.previewFile,
            "general": ["properties": StillImageWallpaper.properties(fit: fit)],
            "image": ["file": imageFile, "width": pixels.width, "height": pixels.height],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: staged.appendingPathComponent("project.json"), options: .atomic)
    }

    /// Consumes a complete item from disposable Steam staging without copying payload bytes.
    /// A valid existing item is left untouched unless `replacing`, when the new tree takes its
    /// place; the caller remains responsible for staging cleanup.
    ///
    /// A Workshop preset is assembled first: its base's content, the preset's own files on top,
    /// and the base's manifest carrying the preset's title and property values. The base comes
    /// from the same staging (see `presetBaseToDownload`) or, failing that, from the library.
    func importDownloadedItem(_ itemID: String, from staging: URL, into library: URL, replacing: Bool = false) throws {
        try Task.checkCancellation()
        guard Self.workshopID(itemID) != nil else {
            throw ImportError(message: String(localized: "Choose a valid numeric Workshop item identifier."))
        }
        let fm = FileManager.default
        let stagingRoot = staging.standardizedFileURL
        let canonicalStaging = stagingRoot.resolvingSymlinksInPath().standardizedFileURL
        var managedRoot = library.resolvingSymlinksInPath().standardizedFileURL
        guard !isWithin(canonicalStaging, managedRoot), !isWithin(managedRoot, canonicalStaging) else {
            throw ImportError(message: String(localized: "Download staging must be outside the managed library."))
        }

        var source = try downloadedItemFolder(itemID, in: stagingRoot)
        if let preset = presetManifest(at: source) {
            source = try assembleDownloadedPreset(itemID, preset: preset, at: source, staging: stagingRoot, library: library)
        }
        try validateDownloadedProject(at: source)
        try Task.checkCancellation()
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        managedRoot = library.resolvingSymlinksInPath().standardizedFileURL
        guard !isWithin(canonicalStaging, managedRoot), !isWithin(managedRoot, canonicalStaging) else {
            throw ImportError(message: String(localized: "Download staging must be outside the managed library."))
        }
        let destination = managedRoot.appendingPathComponent(itemID, isDirectory: true)
        try Task.checkCancellation()
        if replacing, let installed = try? downloadMetadata(at: destination), installed.st_mode & S_IFMT == S_IFDIR {
            // Only an installed wallpaper is replaced: the old tree ends up in staging, which the
            // caller clears, so a folder that is not one is left where it is.
            do {
                try validateProject(at: destination)
            } catch {
                throw ImportError(message: String(localized: "The library’s folder for Workshop item \(itemID) is not an installed wallpaper, so its update was not put in its place. Move the folder out of the library and download the item again."))
            }
            // An update swaps the new tree in and the old one out in one step, so the library never
            // lacks the wallpaper and a failure leaves the old version where it was.
            let result = source.path.withCString { sourcePath in
                destination.path.withCString { destinationPath in
                    renamex_np(sourcePath, destinationPath, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                    NSFilePathErrorKey: destination.path,
                    NSLocalizedDescriptionKey: String(localized: "Could not replace Workshop item \(itemID) with its update: \(String(cString: strerror(code))). The installed version is unchanged.")
                ])
            }
            return
        }
        // Unlike moveItem, this cannot fall back to a cross-volume copy. RENAME_EXCL
        // atomically refuses even a destination created after our validation.
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST {
                try validateDownloadedProject(at: destination)
                try Task.checkCancellation()
                return
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSFilePathErrorKey: destination.path,
                NSLocalizedDescriptionKey: String(localized: "Could not publish Workshop item \(itemID): \(String(cString: strerror(code))). Download staging and the library must be on the same volume.")
            ])
        }
    }

    /// The Workshop item a downloaded preset is built on, when neither the download's own staging
    /// nor the library already holds it; nil for an ordinary wallpaper. The downloader fetches it
    /// into the same staging before `importDownloadedItem` assembles the preset.
    func presetBaseToDownload(_ itemID: String, in staging: URL, library: URL) throws -> String? {
        try Task.checkCancellation()
        guard Self.workshopID(itemID) != nil else {
            throw ImportError(message: String(localized: "Choose a valid numeric Workshop item identifier."))
        }
        let stagingRoot = staging.standardizedFileURL
        guard let preset = presetManifest(at: try downloadedItemFolder(itemID, in: stagingRoot)) else { return nil }
        guard preset.dependency != itemID else {
            throw ImportError(message: String(localized: "This preset names itself as the wallpaper it is based on, so it cannot be used."))
        }
        let staged = Self.downloadedContent(in: stagingRoot).appendingPathComponent(preset.dependency, isDirectory: true)
        if (try? downloadMetadata(at: staged)) != nil { return nil }
        let installed = library.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(preset.dependency, isDirectory: true)
        if (try? requireDownloadDirectory(installed)) != nil, (try? validateProject(at: installed)) != nil { return nil }
        return preset.dependency
    }

    /// A Workshop preset: no wallpaper `type`, only the Workshop item it is `dependency` on and,
    /// under `preset`, values for that item's properties.
    private struct Preset {
        let manifest: [String: Any]
        let dependency: String
    }

    nonisolated static func workshopID(_ value: Any?) -> String? {
        let text: String
        if let string = value as? String {
            text = string
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.int64Value > 0 {
            text = number.stringValue
        } else {
            return nil
        }
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let id = UInt64(text), id > 0 else { return nil }
        return text
    }

    private static func downloadedContent(in staging: URL) -> URL {
        staging.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
    }

    /// Checks each fixed ancestor before descending: resolving the final path alone would
    /// silently accept a Steam content directory redirected through a symbolic link.
    private func downloadedItemFolder(_ itemID: String, in staging: URL) throws -> URL {
        var source = staging
        try requireDownloadDirectory(source)
        for component in ["steamapps", "workshop", "content", "431960", itemID] {
            try Task.checkCancellation()
            source.appendPathComponent(component, isDirectory: true)
            try requireDownloadDirectory(source)
        }
        return source
    }

    /// The preset described by `root/project.json`, or nil when it is anything else; ordinary
    /// validation then reports what is wrong with it.
    private func presetManifest(at root: URL) -> Preset? {
        let url = root.appendingPathComponent("project.json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: url), !data.starts(with: [0xEF, 0xBB, 0xBF]),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              ((manifest["type"] as? String) ?? "").isEmpty,
              let dependency = Self.workshopID(manifest["dependency"]) else { return nil }
        return Preset(manifest: manifest, dependency: dependency)
    }

    /// The first candidate folder holding an installable wallpaper to build the preset on.
    private func presetBase(of preset: Preset, among candidates: [URL]) throws -> URL {
        for base in candidates {
            try Task.checkCancellation()
            guard let metadata = try? downloadMetadata(at: base), metadata.st_mode & S_IFMT == S_IFDIR else { continue }
            if presetManifest(at: base) != nil {
                throw ImportError(message: String(localized: "This preset is based on another preset (Workshop item \(preset.dependency)). Presets of presets are not supported."))
            }
            try validateProject(at: base)
            return base
        }
        throw ImportError(message: String(localized: "This preset is based on Workshop item \(preset.dependency), which is not in your library. Download or import that wallpaper first, then try again."))
    }

    /// Builds the downloaded preset in staging. A base downloaded alongside it is moved, one from
    /// the library is cloned, and the preset's own files are moved over it.
    private func assembleDownloadedPreset(_ itemID: String, preset: Preset, at source: URL, staging: URL, library: URL) throws -> URL {
        guard preset.dependency != itemID else {
            throw ImportError(message: String(localized: "This preset names itself as the wallpaper it is based on, so it cannot be used."))
        }
        try requireRegularTree(source)
        let staged = Self.downloadedContent(in: staging).appendingPathComponent(preset.dependency, isDirectory: true)
        let installed = library.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(preset.dependency, isDirectory: true)
        let base = try presetBase(of: preset, among: [staged, installed])
        try requireRegularTree(base)
        let fm = FileManager.default
        let built = staging.appendingPathComponent("preset-\(UUID().uuidString)", isDirectory: true)
        if base == staged {
            try fm.moveItem(at: base, to: built)
        } else {
            // On APFS this clones the files rather than duplicating their bytes.
            try fm.copyItem(at: base, to: built)
        }
        try requireRegularTree(built)
        try overlay(source, onto: built) { try fm.moveItem(at: $0, to: $1) }
        try writePresetManifest(preset, into: built, workshopID: itemID)
        return built
    }

    /// Places every file of the preset over the base, replacing what is there; the preset's own
    /// manifest is merged separately.
    private func overlay(_ preset: URL, onto base: URL, root: Bool = true, transfer: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for child in try fm.contentsOfDirectory(at: preset, includingPropertiesForKeys: keys) {
            try Task.checkCancellation()
            if root && child.lastPathComponent == "project.json" { continue }
            let target = base.appendingPathComponent(child.lastPathComponent)
            let values = try child.resourceValues(forKeys: Set(keys))
            let existing = try? downloadMetadata(at: target)
            if values.isDirectory == true, values.isSymbolicLink != true, let existing, existing.st_mode & S_IFMT == S_IFDIR {
                try overlay(child, onto: target, root: false, transfer: transfer)
                continue
            }
            if existing != nil { try fm.removeItem(at: target) }
            try transfer(child, target)
        }
    }

    /// Rewrites the base's manifest in `built` as the preset's: its title, description, tags,
    /// rating and preview, its Workshop id, and its values for the base's properties.
    private func writePresetManifest(_ preset: Preset, into built: URL, workshopID: String?) throws {
        let url = built.appendingPathComponent("project.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ImportError(message: String(localized: "project.json must describe a scene, video, or web wallpaper."))
        }
        for key in ["title", "description", "tags", "contentrating"] {
            if let value = preset.manifest[key], !(value is NSNull) { manifest[key] = value }
        }
        if let preview = preset.manifest["preview"] as? String, isSafeRelativePath(preview),
           (try? built.appendingPathComponent(preview).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            manifest["preview"] = preview
        }
        // The base's Workshop identity must not follow it into the preset.
        manifest.removeValue(forKey: "workshopurl")
        manifest["workshopid"] = workshopID ?? Self.workshopID(preset.manifest["workshopid"])
        manifest["dependency"] = preset.dependency
        if let values = preset.manifest["preset"] as? [String: Any],
           var general = manifest["general"] as? [String: Any],
           var properties = general["properties"] as? [String: Any] {
            // Only properties the base declares take a value; nulls are the preset's group headings.
            for (name, value) in values where !(value is NSNull) {
                guard var property = properties[name] as? [String: Any] else { continue }
                property["value"] = value
                properties[name] = property
            }
            general["properties"] = properties
            manifest["general"] = general
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func downloadMetadata(at url: URL) throws -> stat {
        var metadata = stat()
        // URL directory representations can include a trailing slash, which makes
        // lstat follow a final symlink. URL.path removes that directory marker.
        let result = url.path.withCString { lstat($0, &metadata) }
        guard result == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        return metadata
    }

    private func requireDownloadDirectory(_ url: URL) throws {
        let metadata = try downloadMetadata(at: url)
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ImportError(message: String(localized: "Download directories must be real folders, not symbolic links or special files: \(url.lastPathComponent)."))
        }
    }

    private func validateDownloadedProject(at root: URL) throws {
        try requireRegularTree(root)
        try Task.checkCancellation()
        try validateProject(at: root, requireNonemptyContent: true)
    }

    private func requireRegularTree(_ root: URL) throws {
        try requireDownloadDirectory(root)
        var pending = [root]
        while let next = pending.popLast() {
            try Task.checkCancellation()
            let metadata = try downloadMetadata(at: next)
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                pending.append(contentsOf: try FileManager.default.contentsOfDirectory(at: next, includingPropertiesForKeys: nil))
            case S_IFREG:
                break
            default:
                throw ImportError(message: String(localized: "Downloaded projects may contain only regular files and folders, not symbolic links or special files: \(next.lastPathComponent)."))
            }
        }
    }

    /// Folders, relative to a chosen one, whose children can be projects: Workshop downloads in a
    /// Steam library, and the `projects` folders of a Wallpaper Engine install, which a user may
    /// pick as the library, as `steamapps`, `common`, the install itself, or a copy of it from
    /// another computer.
    private static let projectRoots: [String] = {
        let workshop = ["", "steamapps/workshop/content/431960", "workshop/content/431960", "content/431960", "431960"]
        let installs = ["steamapps/common/wallpaper_engine", "common/wallpaper_engine", "wallpaper_engine", "Wallpaper Engine", ""]
        let projectFolders = ["projects/myprojects", "projects/defaultprojects"]
        let installed = installs.flatMap { install in
            projectFolders.map { folder in install.isEmpty ? folder : install + "/" + folder }
        }
        // The projects folder itself, or one of its two halves.
        return workshop + installed + ["myprojects", "defaultprojects"]
    }()

    private func discover(_ source: URL) throws -> [URL] {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ImportError(message: String(localized: "Symbolic links are not imported. Choose the original folder or file instead."))
        }
        guard values.isDirectory == true else { return [projectFolder(ofFile: source) ?? source] }
        if fm.fileExists(atPath: source.appendingPathComponent("project.json").path) { return [source] }
        var projects: [URL] = []
        for relative in Self.projectRoots {
            try Task.checkCancellation()
            let root = relative.isEmpty ? source : source.appendingPathComponent(relative, isDirectory: true)
            guard fm.fileExists(atPath: root.path) else { continue }
            guard isWithin(root.resolvingSymlinksInPath().standardizedFileURL,
                           source.resolvingSymlinksInPath().standardizedFileURL) else { continue }
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for child in children where fm.fileExists(atPath: child.appendingPathComponent("project.json").path) {
                projects.append(child)
            }
        }
        guard !projects.isEmpty else {
            throw ImportError(message: String(localized: "No project.json found. Choose a wallpaper project, a folder containing projects, a Steam library or a Wallpaper Engine folder."))
        }
        return projects.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The project a chosen file belongs to: its own folder, when the file is the manifest, the
    /// scene description or a package, and the folder holds a project manifest. Links are never
    /// followed, neither the file nor the folder, so this is as strict as choosing the folder.
    private func projectFolder(ofFile file: URL) -> URL? {
        let name = file.lastPathComponent.lowercased()
        guard name == "project.json" || name == "scene.json" || file.pathExtension.lowercased() == "pkg",
              let metadata = try? downloadMetadata(at: file), metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        let folder = URL(fileURLWithPath: file.deletingLastPathComponent().path, isDirectory: true)
        guard let folderMetadata = try? downloadMetadata(at: folder), folderMetadata.st_mode & S_IFMT == S_IFDIR,
              let manifest = try? downloadMetadata(at: folder.appendingPathComponent("project.json")),
              manifest.st_mode & S_IFMT == S_IFREG else { return nil }
        return folder
    }

    private func validateProject(at root: URL, requireNonemptyContent: Bool = false) throws {
        let manifestURL = root.appendingPathComponent("project.json")
        let metadata = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              (metadata.fileSize ?? 0) <= 16 * 1024 * 1024 else {
            throw ImportError(message: String(localized: "project.json must be a regular JSON file smaller than 16 MB."))
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard String(data: manifestData, encoding: .utf8) != nil, !manifestData.starts(with: [0xEF, 0xBB, 0xBF]) else {
            throw ImportError(message: String(localized: "project.json must use UTF-8 encoding without a byte-order mark. Convert the manifest and import it again."))
        }
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let type = (manifest["type"] as? String)?.lowercased(), ["scene", "video", "web"].contains(type) else {
            throw ImportError(message: String(localized: "project.json must describe a scene, video, or web wallpaper."))
        }
        if let value = manifest["file"], !(value is String) {
            throw ImportError(message: String(localized: "The project’s file field must be a relative filename."))
        }
        let file = (manifest["file"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (type == "scene" ? "scene.json" : "")
        guard isSafeRelativePath(file) else {
            throw ImportError(message: String(localized: "The project’s file field must point inside its own folder (no absolute paths or parent traversal)."))
        }
        let entry = root.appendingPathComponent(file)
        let package = entry.deletingPathExtension().appendingPathExtension("pkg")
        let entryValues = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let packageValues = type == "scene" ? (try? package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])) : nil
        let exists = (entryValues?.isRegularFile == true && entryValues?.isSymbolicLink != true
                      && (!requireNonemptyContent || (entryValues?.fileSize ?? 0) > 0))
            || (packageValues?.isRegularFile == true && packageValues?.isSymbolicLink != true
                && (!requireNonemptyContent || (packageValues?.fileSize ?? 0) > 0))
        guard exists else {
            throw ImportError(message: String(localized: "Missing project content: \(file). Copy the complete wallpaper folder, not just project.json."))
        }
        if let preview = manifest["preview"] as? String, !preview.isEmpty, !isSafeRelativePath(preview) {
            throw ImportError(message: String(localized: "The preview path must remain inside the wallpaper folder."))
        }
        if let dependencies = manifest["dependencies"] as? [String], dependencies.contains(where: { !isSafeRelativePath($0) }) {
            throw ImportError(message: String(localized: "Project dependency paths may not escape their folder."))
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func isWithin(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path.hasSuffix("/") ? parent.path : parent.path + "/")
    }

    private func copySafely(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else {
            throw ImportError(message: String(localized: "Symbolic links are not imported: \(source.lastPathComponent). Copy the original content into the project folder first."))
        }
        if values.isDirectory == true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            for child in children {
                try copySafely(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else if values.isRegularFile == true {
            guard fm.createFile(atPath: destination.path, contents: nil) else {
                throw ImportError(message: String(localized: "Could not create \(destination.lastPathComponent). Check available disk space and folder permissions."))
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } else {
            throw ImportError(message: String(localized: "Unsupported special file: \(source.lastPathComponent). Only regular files and folders can be imported."))
        }
    }
}
