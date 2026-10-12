import AVFoundation
import AppKit

/// Keeps one native video window per display in step with the bridge's
/// committed native video wallpapers.
///
/// This is the experimental backend's whole host side. The bridge decides
/// which wallpapers are eligible and stops giving them to the scene engine;
/// this host either plays them or hands them back. It never runs alongside the
/// scene engine for the same wallpaper, and it never silently substitutes a
/// setting it cannot honour.
@MainActor
final class NativeVideoWallpaperHost {
    private let fetch: @MainActor () async throws -> [BridgeNativeVideoWallpaper]
    private let reject: @MainActor (String, UInt64, String) async throws -> Void
    private let screens: @MainActor () -> [(id: UInt32, frame: NSRect)]
    /// Decides whether a wallpaper can be honoured. Injected so the routing and
    /// fallback rules can be tested without an asset or a window server.
    private let refusal: @MainActor (URL, UInt32) async -> NativeVideoRefusal?
    /// Builds one display's surface. Injected so the routing and suspension
    /// rules can be exercised without opening a desktop window.
    private let makeSurface: @MainActor (URL, NSRect, RuntimeSurfaceKey, Bool) -> NativeVideoSurface
    private let counters: RuntimeCounters
    private let frameCenter: NotificationCenter

    private var surfaces: [UInt32: NativeVideoSurface] = [:]
    private var descriptors: [UInt32: BridgeNativeVideoWallpaper] = [:]
    /// The `load#N` each display's current clip was logged under, so a later
    /// playback failure is attributed to the load it belongs to.
    private var logLoads: [UInt32: UInt64] = [:]
    /// Displays suspended on their own, kept apart from the global flag so one
    /// occluded screen cannot stop a video on a visible screen.
    private var suspendedDisplays: Set<UInt32> = []
    private var suspended = false
    /// Admission keys with a refusal report in flight right now.
    ///
    /// Deliberately NOT a permanent record. The bridge is the authority on
    /// which wallpapers are refused, and it keys them per (wallpaper, display
    /// slot); a second permanent set here could only ever disagree with it.
    /// It did: a key refused, then superseded, then returned to would be
    /// pruned by the bridge and offered again, while this set went on skipping
    /// it forever — leaving that display with the native backend selected, the
    /// scene engine excluded, and nothing on screen. This set now only stops
    /// the same refusal being reported twice while one report is outstanding.
    private var reportingRefusal: Set<UInt64> = []
    /// Decisions already taken this session, so a display reconfiguration does
    /// not re-read the same file. Bounded, and cleared on shutdown.
    private var admissionCache: [UInt64: NativeVideoRefusal?] = [:]
    private var admissionCacheOrder: [UInt64] = []
    static let admissionCacheLimit = 16
    /// How many times one offer's metadata is re-read after an unsettled
    /// failure before the wallpaper is handed to the scene engine. Bounded so
    /// a file that never loads cannot leave a display blank indefinitely, and
    /// greater than one so a single transient error is not a demotion.
    static let admissionAttemptLimit = 3
    static let admissionRetryDelay = Duration.milliseconds(150)
    private var surfaceGeneration: UInt64 = 0
    private var reconcileInFlight = false
    private var reconcileRequested = false
    private var stopped = false
    private var posterObserver: NSObjectProtocol?

    var onError: (@MainActor (String) -> Void)?
    var onSurfacesChanged: (@MainActor () -> Void)?
    var onStateChanged: (@MainActor (HostWallpaperState) -> Void)?
    private var states: [UInt32: HostWallpaperState] = [:]

