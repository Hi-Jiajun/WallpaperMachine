import Foundation

/// Changes wallpapers on the displays whose playlist rotates or follows the day.
///
/// One timer waits for the earliest change. A change only happens while wallpapers are
/// playing and presenting: one that falls due while the user has paused, the screen is locked
/// or the displays sleep waits, and happens once, when `evaluate()` next finds playback
/// running. The app delegate calls `evaluate()` when playback or presentation changes, so
/// nothing is polled. Every switch runs through the display's command slot, the same one the
/// panel and the menu bar use, so the latest request for a display wins.
@MainActor
final class PlaylistScheduler {
    /// Runs one switch on `display` through its command slot. `choose` names the wallpaper when
    /// the switch's turn comes, or nil to skip it. Answers the wallpaper applied, or nil when
    /// nothing was: a newer request replaced this one, or there was nothing to choose.
    typealias Activate = @MainActor (_ display: String, _ choose: @MainActor () -> String?) async throws -> String?

    private let store: PlaylistStore
    private let collections: WallpaperCollectionStore
    private let displays: @MainActor () -> [String]
    private let library: @MainActor () -> [String]
    private let favorites: @MainActor () -> Set<String>
    private let current: @MainActor (String) -> String?
    private let isRunning: @MainActor (String) -> Bool
    private let activate: Activate
    private let commandRevision: @MainActor (String) -> UInt64
    private let now: @MainActor () -> Date
    private let calendar: Calendar
    private let center: NotificationCenter
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var observers: [NSObjectProtocol] = []
    private var timer: Task<Void, Never>?
    private var armedFor: Date?
    private var inFlight = Set<String>()
    /// Displays someone asked to move along while the timer's own change was waiting its turn:
    /// that change then runs as asked for, even if the display paused meanwhile.
    private var requestedWhileInFlight = Set<String>()
    /// The day or night period each display was last brought into line with, and the playlist
    /// it was brought into line under: a wallpaper the user applies by hand stays until the next
    /// period, and choosing a different day or night wallpaper applies at once.
    private var settledPeriods: [String: (period: Date, revision: UInt64)] = [:]
    private var random = SystemRandomNumberGenerator()
    static let failureCooldown: TimeInterval = 15 * 60
    /// A broken library must not monopolize the command queue in one automatic change.
    static let maximumAttempts = 5

