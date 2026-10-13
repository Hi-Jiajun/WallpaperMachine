import Foundation

/// What the menu bar menu offers, decided without AppKit so the branching can be tested.
///
/// A Mac with one display (or one that can show its own wallpaper) keeps the flat menu:
/// Previous, Next, Random Wallpaper and Recently used act on that display. With two or more, each
/// display gets a submenu with its own commands, so any of them can be changed without opening the panel.
/// `AppDelegate` gathers the `Input` and turns the entries into `NSMenuItem`s; the update,
/// error and Exit items stay there.
enum StatusMenuModel {
    /// What choosing an item does. Every per-display command names its display.
    enum Command: Equatable {
        case openControlPanel
        case playPause
        case previous(display: String)
        case next(display: String)
        /// A random wallpaper other than the one the display shows; see `AutomationCommand.random`.
        case random(display: String)
        case apply(wallpaper: String, display: String)
        case remove(display: String)
        case startAgain(wallpaper: String, display: String)
        case openInPanel(display: String)
        case lockScreen
    }

    enum Entry: Equatable {
        case command(Command, title: String, checked: Bool)
        case submenu(title: String, entries: [Entry])
        case separator
    }

    struct Recent: Equatable {
        var id: String
        var title: String
    }

    struct Display: Equatable {
        var id: String
        var title: String
        /// What the display shows of its own; nil when it is empty.
        var wallpaperID: String?
        var canPrevious: Bool
        var canNext: Bool
        /// Whether the library holds a wallpaper that can play, is not held back and is not the
        /// one this display shows.
        var canRandom: Bool = false
        /// Wallpapers used on this display, newest use first, that are still in the library.
        var recent: [Recent]
    }

    struct Input: Equatable {
        /// Whether the playback state is the renderer's own, rather than from before a failure.
        var playbackIsCurrent: Bool
        var hasActiveWallpapers: Bool
        var paused: Bool
        /// The displays a command can act on, in menu order (`orderedDisplays`); empty while
        /// the app starts or quits.
        var displays: [Display]
        var canLockScreen: Bool
    }

    /// A display the menu may list, before its order and title are settled.
    struct Candidate: Equatable {
        var id: String
        var title: String
        /// The CoreGraphics id, to find the screen it is on.
        var physicalID: UInt32?
        /// Where the screen's left edge is in the global desktop space.
        var minX: Double
    }

    /// How many recently used wallpapers a display's menu lists.
    static let recentLimit = 10

    static func entries(for input: Input) -> [Entry] {
        var entries: [Entry] = [.command(.openControlPanel, title: String(localized: "Control Panel"), checked: false)]
        var actions: [Entry] = []
        if input.playbackIsCurrent, input.hasActiveWallpapers {
            let title = input.paused ? String(localized: "Play") : String(localized: "Pause")
            actions.append(.command(.playPause, title: title, checked: false))
        }
        if input.displays.count > 1 {
            actions += input.displays.map { .submenu(title: $0.title, entries: submenu(for: $0)) }
        } else if let display = input.displays.first {
            actions += navigation(for: display)
        }
        if input.canLockScreen {
            actions.append(.command(.lockScreen, title: String(localized: "Lock Screen"), checked: false))
        }
        if !actions.isEmpty {
            entries.append(.separator)
            entries += actions
        }
        return entries
    }

    /// The displays a command can act on: enabled, showing a wallpaper of their own rather
    /// than mirroring another, and connected right now. A row's CoreGraphics id comes from the
    /// `(id - Role)` suffix of its renderer title.
    static func eligibleDisplays(_ rows: [BridgeDisplaySettingsRow], connected: Set<UInt32>) -> [BridgeDisplaySettingsRow] {
        rows.filter { row in
            guard row.enabled, row.mode == .standalone,
                  let physicalID = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title)
            else { return false }
            return connected.contains(physicalID)
        }
    }

    /// The main display first (the renderer's `primary`, or the screen macOS lists first, which
    /// has the menu bar), then left to right, so the submenus follow how the screens sit on the
    /// desk. Displays with the same title get ` (2)`, ` (3)` after it, so each submenu can be told apart.
    static func orderedDisplays(_ candidates: [Candidate], mainDisplay: UInt32?) -> [Candidate] {
        func isMain(_ candidate: Candidate) -> Bool {
            candidate.id == "primary" || (mainDisplay != nil && candidate.physicalID == mainDisplay)
        }
        let sorted = candidates.sorted { first, second in
            if isMain(first) != isMain(second) { return isMain(first) }
            if first.minX != second.minX { return first.minX < second.minX }
            return first.id < second.id
        }
        var used = Set<String>()
        return sorted.map { candidate in
            var title = candidate.title
            var count = 1
            while !used.insert(title).inserted {
                count += 1
                title = "\(candidate.title) (\(count))"
            }
            var named = candidate
            named.title = title
            return named
        }
    }

    // MARK: Building blocks

    /// Previous, Next, Random Wallpaper and Recently used for one display; each appears only
    /// when it can act.
    private static func navigation(for display: Display) -> [Entry] {
        var items: [Entry] = []
        if display.canPrevious {
            items.append(.command(.previous(display: display.id), title: String(localized: "Previous Wallpaper"), checked: false))
        }
        if display.canNext {
            items.append(.command(.next(display: display.id), title: String(localized: "Next Wallpaper"), checked: false))
        }
        if display.canRandom {
            items.append(.command(.random(display: display.id), title: String(localized: "Random Wallpaper"), checked: false))
        }
        let recent = display.recent.prefix(recentLimit)
        if !recent.isEmpty {
            items.append(.submenu(title: String(localized: "Recently used"), entries: recent.map {
                .command(.apply(wallpaper: $0.id, display: display.id), title: $0.title, checked: $0.id == display.wallpaperID)
            }))
        }
        return items
    }

    /// One display's submenu. Removing a wallpaper leaves the display empty, and the wallpaper
    /// it showed is the newest in its history, so an empty display offers to start it again.
    private static func submenu(for display: Display) -> [Entry] {
        var groups = [navigation(for: display)]
        if display.wallpaperID != nil {
            groups.append([.command(.remove(display: display.id), title: String(localized: "Remove from Display"), checked: false)])
        } else if let latest = display.recent.first {
            groups.append([.command(.startAgain(wallpaper: latest.id, display: display.id),
                                    title: String(localized: "Start Again"), checked: false)])
        }
        groups.append([.command(.openInPanel(display: display.id), title: String(localized: "Open in Control Panel"), checked: false)])
        var entries: [Entry] = []
        for group in groups where !group.isEmpty {
            if !entries.isEmpty { entries.append(.separator) }
            entries += group
        }
        return entries
    }
}