    init(
        fetch: @escaping @MainActor () async throws -> [BridgeNativeVideoWallpaper],
        reject: @escaping @MainActor (String, UInt64, String) async throws -> Void,
        screens: (@MainActor () -> [(id: UInt32, frame: NSRect)])? = nil,
        refusal: (@MainActor (URL, UInt32) async -> NativeVideoRefusal?)? = nil,
        makeSurface: (
            @MainActor (URL, NSRect, RuntimeSurfaceKey, Bool) -> NativeVideoSurface
        )? = nil,
        frameCenter: NotificationCenter = .default,
        counters: RuntimeCounters? = nil
    ) {
        self.fetch = fetch
        self.reject = reject
        self.screens = screens ?? { WebWallpaperHost.systemScreens() }
        self.refusal = refusal ?? { url, fps in
            await NativeVideoAdmission.evaluate(url: url, targetFps: fps)
        }
        let sharedCounters = counters ?? .shared
        self.makeSurface = makeSurface ?? { url, frame, surface, paused in
            let player = NativeVideoPlayer(
                surface: surface, counters: sharedCounters, paused: paused)
            let window = NativeVideoWallpaperWindow(frame: frame, player: player)
            player.load(url: url)
            return window
        }
        self.frameCenter = frameCenter
        self.counters = counters ?? .shared
    }

    convenience init(bridge: WallpaperBridge) {
        self.init(
            fetch: { try await bridge.nativeVideoWallpapers() },
            reject: { id, admissionKey, reason in
                try await bridge.rejectNativeVideo(
                    wallpaperId: id, admissionKey: admissionKey, reason: reason)
            })
    }

    var activeDisplayIDs: Set<UInt32> { Set(surfaces.keys) }
    var isEmpty: Bool { surfaces.isEmpty }

    /// Whether this display's player is running. The observable the suspension
    /// rules are argued from: a decision delivered is not a player stopped.
    func isPlaying(displayID: UInt32) -> Bool? {
        surfaces[displayID]?.isPlaying
    }

    var surfaceGenerationForTest: UInt64 { surfaceGeneration }