    init(
        store: PlaylistStore,
        collections: WallpaperCollectionStore,
        displays: @escaping @MainActor () -> [String],
        library: @escaping @MainActor () -> [String],
        favorites: @escaping @MainActor () -> Set<String>,
        current: @escaping @MainActor (String) -> String?,
        isRunning: @escaping @MainActor (String) -> Bool,
        activate: @escaping Activate,
        commandRevision: @escaping @MainActor (String) -> UInt64 = { _ in 0 },
        now: (@MainActor () -> Date)? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        center: NotificationCenter = .default,
        // The continuous clock keeps counting while the Mac sleeps, so a change that fell due
        // during sleep happens on wake rather than an interval of awake time later.
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(max(0, seconds)))
        }
    ) {
        self.store = store
        self.collections = collections
        self.displays = displays
        self.library = library
        self.favorites = favorites
        self.current = current
        self.isRunning = isRunning
        self.activate = activate
        self.commandRevision = commandRevision
        self.now = now ?? { Date() }
        self.calendar = calendar
        self.center = center
        self.sleep = sleep
    }

    func start() {
        guard observers.isEmpty else {
            evaluate()
            return
        }
        // A clock or time-zone change moves every day and night boundary; the store changes when
        // the user edits a playlist or a change is dated.
        let names: [(Notification.Name, AnyObject?)] = [
            (PlaylistStore.didChangeNotification, store),
            (WallpaperCollectionStore.didChangeNotification, collections),
            (.NSSystemClockDidChange, nil),
            (.NSSystemTimeZoneDidChange, nil),
        ]
        for (name, object) in names {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        evaluate()
    }

    func stop() {
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.cancel()
        timer = nil
        armedFor = nil
    }

    /// A restored/manual choice in a day/night plan stays until its next boundary.
    func holdCurrentPeriod(_ display: String) {
        let playlist = store.playlist(for: display)
        guard playlist.mode == .dayNight else { return }
        let phase = PlaylistPlanner.phase(at: now(), dayStart: playlist.dayStart, nightStart: playlist.nightStart, calendar: calendar)
        settledPeriods[display] = (phase.until, store.revisions[display] ?? 0)
    }

    /// The longest a rotating display leaves a wallpaper the user just applied alone, whatever
    /// the deadline it was heading for.
    static let manualGrace: TimeInterval = 5 * 60

    /// The user applied a wallpaper to `display` by hand. A rotation that was about to replace
    /// it moments later waits `min(interval, manualGrace)` from now instead: a deadline that
    /// falls due sooner is pushed back to that point, and a later one is never shortened, so a
    /// long interval keeps its rhythm. A paused display whose deadline already passed is pushed
    /// back too, so it does not swap the moment playback resumes. Day and night already keeps a
    /// hand-picked wallpaper until its next boundary, and an Off display has nothing to hold.
    func noteManualChoice(_ display: String) {
        let playlist = store.playlist(for: display)
        guard playlist.mode == .rotate, let due = store.nextChange[display] else { return }
        let date = now()
        let held = date.addingTimeInterval(min(Self.seconds(playlist.interval), Self.manualGrace))
        guard due < held else { return }
        // Dating the change posts the store's notification, which re-arms the single timer.
        store.schedule(display, at: held)
        AppLog.info("playlist: a manual choice on display \(display) holds the rotation for \(Int(held.timeIntervalSince(date))) s")
    }

    /// Makes every change that is due, dates the next ones and arms the timer for the earliest.
    func evaluate() {
        guard !observers.isEmpty else { return }
        let date = now()
        var earliest: Date?
        for display in displays() {
            let playlist = store.playlist(for: display)
            let running = isRunning(display)
            if store.holds[display] != nil {
                // A wallpaper on the display again, from anyone, ends the wait: the user, a
                // rule, a Space or a Focus put it there, and each is a choice. The playlist then
                // counts a whole interval from now (or, for day and night, leaves what is on
                // screen until its next boundary), never a deadline it kept while the display
                // was empty.
                guard playlist.mode == .off || current(display) != nil else {
                    // Nothing is due while the display waits, so no deadline or timer exists.
                    store.schedule(display, at: nil)
                    settledPeriods[display] = nil
                    continue
                }
                // Settle the period before lifting: lifting posts the store's notification.
                if playlist.mode == .dayNight {
                    let until = PlaylistPlanner.phase(
                        at: date, dayStart: playlist.dayStart, nightStart: playlist.nightStart, calendar: calendar).until
                    settledPeriods[display] = (until, store.revisions[display] ?? 0)
                }
                store.setHold(nil, on: display)
                AppLog.info("playlist: display \(display) has a wallpaper again, so its playlist carries on")
            }
            switch playlist.mode {
            case .off:
                store.schedule(display, at: nil)
                settledPeriods[display] = nil
            case .rotate:
                settledPeriods[display] = nil
                guard let due = store.nextChange[display] else {
                    let next = date.addingTimeInterval(Self.seconds(playlist.interval))
                    store.schedule(display, at: next)
                    earliest = min(earliest ?? next, next)
                    continue
                }
                if due > date {
                    earliest = min(earliest ?? due, due)
                } else if running, !inFlight.contains(display) {
                    rotate(display, playlist: playlist)
                }
            case .dayNight:
                let (phase, until) = PlaylistPlanner.phase(
                    at: date, dayStart: playlist.dayStart, nightStart: playlist.nightStart, calendar: calendar)
                store.schedule(display, at: until)
                earliest = min(earliest ?? until, until)
                let settled = settledPeriods[display]
                guard settled?.period != until || settled?.revision != (store.revisions[display] ?? 0) else { continue }
                guard running, !inFlight.contains(display) else { continue }
                follow(display, phase: phase, period: until, playlist: playlist)
            }
        }
        arm(earliest)
    }

    /// Whether `skip(_:)` has a playlist wallpaper to change `display` to.
    func canSkip(_ display: String) -> Bool {
        let playlist = store.playlist(for: display)
        guard playlist.mode == .rotate else { return false }
        let candidates = availableCandidates(for: playlist, on: display)
        return candidates.contains { $0 != current(display) }
    }

    /// Changes `display` to its playlist's next wallpaper now, whatever the timer says, and
    /// starts a fresh interval. Someone asked for it, so it happens while the display is paused
    /// or covered too, and a change already under way counts as the answer. Returns false when
    /// the display does not rotate, so the caller can fall back to the library order, or when
    /// its playlist has no other wallpaper to change to. It also ends the wait of a display the
    /// user emptied.
    @discardableResult
    func skip(_ display: String) -> Bool {
        let playlist = store.playlist(for: display)
        guard playlist.mode == .rotate, displays().contains(display) else { return false }
        if inFlight.contains(display) {
            store.setHold(nil, on: display)
            requestedWhileInFlight.insert(display)
            return true
        }
        guard canSkip(display) else { return false }
        // Asking for a change is asking a display the user emptied to be filled.
        store.setHold(nil, on: display)
        rotate(display, playlist: playlist, requested: true)
        return true
    }

    /// The user wants a playlist that waited because they removed the wallpaper to run again.
    /// A rotation fills the display now and starts a fresh interval; day and night puts the
    /// wallpaper for the current half of the day back as soon as the display can play. Does
    /// nothing for a display that is not waiting.
    func resume(_ display: String) {
        guard store.holds[display] != nil else { return }
        settledPeriods[display] = nil
        store.setHold(nil, on: display)
        AppLog.info("playlist: display \(display) resumed after its wallpaper was removed")
        if store.playlist(for: display).mode == .rotate, skip(display) { return }
        evaluate()
    }

    /// A change the timer brings waits while the display cannot play; a `requested` one does not.
    private func rotate(_ display: String, playlist: DisplayPlaylist, requested: Bool = false) {
        let revision = store.revisions[display] ?? 0
        inFlight.insert(display)
        Task {
            var attempted = false
            defer {
                inFlight.remove(display)
                // A change asked for while this one waited rode on it. If this one was dropped
                // unmade (the playlist changed meanwhile), the asked-for change is made on its own.
                let unanswered = requestedWhileInFlight.remove(display) != nil && !attempted
                let remade = unanswered && skip(display)
                if remade {
                    // That change schedules the next interval once it is made.
                } else if (attempted || isRunning(display)), (store.revisions[display] ?? 0) == revision,
                          store.holds[display] == nil {
                    store.schedule(display, at: now().addingTimeInterval(Self.seconds(playlist.interval)))
                } else {
                    evaluate()
                }
            }
            var tried = Set<String>()
            for _ in 0..<Self.maximumAttempts {
                var selected: String?
                var command: UInt64?
                var candidates: [String] = []
                do {
                    let applied = try await activate(display) { [self] in
                        guard !observers.isEmpty, (store.revisions[display] ?? 0) == revision,
                            displays().contains(display),
                            requested || requestedWhileInFlight.contains(display) || isRunning(display),
                            // The user may have emptied the display while this change waited.
                            store.holds[display] == nil
                        else { return nil }
                        // Resolve membership when the command runs, not when its timer fired.
                        let latest = store.playlist(for: display)
                        candidates = self.availableCandidates(for: latest, on: display).filter { !tried.contains($0) }
                        selected = PlaylistPlanner.next(
                            after: current(display), in: candidates, order: latest.order,
                            recent: store.recent[display] ?? [], using: &random)
                        command = commandRevision(display)
                        attempted = attempted || selected != nil
                        return selected
                    }
                    if let applied, (store.revisions[display] ?? 0) == revision {
                        store.clearFailure(applied, on: display)
                        store.recordPick(applied, on: display, candidates: self.candidates(for: store.playlist(for: display)))
                        AppLog.info("playlist changed display \(display) to \(applied)")
                    }
                    // A nil result means superseded or ineligible, never an instruction to retry.
                    break
                } catch is CancellationError {
                    break
                } catch {
                    guard let selected else { break }
                    attempted = true
                    tried.insert(selected)
                    store.recordFailure(selected, on: display, message: error.localizedDescription,
                                        retryAfter: now().addingTimeInterval(Self.failureCooldown))
                    AppLog.warn("playlist skipped \(selected) on display \(display): \(error.localizedDescription)")
                    guard !observers.isEmpty, (store.revisions[display] ?? 0) == revision,
                          displays().contains(display), command == commandRevision(display),
                          current(display) != selected else { break }
                }
            }
        }
    }
    private func follow(_ display: String, phase: PlaylistPlanner.Phase, period: Date, playlist: DisplayPlaylist) {
        let revision = store.revisions[display] ?? 0
        let target = phase == .day ? playlist.dayWallpaperID : playlist.nightWallpaperID
        guard let target, library().contains(target), current(display) != target else {
            settledPeriods[display] = (period, revision)
            return
        }
        inFlight.insert(display)
        Task {
            var attempted = false
            defer {
                inFlight.remove(display)
                // A day or night switch never answers a rotation someone asked for meanwhile.
                if requestedWhileInFlight.remove(display) != nil { skip(display) }
                if (attempted || isRunning(display)), (store.revisions[display] ?? 0) == revision {
                    settledPeriods[display] = (period, revision)
                }
                evaluate()
            }
            do {
                let applied = try await activate(display) { [self] in
                    guard (store.revisions[display] ?? 0) == revision,
                        displays().contains(display), isRunning(display), library().contains(target),
                        store.holds[display] == nil,
                        PlaylistPlanner.phase(at: now(), dayStart: playlist.dayStart,
                            nightStart: playlist.nightStart, calendar: calendar).until == period
                    else { return nil }
                    attempted = true
                    return current(display) == target ? nil : target
                }
                if applied != nil {
                    AppLog.info("playlist switched display \(display) to its \(phase.rawValue) wallpaper")
                }
            } catch {
                attempted = true
                AppLog.warn("playlist could not switch display \(display) to its \(phase.rawValue) wallpaper: \(error.localizedDescription)")
            }
        }
    }

    private func candidates(for playlist: DisplayPlaylist) -> [String] {
        let ids = playlist.collectionID.flatMap { collections.collection(id: $0)?.wallpaperIDs } ?? []
        return PlaylistPlanner.candidates(
            for: playlist, library: library(), favorites: favorites(), collectionIDs: ids)
    }

    private func availableCandidates(for playlist: DisplayPlaylist, on display: String) -> [String] {
        let date = now()
        return candidates(for: playlist).filter {
            guard let failure = store.skipped[display]?[$0] else { return true }
            return failure.retryAfter <= date
        }
    }

    private func arm(_ date: Date?) {
        guard date != armedFor else { return }
        timer?.cancel()
        timer = nil
        armedFor = date
        guard let date else { return }
        let delay = date.timeIntervalSince(now())
        let sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.armedFor = nil
            self.evaluate()
        }
    }

    static func seconds(_ minutes: Int) -> TimeInterval {
        TimeInterval(max(1, minutes) * 60)
    }
}
