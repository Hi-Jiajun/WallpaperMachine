import Foundation

/// How a display changes wallpaper on its own.
enum PlaylistMode: String, Codable, CaseIterable, Sendable {
    /// The wallpaper changes only when the user changes it.
    case off
    /// A new wallpaper from `PlaylistSource` every `interval` minutes.
    case rotate
    /// One wallpaper by day and another by night, switched at two times of day.
    case dayNight
}

/// Which wallpapers a rotation draws from.
enum PlaylistSource: String, Codable, CaseIterable, Sendable {
    case all
    case favorites
    /// The wallpapers the user added to this display's list, in the order they were added.
    case list
    /// The live membership of a reusable local collection.
    case collection
}

enum PlaylistOrder: String, Codable, CaseIterable, Sendable {
    case sequential
    case shuffle
}

/// One display's playlist. Every field has a default, so a display nobody configured is `off`
/// and a playlist saved by an older build decodes with the fields it lacks filled in.
struct DisplayPlaylist: Codable, Equatable, Sendable {
    /// The intervals the panel's menu offers, in minutes.
    static let intervals = [5, 10, 15, 30, 60, 120, 180, 360, 720, 1440]
    static let minutesPerDay = 24 * 60
    /// Any whole number of minutes from one minute to a week can be typed in as a custom interval.
    static let intervalRange = 1...(7 * minutesPerDay)

    var mode: PlaylistMode = .off
    var source: PlaylistSource = .all
    var order: PlaylistOrder = .sequential
    /// Minutes between changes; one of `intervals` or a custom value in `intervalRange`.
    var interval = 30
    var wallpaperIDs: [String] = []
    var collectionID: String?
    /// Saved plan identity; an actual manual edit detaches the display's copy.
    var planID: String?
    var dayWallpaperID: String?
    var nightWallpaperID: String?
    /// Minutes after local midnight at which the day and the night wallpapers take over.
    var dayStart = 7 * 60
    var nightStart = 19 * 60

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DisplayPlaylist()
        mode = (try? container.decodeIfPresent(PlaylistMode.self, forKey: .mode)) ?? fallback.mode
        source = (try? container.decodeIfPresent(PlaylistSource.self, forKey: .source)) ?? fallback.source
        order = (try? container.decodeIfPresent(PlaylistOrder.self, forKey: .order)) ?? fallback.order
        let interval = (try? container.decodeIfPresent(Int.self, forKey: .interval)) ?? fallback.interval
        self.interval = Self.intervalRange.contains(interval) ? interval : fallback.interval
        wallpaperIDs = (try? container.decodeIfPresent([String].self, forKey: .wallpaperIDs)) ?? []
        collectionID = try? container.decodeIfPresent(String.self, forKey: .collectionID)
        planID = try? container.decodeIfPresent(String.self, forKey: .planID)
        dayWallpaperID = try? container.decodeIfPresent(String.self, forKey: .dayWallpaperID)
        nightWallpaperID = try? container.decodeIfPresent(String.self, forKey: .nightWallpaperID)
        dayStart = Self.minuteOfDay((try? container.decodeIfPresent(Int.self, forKey: .dayStart)) ?? nil)
            ?? fallback.dayStart
        nightStart = Self.minuteOfDay((try? container.decodeIfPresent(Int.self, forKey: .nightStart)) ?? nil)
            ?? fallback.nightStart
    }

    /// A minute of the day, or nil when `value` is missing or outside 0..<1440.
    static func minuteOfDay(_ value: Int?) -> Int? {
        guard let value, (0..<minutesPerDay).contains(value) else { return nil }
        return value
    }
}

/// A reusable playlist configuration with no display identity or timer state.
struct PlaylistPlan: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var name: String
    var playlist: DisplayPlaylist
}