    func start() {
        guard posterObserver == nil else { return }
        posterObserver = frameCenter.addObserver(
            forName: DesktopPosterNotification.request,
            object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.answerPosterRequest(notification) }
        }
        stopped = false
    }

    /// Re-reads the committed native wallpapers and diffs them against open
    /// windows. Overlapping calls coalesce into one trailing pass.
    ///
    /// A descriptor's `paused` is the bridge's composed flag: Play/Pause, the
    /// battery Pause, and presentation, global and per display. A presentation
    /// change returns no snapshot, so whoever delivers one calls this once the
    /// bridge has committed it (`WallpaperHosts.reconcile`). Without that, a
    /// pass that ran while the desktop was covered leaves the clip user-paused
    /// by a reading that is out of date the moment the desktop is uncovered.
    func reconcile() {
        guard !stopped else { return }
        guard !reconcileInFlight else {
            reconcileRequested = true
            return
        }
        reconcileInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.reconcileInFlight = false
                if self.reconcileRequested {
                    self.reconcileRequested = false
                    self.reconcile()
                }
            }
            do {
                let wallpapers = try await self.fetch()
                guard !self.stopped else { return }
                await self.apply(wallpapers)
            } catch {
                AppLog.error("native video wallpapers could not be read: \(error.localizedDescription)")
                self.onError?(error.localizedDescription)
            }
        }
    }

    func apply(_ wallpapers: [BridgeNativeVideoWallpaper]) async {
        let screenFrames = Dictionary(
            screens().map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var wanted: [UInt32: BridgeNativeVideoWallpaper] = [:]
        for wallpaper in wallpapers where screenFrames[wallpaper.displayId] != nil {
            wanted[wallpaper.displayId] = wallpaper
        }
        for (displayID, var state) in states where wanted[displayID] == nil {
            state.phase = .closed
            onStateChanged?(state)
            states.removeValue(forKey: displayID)
        }

        // Close first. A wallpaper that moved to another backend, or to another
        // display, must stop playing here before anything else starts, so the
        // clip is never decoded or heard twice.
        for (displayID, surface) in surfaces where wanted[displayID] == nil {
            close(displayID: displayID, surface: surface)
        }
        // A surface is bound to the admission key it was accepted under, not
        // just to a wallpaper id. When the key changes the decision that
        // allowed this player to run no longer applies to what is being asked
        // for: lowering the target rate under a running 60 fps clip, or
        // replacing the media at the same path, both leave the id untouched.
        // Keeping the player would be the silent rate change, or the stale
        // file, that admission exists to prevent — so the surface is torn down
        // and the new identity goes through admission from the start.
        for (displayID, wallpaper) in wanted {
            guard let existing = descriptors[displayID], let surface = surfaces[displayID] else {
                continue
            }
            if existing.wallpaperId != wallpaper.wallpaperId
                || existing.admissionKey != wallpaper.admissionKey
            {
                close(displayID: displayID, surface: surface)
            }
        }

        for (displayID, wallpaper) in wanted.sorted(by: { $0.key < $1.key }) {
            // No local skip list. If the bridge is still offering this key,
            // this host must either play it or say again that it cannot —
            // silently ignoring an offer is how a display ends up with no
            // backend at all.
            if let surface = surfaces[displayID] {
                if let frame = screenFrames[displayID] { surface.setScreenFrame(frame) }
                update(surface: surface, with: wallpaper, displayID: displayID)
                continue
            }
            guard let frame = screenFrames[displayID] else { continue }
            await open(wallpaper: wallpaper, displayID: displayID, frame: frame)
        }
        notifySurfacesChanged()
    }

    private func open(
        wallpaper: BridgeNativeVideoWallpaper, displayID: UInt32, frame: NSRect
    ) async {
        recordState(wallpaper, phase: .loading)
        let url = URL(fileURLWithPath: wallpaper.mediaPath)
        let load = AppLog.beginLoad("native video", project: wallpaper.mediaPath, detail: """
            wallpaper \(wallpaper.wallpaperId) “\(wallpaper.title)” media \(url.lastPathComponent), \
            \(DiagnosticEnvironment.display(displayID)), fps \(wallpaper.fps) (admission \(wallpaper.admissionFps)), \
            scaling \(wallpaper.scalingMode) x\(wallpaper.scalingFactor), paused \(wallpaper.paused)
            """)
        logLoads[displayID] = load
        // Decided before a window exists, so a refusal never shows a black
        // rectangle on the desktop.
        if let refusal = await admission(for: url, wallpaper: wallpaper, load: load) {
            guard !stopped else { return }
            recordState(wallpaper, phase: .failed, message: refusal.reason)
            await handOff(wallpaper: wallpaper, refusal: refusal, load: load)
            return
        }
        guard !stopped else { return }
        surfaceGeneration += 1
        let key = RuntimeSurfaceKey(
            kind: .desktopNativeVideo, displayID: displayID, generation: surfaceGeneration)
        let surface = makeSurface(url, frame, key, wallpaper.paused)
        surfaces[displayID] = surface
        descriptors[displayID] = wallpaper
        // Admission read metadata; this covers the asset failing when it is
        // actually played. The generation is checked on the way back in, so a
        // failure from a surface that has since been replaced cannot condemn
        // its successor.
        surface.onPreparationFailure = { [weak self, weak surface] _, detail in
            guard let surface else { return }
            self?.handlePreparationFailure(
                displayID: displayID, surface: surface, detail: detail)
        }
        surface.onAudioDropped = { [weak self, weak surface] detail in
            guard let self, let surface, self.surfaces[displayID] === surface else { return }
            AppLog.warn(
                "native video wallpaper \(wallpaper.wallpaperId): the platform player could not "
                    + "play the clip with its audio (\(detail)); playing it without sound",
                load: self.logLoads[displayID])
        }
        surface.onReadyForDisplay = { [weak self, weak surface] in
            guard let self, let surface, self.surfaces[displayID] === surface,
                  let current = self.descriptors[displayID] else { return }
            self.recordState(current, phase: .ready)
        }
        // Installing the callback can deliver a failure the player was already
        // holding, and that runs the hand-off synchronously — closing this
        // surface and removing it from the registry before the next line.
        // Presenting anyway would order a stopped window onto the desktop that
        // nothing owns and nothing can close.
        guard surfaces[displayID] === surface else { return }
        update(surface: surface, with: wallpaper, displayID: displayID)
        surface.present()
    }

    /// The player could not play an asset admission had accepted.
    ///
    /// This is a different failure from a metadata refusal and is handled in
    /// the same place, because the outcome has to be the same: the scene
    /// engine takes the wallpaper. Leaving it here would mean a display
    /// showing black with the other backend excluded.
    private func handlePreparationFailure(
        displayID: UInt32, surface: NativeVideoSurface, detail: String
    ) {
        guard !stopped, let wallpaper = descriptors[displayID] else { return }
        // Staleness is identity, not a counter. `surfaceGeneration` is
        // host-wide and moves whenever ANY display opens a surface, so
        // comparing against it discards a live display's real failure as soon
        // as a second display has opened since — which left the first display
        // native-selected with the scene engine excluded, showing black.
        guard surfaces[displayID] === surface else { return }
        let refusal = NativeVideoRefusal.playbackFailed(detail)
        let load = logLoads[displayID]
        // Stop before handing over, so the clip is never being decoded by both
        // backends at once.
        close(displayID: displayID, surface: surface)
        recordState(wallpaper, phase: .failed, message: refusal.reason)
        admissionCache[wallpaper.admissionKey] = refusal
        Task { @MainActor [weak self] in
            await self?.handOff(wallpaper: wallpaper, refusal: refusal, load: load)
            self?.notifySurfacesChanged()
        }
    }

    /// The admission decision for one offer, taken at most once per admission
    /// key. The key already covers the media file's identity and every setting
    /// the decision depends on, so a cache hit cannot return a verdict for a
    /// configuration that has since changed, and a reconcile storm cannot turn
    /// into repeated file reads.
    ///
    /// An unsettled failure — metadata that could not be read, as opposed to
    /// content this backend cannot honour — is retried a bounded number of
    /// times before it is allowed to become a handoff, and is never cached as
    /// a verdict. Without that split, one I/O blip would demote a wallpaper
    /// for the rest of the session; without the bound, a file that never loads
    /// would leave the display showing nothing for as long as it is offered.
    private func admission(
        for url: URL, wallpaper: BridgeNativeVideoWallpaper, load: UInt64?
    ) async -> NativeVideoRefusal? {
        if let cached = admissionCache[wallpaper.admissionKey] { return cached }
        // `admissionFps` is the strictest target across this display's mirror
        // group, not this display's own. A mirror cannot fall back on its own
        // — the engine only ever gives it a scene by copying its source's — so
        // the group is judged together, against the member that constrains it
        // most. Probing `fps` here would let a 60 fps clip accepted for a
        // 60 fps source play unchecked on a 30 fps mirror.
        var decision = await refusal(url, wallpaper.admissionFps)
        var attempt = 1
        while let unsettled = decision, !unsettled.isSettled,
            attempt < Self.admissionAttemptLimit
        {
            attempt += 1
            AppLog.warn(
                "native video wallpaper \(wallpaper.wallpaperId): \(unsettled.reason); "
                    + "retrying (\(attempt)/\(Self.admissionAttemptLimit))", load: load)
            try? await Task.sleep(for: Self.admissionRetryDelay)
            guard !stopped else { return unsettled }
            decision = await refusal(url, wallpaper.admissionFps)
        }
        admissionCache[wallpaper.admissionKey] = decision
        admissionCacheOrder.append(wallpaper.admissionKey)
        while admissionCacheOrder.count > Self.admissionCacheLimit {
            admissionCache.removeValue(forKey: admissionCacheOrder.removeFirst())
        }
        return decision
    }

    private func handOff(
        wallpaper: BridgeNativeVideoWallpaper, refusal: NativeVideoRefusal, load: UInt64?
    ) async {
        guard reportingRefusal.insert(wallpaper.admissionKey).inserted else { return }
        defer { reportingRefusal.remove(wallpaper.admissionKey) }
        counters.record(
            .nativeVideoRefused,
            for: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 0))
        AppLog.warn(
            "native video wallpaper \(wallpaper.wallpaperId): \(refusal.reason); "
                + "falling back to the scene engine", load: load)
        do {
            // The key the decision was taken against travels with the refusal:
            // a verdict that arrives after the configuration changed describes
            // something that no longer exists and must not exclude the new one.
            try await reject(wallpaper.wallpaperId, wallpaper.admissionKey, refusal.reason)
        } catch {
            AppLog.error(
                "native video fallback for \(wallpaper.wallpaperId) failed: "
                    + error.localizedDescription, load: load)
            onError?(error.localizedDescription)
        }
    }

    private func update(
        surface: NativeVideoSurface, with wallpaper: BridgeNativeVideoWallpaper,
        displayID: UInt32
    ) {
        descriptors[displayID] = wallpaper
        surface.setVolume(wallpaper.volume, muted: wallpaper.muted)
        surface.setScaling(wallpaper.scalingMode)
        // The descriptor's paused flag already carries the user's own choice
        // and this display's suspension, as the activation rules combined them.
        surface.setUserPaused(wallpaper.paused)
        surface.setPresentationSuspended(suspended || suspendedDisplays.contains(displayID))
        if surface.isReadyForDisplay { recordState(wallpaper, phase: .ready) }
        else if let prior = states[displayID], prior.startupRevision != wallpaper.startupRevision {
            recordState(wallpaper, phase: prior.phase, message: prior.message)
        }
    }

    private func recordState(
        _ wallpaper: BridgeNativeVideoWallpaper, phase: HostWallpaperState.Phase, message: String? = nil
    ) {
        let state = HostWallpaperState(kind: .nativeVideo, displayID: wallpaper.displayId,
            wallpaperID: wallpaper.wallpaperId, startupRevision: wallpaper.startupRevision,
            nativeAdmissionKey: wallpaper.admissionKey, phase: phase, message: message)
        guard states[wallpaper.displayId] != state else { return }
        states[wallpaper.displayId] = state
        onStateChanged?(state)
    }

    private func close(displayID: UInt32, surface: NativeVideoSurface) {
        if let wallpaper = descriptors[displayID] { recordState(wallpaper, phase: .closed) }
        states.removeValue(forKey: displayID)
        surface.stop()
        surfaces.removeValue(forKey: displayID)
        descriptors.removeValue(forKey: displayID)
    }

    /// Global suspension: no display can show a wallpaper pixel at all.
    func setPresentationSuspended(_ value: Bool) {
        suspended = value
        for (displayID, surface) in surfaces {
            surface.setPresentationSuspended(value || suspendedDisplays.contains(displayID))
        }
    }

    /// One display's own suspension. A hidden screen must not stop a visible
    /// one, and resuming must not clear the global reason.
    func setPresentationSuspended(_ value: Bool, forDisplay displayID: UInt32) {
        if value {
            suspendedDisplays.insert(displayID)
        } else {
            suspendedDisplays.remove(displayID)
        }
        guard let surface = surfaces[displayID] else { return }
        surface.setPresentationSuspended(suspended || value)
    }

    func shutdown() {
        stopped = true
        if let posterObserver {
            frameCenter.removeObserver(posterObserver)
            self.posterObserver = nil
        }
        for (displayID, surface) in surfaces {
            close(displayID: displayID, surface: surface)
        }
        surfaces.removeAll()
        descriptors.removeAll()
        admissionCache.removeAll()
        admissionCacheOrder.removeAll()
    }

    /// Answers a desktop poster request from the player that is already
    /// running. A second player would decode the same clip twice.
    private func answerPosterRequest(_ notification: Notification) {
        guard let layer = notification.object as? CALayer,
            let (displayID, surface) = surfaces.first(where: { $0.value.posterLayer === layer })
        else { return }
        let context = notification.userInfo?["context"] as? String
        Task { @MainActor [weak self] in
            let image = await surface.posterImage()
            guard let self, !self.stopped, let image else { return }
            // The surface that answered must still be this display's surface.
            // A poster produced by a wallpaper that has since been replaced is
            // a frame of the wrong clip, and publishing it would show it.
            guard self.surfaces[displayID] === surface, surface.posterLayer === layer,
                  let frame = DesktopPosterFrame.rgba(image) else { return }
            frame.publish(for: layer, to: self.frameCenter, context: context)
        }
    }

    private func notifySurfacesChanged() {
        onSurfacesChanged?()
    }
}
