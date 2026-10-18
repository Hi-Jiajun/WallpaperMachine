import Foundation

/// What the screen saver shows, resolved from the files the app already keeps.
///
/// The saver is a separate process that the system loads, so it cannot ask the app for
/// its in-memory state. Reading the committed wallpaper selection and the library entry
/// keeps the saver correct across restarts and needs no IPC while the screen is covered.
struct ScreenSaverWallpaper {
    enum Kind {
        case scene
        case video
        case web
    }

    let id: String
    let kind: Kind
    let projectDirectory: URL
    /// The entry a web wallpaper loads; empty for the native renderer.
    let entryFile: String
    let assetsDirectory: URL?
    let propertiesJSON: String?
    let previewURL: URL?
    /// Native renderer frame rate. The saver does not read the app's live cap.
    let fps: UInt32
    /// Whether the app asks the renderer for its native Metal backend.
    let nativeMetalPreferred: Bool

    static var supportRoot: URL {
        if let override = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WallpaperMachine", isDirectory: true)
    }

    /// The wallpaper the primary display shows, or nil while nothing is installed.
    static func current() -> ScreenSaverWallpaper? {
        let support = supportRoot
        guard let id = primaryWallpaperID(support: support) else { return nil }
        return wallpaper(id: id, support: support)
    }

    static func wallpaper(id: String, support: URL) -> ScreenSaverWallpaper? {
        let project = support.appendingPathComponent("Library/\(id)", isDirectory: true)
        let manifest = project.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: manifest),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = metadata["type"] as? String
        else { return nil }

        let kind: Kind
        switch type.lowercased() {
        case "scene": kind = .scene
        case "video": kind = .video
        case "web": kind = .web
        default: return nil
        }

        let preview = (metadata["preview"] as? String).map {
            project.appendingPathComponent($0)
        }
        let assets = kind == .scene ? sceneAssetsRoot(support: support) : nil
        if kind == .scene, assets == nil { return nil }
        let properties = propertyOverrides(id: id, support: support)

        return ScreenSaverWallpaper(
            id: id,
            kind: kind,
            projectDirectory: project,
            entryFile: metadata["file"] as? String ?? "",
            assetsDirectory: assets,
            propertiesJSON: properties,
            previewURL: preview,
            fps: 30,
            nativeMetalPreferred: prefersNativeMetal(support: support))
    }

    // MARK: - Selection

    /// `config.toml` keeps one `[[monitors]]` block per display. The primary block is the
    /// one the saver shows; a layout without one falls back to the first assigned wallpaper.
    static func primaryWallpaperID(support: URL) -> String? {
        let config = support.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        let blocks = monitorBlocks(in: text).filter {
            ($0["enabled"] ?? "true").lowercased() != "false"
                && ($0["wallpaper"]?.isEmpty == false)
        }
        let primary = blocks.first { ($0["kind"] ?? "").lowercased() == "primary" }
        return (primary ?? blocks.first)?["wallpaper"]
    }

    static func monitorBlocks(in text: String) -> [[String: String]] {
        var blocks: [[String: String]] = []
        var current: [String: String]?
        func flush() {
            if let current { blocks.append(current) }
            current = nil
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[[") {
                flush()
                if line == "[[monitors]]" { current = [:] }
                continue
            }
            if line.hasPrefix("[") {
                flush()
                continue
            }
            guard current != nil, !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.firstIndex(of: "#") { value = String(value[..<comment]) }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            current?[key] = value
        }
        flush()
        return blocks
    }

    // MARK: - Renderer inputs

    /// Flat `{ property: value }` renderer overrides. An empty map is left to the scene's
    /// own defaults, exactly like a wallpaper the user never edited.
    static func propertyOverrides(id: String, support: URL) -> String? {
        let record = support.appendingPathComponent("wallpapers/\(id).json")
        guard let data = try? Data(contentsOf: record),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let overrides = object["property_overrides"] as? [String: Any],
              !overrides.isEmpty,
              let encoded = try? JSONSerialization.data(withJSONObject: overrides, options: [.sortedKeys])
        else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// The app stores this as `scene_renderer = "native_metal_preferred"` at the top
    /// level. The saver links the renderer directly, so it has to carry the same
    /// preference the app would have applied through the bridge.
    static func prefersNativeMetal(support: URL) -> Bool {
        let config = support.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("scene_renderer"), let equals = line.firstIndex(of: "=")
            else { continue }
            return line[line.index(after: equals)...].contains("native_metal")
        }
        return false
    }

    /// The shared Wallpaper Engine assets the scene renderer reads shaders and materials
    /// from. Mirrors `ClientPaths.assetsURL` without depending on the app's defaults.
    static func sceneAssetsRoot(support: URL) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let configured = CFPreferencesCopyAppValue(
            "WallpaperMachineAssetsPath" as CFString, "app.wallpapermachine" as CFString) as? String,
           !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        candidates.append(support.appendingPathComponent("SceneAssets", isDirectory: true))
        candidates.append(
            home.appendingPathComponent(
                "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets",
                isDirectory: true))
        candidates.append(
            support.appendingPathComponent(
                "Steam/steamapps/common/wallpaper_engine/assets", isDirectory: true))
        return candidates.first(where: hasSceneAssets)
    }

    static func hasSceneAssets(_ url: URL) -> Bool {
        ["shaders/genericimage2.vert", "shaders/genericimage2.frag",
         "materials/util/effectpassthrough.json"].allSatisfy { path in
            let file = url.appendingPathComponent(path)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0
            else { return false }
            return FileManager.default.isReadableFile(atPath: file.path)
        }
    }
}
