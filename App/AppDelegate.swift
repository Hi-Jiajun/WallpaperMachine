import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var controlPanelWindow: NSWindow?
    private var whatsNewWindow: NSWindow?
    private var previewWindow: WallpaperPreviewWindowController?
    private lazy var whatsNewStore = WhatsNewStore()
    private let controlPanelNavigation = ControlPanelNavigation()
    private lazy var workshopStore = WorkshopStore()
    private lazy var pixivStore = PixivStore()
    private lazy var libraryImports = LibraryImportStore()
    /// Files handed to the app before it finished launching, imported once it has.
    private var pendingOpenedFiles: [URL] = []
    private var finishedLaunching = false
    private lazy var appUpdater = AppUpdateStore()
    private var automaticUpdates: Task<Void, Never>?
    /// The version the unattended check last prompted for; "Later" holds until the next launch.
    private var promptedUpdateVersion: String?
    private var displayChangeObserver: NSObjectProtocol?
    private lazy var displayRefresh = DisplayRefreshCoalescer { [weak self] in
        guard let self else { return false }
        return await self.refreshDisplaysFromSystemEvent()
    }
    private var desktopWallpaperSync: DesktopWallpaperSync?
    private var desktopMediaSession: DesktopMediaSession?
    private var sceneMediaSink: SceneMediaSink?
    private var webWallpaperHost: WebWallpaperHost?
    private var nativeVideoHost: NativeVideoWallpaperHost?
    private var presentationPolicy: WallpaperPresentationPolicy?
    private var appRuleMonitor: AppRuleMonitor?
    private var otherAudioMonitor: OtherAudioMonitor?
    private var systemConditionMonitor: SystemConditionMonitor?
    private var playlistScheduler: PlaylistScheduler?
    private var automaticWallpapers: WallpaperAutomationController?
    private var desktopSpaces: WallpaperSpaceMonitor?
    private var posterRefreshTask: Task<Void, Never>?
    private var globalHotKeys: GlobalHotKeys?
    private var playbackPreferencesObserver: NSObjectProtocol?
    private var wallpaperEnergy: WallpaperEnergyRecorder?
    /// Last presentation the bridge accepted, so leaving unloaded clears that flag first.
    private var appliedGlobalPresentation: GlobalPresentation = .running
    private var store: BridgeStore?
    private var startupError: Error?
    private var lastError: Error?
    private var playbackSnapshotCurrent = false
    private var shutdownInProgress = false
    private var shutdownComplete = false
    private var themeSubscription: AnyCancellable?
    private var iconSubscription: AnyCancellable?
    private var diagnostics: RuntimeDiagnosticsSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests need the executable's types, not its desktop lifecycle.
        // UI tests run in a separate runner, so the real app still starts normally.
        if NSClassFromString("XCTestCase") != nil {
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        themeSubscription = AppThemeStore.shared.$preferences
            .map(\.mode).removeDuplicates()
            .sink { mode in NSApp.appearance = mode.appearance }
        iconSubscription = AppThemeStore.shared.$preferences
            .map(\.icon).removeDuplicates()
            .sink { icon in
                do {
                    NSApp.applicationIconImage = try icon.image()
                } catch {
                    AppLog.error("Dock icon \(icon.rawValue) could not load: \(error.localizedDescription)")
                }
            }
        AppLog.info("startup: didFinishLaunching start")
        BridgeEnvironment.configureVulkanICDIfNeeded()
        AppLog.info("startup: vulkan icd configured")
        do {
            try ClientPaths.prepare()
            let created = try BridgeStore()
            store = created
            created.openPreview = { [weak self] selection in self?.showWallpaperPreview(selection) }
            AppLog.attach(created.bridge)
            // Reloading waits for a wallpaper being applied, so a page that lands meanwhile
            // appears once that finishes rather than failing.
            pixivStore.downloads.onInstalled = { [weak created] id in
                created?.supportPrompt?.recordDownload(wallpaperID: id)
                try await created?.refreshLibraryAsync()
            }
            libraryImports.refreshLibrary = { [weak created] in try await created?.refreshLibraryAsync() }
            for line in DiagnosticEnvironment.current() { AppLog.info("environment: \(line)") }
            startupError = nil
            playbackSnapshotCurrent = false
            AppLog.info("startup: BridgeStore created")
        } catch {
            AppLog.detachToStandardError()
            AppLog.error("startup: BridgeStore FAILED: \(error.localizedDescription)")
            startupError = error
            playbackSnapshotCurrent = false
        }
        pixivStore.restoreSession()
        // A crash during a download leaves its staging behind, holding the whole downloaded item.
        let stagingRoot = ClientPaths.supportURL
        let pixivStagingRoot = PixivWallpaperPackager.stagingRoot(forLibrary: ClientPaths.libraryURL)
        let importStagingRoot = WallpaperImportService.stagingRoot(forLibrary: ClientPaths.libraryURL)
        Task.detached(priority: .utility) {
            WorkshopDownloader.removeAbandonedStaging(in: stagingRoot)
            PixivWallpaperPackager.removeAbandonedStaging(in: pixivStagingRoot)
            WallpaperImportService.removeAbandonedStaging(in: importStagingRoot)
        }

        NSApp.setActivationPolicy(.accessory)
        AppLog.info("startup: activation policy set to accessory")
        installStatusItem()
        synchronizeStatusItem()
        installDisplayChangeObserver()
        AppLog.info("startup: display change observer installed")
        installApplicationMenu()
        AppLog.info("startup: application menu installed")
        if let store {
            workshopStore.startDownloadLifecycle(bridge: store)
            let lockScreen = LockScreenConfiguration.isSupportedBySystem
                ? LockScreenWallpaperService(bridge: store.bridge, contentRevision: { [weak store] in store?.wallpaperContentRevision ?? 0 }) : nil
            if let lockScreen {
                store.lockScreenWallpaper = lockScreen
                lockScreen.beforeActivation = { [weak self] in
                    guard let self else { return }
                    if self.desktopWallpaperSync == nil {
                        self.desktopWallpaperSync = try DesktopWallpaperSync(
                            folder: ClientPaths.supportURL.appendingPathComponent("DesktopPosters"))
                    }
                    self.desktopWallpaperSync?.suspendForNativeProvider()
                }
                lockScreen.afterDeactivation = { [weak self] in
                    guard let self, !self.shutdownInProgress else { return }
                    self.desktopWallpaperSync = nil
                    try self.startDesktopWallpaperSync()
                }
            }
            let mediaScheduler = FoundationMediaTimerScheduler()
            let mediaSession = DesktopMediaSession(
                provider: FallbackSystemMediaProvider(
                    primary: AdapterSystemMediaProvider(scheduler: mediaScheduler),
                    fallback: AppleScriptMediaProvider(scheduler: mediaScheduler),
                    scheduler: mediaScheduler))
            desktopMediaSession = mediaSession
            let webHost = WebWallpaperHost(bridge: store.bridge, mediaRelay: mediaSession.relay,
                contentRevision: { [weak store] in store?.wallpaperContentRevision ?? 0 })
            webWallpaperHost = webHost
            webHost.onStateChanged = { [weak store] state in store?.receiveHostState(state) }
            webHost.onDeliveryStateChanged = { [weak store] in store?.webWallpaperDeliveryRevision &+= 1 }
            webHost.onAssetsChanged = { [weak store] in
                store?.wallpaperContentRevision &+= 1
                if store?.lockScreenWallpaper?.canRefreshAutomatically == true { store?.lockScreenWallpaper?.refresh() }
            }
            store.retryHostWallpaper = { [weak webHost] wallpaperID, displayID in
                webHost?.retry(wallpaperID: wallpaperID, displayID: displayID)
            }
            store.invalidateHostAsset = { [weak webHost] wallpaperID, propertyID in
                webHost?.invalidateAsset(wallpaperID: wallpaperID, propertyID: propertyID)
            }
            store.sceneMediaAvailability = { [weak mediaSession] in
                mediaSession?.availability ?? .unavailable(reason: String(localized: "Media integration has not been started."))
            }
            sceneMediaSink = SceneMediaSink(
                session: mediaSession,
                submit: { json in
                    try await store.bridge.submitSystemMediaEvent(json: json)
                },
                applyArtwork: { width, height, rgba in
                    try await store.bridge.applySystemMediaArtwork(
                        width: width, height: height, rgba: rgba)
                },
                fetchHandles: {
                    await Self.sceneMediaHandles(store: store)
                },
                nextShortcut: {
                    try await store.bridge.nextUserShortcut()
                })
            // The panel distinguishes the user's setting from what is actually
            // being delivered, which only the host knows. The provider is
            // process-wide, so a scene wallpaper can populate it too.
            store.webWallpaperDeliveryStatus = { [weak webHost] in
                webHost?.deliveryStatus ?? WebWallpaperHost.DeliveryStatus()
            }
            webHost.onError = { [weak self] message in
                self?.lastError = WallpaperActionError(message: message)
                self?.rebuildMenu()
            }
            webHost.onSurfacesChanged = { [weak self, weak lockScreen] in
                guard let self, !self.shutdownInProgress else { return }
                self.presentationPolicy?.evaluate()
                guard lockScreen?.ownsDesktopProvider != true else { return }
                do { try self.startDesktopWallpaperSync() } catch {
                    AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
                }
            }
            webHost.start()
            // The experimental native video backend. The bridge returns nothing
            // for it unless the user turned it on, so this host opens no window
            // and starts no player by default.
            let nativeVideo = NativeVideoWallpaperHost(bridge: store.bridge)
            nativeVideoHost = nativeVideo
            nativeVideo.onStateChanged = { [weak store] state in store?.receiveHostState(state) }
            nativeVideo.onError = { [weak self] message in
                self?.lastError = WallpaperActionError(message: message)
                self?.rebuildMenu()
            }
            nativeVideo.onSurfacesChanged = { [weak self] in
                guard let self, !self.shutdownInProgress else { return }
                self.presentationPolicy?.evaluate()
            }
            nativeVideo.start()
            store.onSnapshotApplied = { [weak self, weak lockScreen] in
                guard let self, !self.shutdownInProgress else { return }
                // Any engine change (playback, assignment, quality) ends the interval
                // being measured; its two ends could otherwise match across it.
                self.wallpaperEnergy?.invalidate()
                // Web wallpapers live in host windows; open or close them before
                // the poster sync and the presentation policy look at the desktop.
                self.webWallpaperHost?.reconcile()
                self.sceneMediaSink?.reconcile()
                self.nativeVideoHost?.reconcile()
                self.presentationPolicy?.evaluate()
                // Play, pause and a changed library or display set are when a waiting playlist
                // change can happen.
                self.automaticWallpapers?.scheduler.evaluate()
                self.playlistScheduler?.evaluate()
                if let lockScreen, lockScreen.canRefreshAutomatically {
                    lockScreen.refresh()
                }
                // Posters keep the desktop unless the native provider has it or an animated lock
                // screen is on its way to taking it; a screen saver chosen on its own leaves it here.
                let nativeDesktop = lockScreen.map {
                    $0.ownsDesktopProvider || ($0.isRequested && $0.canRefreshAutomatically && $0.errorMessage == nil)
                } ?? false
                if !nativeDesktop {
                    // A suspended poster sync must never outlive the native provider.
                    do { try self.startDesktopWallpaperSync() } catch {
                        self.lastError = error
                        AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
                    }
                }
            }
            let preferences = PlaybackPreferences.shared
            let appRules = AppRuleMonitor(preferences: preferences)
            let otherAudio = OtherAudioMonitor(preferences: preferences)
            let conditions = SystemConditionMonitor(preferences: preferences, focus: .shared)
            appRuleMonitor = appRules
            otherAudioMonitor = otherAudio
            systemConditionMonitor = conditions
            appRules.onChange = { [weak self] in self?.presentationPolicy?.evaluate() }
            otherAudio.onChange = { [weak self] in self?.presentationPolicy?.evaluate() }
            conditions.onChange = { [weak self] in self?.presentationPolicy?.evaluate() }
            playbackPreferencesObserver = NotificationCenter.default.addObserver(
                forName: PlaybackPreferences.didChangeNotification, object: preferences, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncPlaybackMonitors()
                    self?.presentationPolicy?.evaluate()
                    self?.desktopWallpaperSync?.refreshesPeriodically = preferences.refreshesDesktopPicturePeriodically
                }
            }
            let policy = WallpaperPresentationPolicy(
                displaySleepAction: { preferences.displaySleepAction },
                // Low Power Mode, a hot Mac and a Focus filter act exactly as app rules do.
                appRuleActions: { appRules.actions.union(conditions.actions) },
                otherAudioActive: { otherAudio.isActive },
                otherAudioAction: { preferences.otherAudioAction },
                desktopCoveredAction: { preferences.desktopCoveredAction },
                applyGlobal: { [weak self] presentation, completion in
                    guard let self, let store = self.store,
                          !self.shutdownInProgress, !self.shutdownComplete else {
                        completion(.failure(CancellationError()))
                        return
                    }
                    let hostsSuspended = presentation != .running
                    self.webWallpaperHost?.setPresentationSuspended(hostsSuspended)
                    self.nativeVideoHost?.setPresentationSuspended(hostsSuspended)
                    let leavingUnloaded = self.appliedGlobalPresentation == .unloaded
                        && presentation != .unloaded
                    let resuming = presentation == .running && self.appliedGlobalPresentation != .running
                    self.wallpaperEnergy?.invalidate()
                    Task {
                        do {
                            if leavingUnloaded {
                                try await store.setPresentationUnloadedAsync(false)
                            }
                            switch presentation {
                            case .running:
                                try await store.setPresentationSuspendedAsync(false)
                            case .suspended:
                                try await store.setPresentationSuspendedAsync(true)
                            case .unloaded:
                                try await store.setPresentationSuspendedAsync(true)
                                try await store.setPresentationUnloadedAsync(true)
                            }
                            self.appliedGlobalPresentation = presentation
                            if resuming { self.desktopWallpaperSync?.presentationResumed() }
                            // A playlist change that fell due while presentation was suspended
                            // happens now that it runs again.
                            self.automaticWallpapers?.scheduler.evaluate()
                            self.playlistScheduler?.evaluate()
                            // Presentation suspend commits without producing a
                            // snapshot, so nothing else would recompute who is
                            // still consuming system media. Without this the
                            // adapter process and its timeline ticker keep
                            // running for scenes that stopped presenting, until
                            // some unrelated UI change happens to apply one.
                            self.sceneMediaSink?.reconcile()
                            completion(.success(()))
                        } catch {
                            AppLog.error("presentation suspend failed: \(error.localizedDescription)")
                            completion(.failure(error))
                        }
                    }
                },
                applyAudio: { [weak self] suppressed, completion in
                    guard let self, let store = self.store,
                          !self.shutdownInProgress, !self.shutdownComplete else {
                        completion(.failure(CancellationError()))
                        return
                    }
                    Task {
                        do {
                            try await store.setAudioSuppressedAsync(suppressed)
                            completion(.success(()))
                        } catch {
                            AppLog.error("audio suppress failed: \(error.localizedDescription)")
                            completion(.failure(error))
                        }
                    }
                },
                applyDisplay: { [weak self] displayID, suspended, completion in
                    guard let self, let store = self.store,
                          !self.shutdownInProgress, !self.shutdownComplete else {
                        completion(.failure(CancellationError()))
                        return
                    }
                    self.webWallpaperHost?.setPresentationSuspended(suspended, forDisplay: displayID)
                    self.nativeVideoHost?.setPresentationSuspended(suspended, forDisplay: displayID)
                    self.wallpaperEnergy?.invalidate()
                    Task {
                        do {
                            try await store.setDisplayPresentationSuspendedAsync(
                                displayID: displayID, suspended: suspended)
                            if !suspended { self.desktopWallpaperSync?.presentationResumed() }
                            // As on the global path, a change that fell due while this
                            // display was covered happens now that it shows again.
                            self.automaticWallpapers?.scheduler.evaluate()
                            self.playlistScheduler?.evaluate()
                            // Same reason as the global path: a display going
                            // dark changes the effective consumer set and
                            // produces no snapshot of its own.
                            self.sceneMediaSink?.reconcile()
                            completion(.success(()))
                        } catch {
                            AppLog.error("""
                                presentation suspend for display \(displayID) failed: \
                                \(error.localizedDescription)
                                """)
                            completion(.failure(error))
                        }
                    }
                })
            presentationPolicy = policy
            syncPlaybackMonitors()
            conditions.start()
            policy.start()
            desktopSpaces = .shared
            desktopSpaces?.start()
            startPlaylistScheduler(store: store)
            startAutomaticWallpapers(store: store)
            // The Shortcuts app lists these; commands wait for the handler set after bootstrap.
            AppAutomation.shared.wallpapers = {
                store.librarySnapshot.wallpapers.filter(\.supported).map { (id: $0.id, title: $0.title) }
            }
            AppAutomation.shared.displays = {
                let titles = DisplayTitleResolver.system.resolved()
                return Self.availableAutomationDisplays(store: store).map {
                    (id: $0.displayId, title: titles.title($0.title, displayId: $0.displayId))
                }
            }
            AppAutomation.shared.playlistPlans = { PlaylistStore.shared.plans.map { (id: $0.id, title: $0.name) } }
            AppAutomation.shared.displayLayouts = { WallpaperDisplayLayoutStore.shared.layouts.map { (id: $0.id, title: $0.name) } }
            AppAutomation.shared.propertyPresets = {
                store.librarySnapshot.wallpapers.filter(\.supported).flatMap { wallpaper in
                    WallpaperPresetStore.shared.presets(wallpaperID: wallpaper.id).map {
                        (id: $0.id, title: $0.name, wallpaper: wallpaper.title)
                    }
                }
            }
            let hotKeys = GlobalHotKeys(preferences: .shared)
            hotKeys.onPress = { [weak self] action in self?.runAutomation(action.command) }
            globalHotKeys = hotKeys
            hotKeys.start()
            Task { await WallpaperFocusFilter.refreshState() }
            startWallpaperEnergyRecorder(store: store)
            do {
                try lockScreen?.start()
                if lockScreen?.isRequested != true { try startDesktopWallpaperSync() }
            } catch {
                lastError = error
                AppLog.error("startup: Native wallpaper recovery failed: \(error.localizedDescription)")
            }
        }
        bootstrapStore()
        AppLog.info("startup: bootstrap dispatched")
        startDiagnosticsSessionIfRequested()
        finishedLaunching = true
        let opened = pendingOpenedFiles
        pendingOpenedFiles = []
        let opensPanel = ControlPanelLaunch.opensPanel(
            launchEvent: launchEvent,
            welcomeSeen: ClientPreferences.defaults.bool(forKey: WebPanelController.welcomeSeenKey),
            startupFailed: store == nil)
        if !opensPanel { AppLog.info("startup: launched at login; control panel stays closed") }
        DispatchQueue.main.async { [weak self] in
            if opensPanel { self?.showControlPanel(selection: .wallpaper) }
            self?.showWhatsNewAfterUpdate()
            if !opened.isEmpty { self?.importOpenedFiles(opened) }
        }
    }

    /// Files dropped on the Dock icon, or opened with the app from Finder, go into the library
    /// the way Import does, skipping wallpapers already there. The panel opens on Installed so
    /// the import's progress and report are in view.
    func application(_ application: NSApplication, open urls: [URL]) {
        // `wallpapermachine://` links; see `AutomationCommand` for what they may ask.
        for url in urls where !url.isFileURL {
            guard let command = AutomationCommand(url: url) else {
                AppLog.warn("ignored a link WallpaperMachine does not understand: \(url.absoluteString)")
                continue
            }
            runAutomation(command)
        }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard finishedLaunching else {
            pendingOpenedFiles.append(contentsOf: files)
            return
        }
        importOpenedFiles(files)
    }

    private func importOpenedFiles(_ files: [URL]) {
        guard store != nil, !shutdownInProgress, !shutdownComplete else { return }
        showControlPanel(selection: .wallpaper)
        do {
            try libraryImports.start(files, duplicates: .skip)
        } catch {
            lastError = error
            rebuildMenu()
            presentErrorAlert(error)
        }
    }

    /// Changes wallpapers on displays whose playlist rotates or follows the day. A switch goes
    /// through the display's command slot, like the panel's and the menu bar's, and picks its
    /// wallpaper when its turn comes.
    private func startPlaylistScheduler(store: BridgeStore) {
        let playlists = PlaylistStore.shared
        store.onWallpaperApplied = { [weak self] wallpaper, display in
            playlists.clearFailure(wallpaper, on: display)
            self?.schedulePosterRefresh()
        }
        let scheduler = PlaylistScheduler(
            store: playlists,
            collections: WallpaperCollectionStore.shared,
            displays: {
                store.settingsSnapshot.displays.filter { $0.enabled && $0.mode == .standalone }.map(\.displayId)
            },
            library: { store.librarySnapshot.wallpapers.filter(\.supported).map(\.id) },
            favorites: { Self.favoriteWallpaperIDs() },
            current: { display in
                store.monitorInformationSnapshot.rows.first {
                    $0.displayId == display && $0.mirrorTargetDisplayId == nil && !$0.wallpaperId.isEmpty
                }?.wallpaperId
            },
            isRunning: { [weak self] display in
                guard store.appSnapshot.playbackState == .playing,
                    self?.automaticWallpapers?.scheduler.inFlight.contains(display) != true,
                    let policy = self?.presentationPolicy, policy.globalPresentation == .running,
                    let row = store.settingsSnapshot.displays.first(where: { $0.displayId == display }),
                    let physicalID = ResolvedDisplayTitles.liveDisplayID(display, title: row.title)
                else { return false }
                return !policy.suspendedDisplayIDs.contains(physicalID)
            },
            activate: { display, choose in
                var applied: String?
                try await store.commands.run(slot: BridgeStore.activationSlot(displayId: display)) {
                    guard let id = choose() else { return }
                    try await store.activateWallpaperAsync(id: id, displayId: display)
                    applied = id
                }
                return applied
            }, commandRevision: { display in
                store.commands.revision(for: BridgeStore.activationSlot(displayId: display))
            })
        playlistScheduler = scheduler
        playlists.skipHandler = { [weak scheduler] display in
            guard scheduler?.skip(display) == true else { return false }
            WallpaperAutomationStore.shared.manualChoice?(display)
            return true
        }
        scheduler.start()
    }

    private func startAutomaticWallpapers(store: BridgeStore) {
        guard let playlistScheduler else { return }
        let controller = WallpaperAutomationController(bridge: store, rules: .shared, playlists: .shared, collections: .shared,
            focus: .shared, displays: { Self.availableAutomationDisplays(store: store).map(\.displayId) },
            targetDisplay: { [weak self] in self?.controlPanelNavigation.targetDisplayID ?? "primary" },
            canRun: { [weak self] display in
                guard store.appSnapshot.playbackState == .playing,
                      let policy = self?.presentationPolicy, policy.globalPresentation == .running,
                      let row = store.settingsSnapshot.displays.first(where: { $0.displayId == display }),
                      let physical = ResolvedDisplayTitles.liveDisplayID(display, title: row.title) else { return false }
                return !policy.suspendedDisplayIDs.contains(physical)
            }, playlistScheduler: playlistScheduler, spaceMonitor: desktopSpaces,
            onSettled: { [weak self] in self?.schedulePosterRefresh() })
        automaticWallpapers = controller
        store.onUserWallpaperChoice = { [weak self, weak controller] _, display in
            controller?.scheduler.noteManualChoice(display)
            self?.schedulePosterRefresh()
        }
        controller.scheduler.start()
    }

    /// The panel's favorites, which a playlist can rotate through.
    private static func favoriteWallpaperIDs() -> Set<String> {
        guard let data = ClientPreferences.defaults.data(forKey: WebPanelController.favoriteKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    /// Rates each wallpaper's energy use from background samples while it plays alone.
    /// See `WallpaperEnergyRecorder`; `wallpaperEnergyContext()` decides when a sample
    /// can be credited.
    private func startWallpaperEnergyRecorder(store: BridgeStore) {
        let ratings = WallpaperEnergyRatings(
            file: ClientPaths.supportURL.appendingPathComponent("EnergyRatings.json"))
        store.wallpaperEnergyRatings = ratings
        let recorder = WallpaperEnergyRecorder(
            source: CoalitionEnergySource(), ratings: ratings
        ) { [weak self] in self?.wallpaperEnergyContext() }
        wallpaperEnergy = recorder
        recorder.start()
    }

    /// Nil whenever the app's energy is not one wallpaper's: playback paused or suspended
    /// (display sleep, lock, app rules, Low Power Mode, heat, a Focus filter, other audio,
    /// battery pause), the panel on screen
    /// with its WebKit work, a download running SteamCMD inside the app's coalition or
    /// fetching a pixiv original in the app itself, or a video on the native player,
    /// whose decoding and drawing macOS charges to no coalition of this app.
    private func wallpaperEnergyContext() -> WallpaperEnergyContext? {
        guard let store, let policy = presentationPolicy, !shutdownInProgress,
              previewWindow == nil,
              policy.globalPresentation == .running,
              store.appSnapshot.playbackState == .playing,
              !workshopStore.downloader.isRunning, !pixivStore.downloads.isRunning
        else { return nil }
        if let window = controlPanelWindow, window.isVisible, !window.isMiniaturized,
           window.occlusionState.contains(.visible) {
            return nil
        }
        let settings = store.settingsSnapshot
        let reduced = settings.batteryMode == .reducedQuality && settings.onBatteryPower
        let cap = [settings.frameRateCap, reduced ? settings.batteryTargetFps : nil]
            .compactMap { $0 }.min()
        let connected = Set(WebWallpaperHost.systemScreens().map(\.id))
        let liveDisplays = Dictionary(store.monitorInformationSnapshot.rows.compactMap { row in
            ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title)
                .flatMap { connected.contains($0) ? (row.displayId, $0) : nil }
        }, uniquingKeysWith: { first, _ in first })
        return WallpaperEnergyContext.resolve(
            assignments: store.monitorInformationSnapshot.rows.map {
                (display: $0.displayId, wallpaper: $0.wallpaperId)
            },
            suspendedDisplays: policy.suspendedDisplayIDs,
            nativeVideoDisplays: nativeVideoHost?.activeDisplayIDs ?? [],
            frameRateCap: cap, renderScale: settings.renderScale,
            resolveDisplay: { liveDisplays[$0] })
    }

    /// Opens a bounded diagnostic window when the environment explicitly asks
    /// for one. Absent the variable nothing is started, nothing is counted and
    /// no timer exists: the renderer's counters stay off and the in-process
    /// counters stay outside a session.
    ///
    /// `WALLPAPER_MACHINE_DIAGNOSTICS` is a duration in seconds, and
    /// `WALLPAPER_MACHINE_DIAGNOSTICS_DELAY` optionally opens the window that
    /// many seconds after launch (see `RuntimeDiagnosticsRequest`). One
    /// aggregated report is written to the log when it elapses; nothing is
    /// emitted per frame, and no screenshot, pixel readback or periodic disk
    /// write is involved.
    private func startDiagnosticsSessionIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let store, environment[RuntimeDiagnosticsRequest.durationKey] != nil else { return }
        guard let request = RuntimeDiagnosticsRequest(environment: environment) else {
            AppLog.error("""
                diagnostics not started: \(RuntimeDiagnosticsRequest.durationKey) and \
                \(RuntimeDiagnosticsRequest.delayKey) take whole seconds
                """)
            return
        }
        let session = RuntimeDiagnosticsSession(store: store)
        diagnostics = session
        Task { [weak self] in
            do {
                if request.delay > .zero {
                    try await Task.sleep(for: request.delay)
                    // Quit during the delay: there is nothing left to observe.
                    guard let self, self.diagnostics === session else { return }
                }
                try await session.start(duration: request.duration) { lines in
                    for line in lines { AppLog.info("diagnostics \(line)") }
                    self?.diagnostics = nil
                }
                AppLog.info("diagnostics session open for \(request.duration.components.seconds)s")
            } catch {
                AppLog.error("diagnostics session failed: \(error.localizedDescription)")
                self?.diagnostics = nil
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !shutdownInProgress, !shutdownComplete,
              let window = controlPanelWindow, !window.isVisible else { return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKeys?.stop()
        AppAutomation.shared.handler = nil
        AppAutomation.shared.displays = nil
        AppAutomation.shared.playlistPlans = nil
        AppAutomation.shared.displayLayouts = nil
        AppAutomation.shared.propertyPresets = nil
        automaticWallpapers?.scheduler.stop()
        desktopSpaces?.stop()
        playlistScheduler?.stop()
        stopPlaybackMonitoring()
        wallpaperEnergy?.stop()
        wallpaperEnergy = nil
        presentationPolicy?.stop()
        presentationPolicy = nil
        desktopWallpaperSync?.stop()
        previewWindow?.session.close()
        previewWindow?.close()
        previewWindow = nil
        sceneMediaSink?.shutdown()
        webWallpaperHost?.shutdown()
        nativeVideoHost?.shutdown()
        if let displayChangeObserver {
            NotificationCenter.default.removeObserver(displayChangeObserver)
            self.displayChangeObserver = nil
        }
        if let diagnostics {
            self.diagnostics = nil
            Task { await diagnostics.stop() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The test host must not instantiate services against the user's app-support folder.
        if NSClassFromString("XCTestCase") != nil { return .terminateNow }
        guard !shutdownComplete else {
            return .terminateNow
        }
        guard !shutdownInProgress else {
            return .terminateCancel
        }

        shutdownInProgress = true
        previewWindow?.session.close()
        previewWindow?.close()
        previewWindow = nil
        desktopWallpaperSync?.suspendForNativeProvider()
        // Keep this restorer through native-provider callbacks and reloads.
        let wallpaperRestorer = desktopWallpaperSync
        controlPanelWindow?.orderOut(nil)
        whatsNewWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)

        Task {
            do {
                if let lockScreen = store?.lockScreenWallpaper {
                    try await lockScreen.shutdown {
                        try await wallpaperRestorer?.restoreForTermination()
                    }
                } else {
                    try await wallpaperRestorer?.restoreForTermination()
                }
                globalHotKeys?.stop()
                AppAutomation.shared.handler = nil
                AppAutomation.shared.displays = nil
                AppAutomation.shared.playlistPlans = nil
                AppAutomation.shared.displayLayouts = nil
                AppAutomation.shared.propertyPresets = nil
                automaticWallpapers?.scheduler.stop()
                desktopSpaces?.stop()
                playlistScheduler?.stop()
                stopPlaybackMonitoring()
                wallpaperEnergy?.stop()
                wallpaperEnergy = nil
                presentationPolicy?.stop()
                presentationPolicy = nil
                desktopWallpaperSync = nil
                sceneMediaSink?.shutdown()
                sceneMediaSink = nil
                webWallpaperHost?.shutdown()
                webWallpaperHost = nil
            } catch {
                AppLog.error("Quit cancelled because wallpaper restoration failed: \(error.localizedDescription)")
                lastError = error
                shutdownInProgress = false
                // Native restoration may already have released the desktop even
                // though poster restoration failed. Resume without waiting for
                // another bridge snapshot, but never overwrite an owned provider.
                if store?.lockScreenWallpaper?.ownsDesktopProvider != true {
                    do { try startDesktopWallpaperSync() } catch {
                        AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
                    }
                }
                presentationPolicy?.evaluate()
                rebuildMenu()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            await libraryImports.shutdown()
            automaticUpdates?.cancel()
            appUpdater.cancel()
            await workshopStore.steamCMDSetup.shutdown()
            await workshopStore.downloader.shutdown()
            await pixivStore.downloads.shutdown()
            do {
                try await store?.shutdownAsync()
                lastError = nil
            } catch {
                lastError = error
            }

            shutdownInProgress = false
            shutdownComplete = true
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    private func syncPlaybackMonitors() {
        let preferences = PlaybackPreferences.shared
        if preferences.appRules.isEmpty {
            appRuleMonitor?.stop()
        } else {
            appRuleMonitor?.start()
        }
        if preferences.otherAudioAction == .keepRunning {
            otherAudioMonitor?.stop()
        } else {
            otherAudioMonitor?.start()
        }
    }

    private func stopPlaybackMonitoring() {
        if let playbackPreferencesObserver {
            NotificationCenter.default.removeObserver(playbackPreferencesObserver)
            self.playbackPreferencesObserver = nil
        }
        appRuleMonitor?.stop()
        otherAudioMonitor?.stop()
        systemConditionMonitor?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Dock click returns to the last native section, even after releasing the page.
        showControlPanel(selection: controlPanelNavigation.selection ?? .wallpaper)
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStoreSnapshot()
        rebuildMenu(menu)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === controlPanelWindow else { return frameSize }
        return ControlPanelWindow.clampedFrameSize(frameSize, for: sender)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controlPanelWindow else { return }
        ControlPanelWindow.setFullScreenLayout(true, for: window)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controlPanelWindow else { return }
        ControlPanelWindow.setFullScreenLayout(false, for: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === whatsNewWindow {
            whatsNewWindow = nil
            window.contentViewController = nil
            if controlPanelWindow?.isVisible != true, previewWindow == nil { NSApp.setActivationPolicy(.accessory) }
            return
        }
        guard window === controlPanelWindow else { return }

        controlPanelWindow = nil
        // Closing releases the page and its WebKit processes; reopening builds a
        // fresh view around the existing stores and navigation.
        window.contentViewController = nil
        if whatsNewWindow == nil, previewWindow == nil { NSApp.setActivationPolicy(.accessory) }
        rebuildMenu()
    }

    private func startDesktopWallpaperSync() throws {
        guard !shutdownInProgress else { return }
        if let sync = desktopWallpaperSync, !sync.isSuspended {
            sync.refresh()
            return
        }
        let sync = try DesktopWallpaperSync(folder: ClientPaths.supportURL.appendingPathComponent("DesktopPosters"),
            scope: { [weak self] display in self?.desktopPosterScope(display) ?? .all },
            retainedDisplays: { [weak self] in self?.retainedSpacePosterDisplays() ?? [] },
            beforeDesktopChange: { [weak self] in self?.desktopSpaces?.refresh() })
        desktopWallpaperSync = sync
        sync.canCapture = { [weak self] surface in
            guard let policy = self?.presentationPolicy else { return true }
            return !policy.isSuspended
                && !(UInt32(surface.display).map(policy.suspendedDisplayIDs.contains) ?? false)
        }
        sync.refreshesPeriodically = PlaybackPreferences.shared.refreshesDesktopPicturePeriodically
        sync.start()
        sync.refresh()
    }

    private func desktopPosterScope(_ physicalDisplay: String) -> DesktopPosterScope {
        guard let store else { return .hold }
        guard let row = store.settingsSnapshot.displays.first(where: {
            ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title).map(String.init) == physicalDisplay
        }) else { return WallpaperAutomationStore.shared.configurations.values.contains { $0.mode == .spaces } ? .hold : .all }
        guard row.enabled, row.mode == .standalone,
              WallpaperAutomationStore.shared.configuration(for: row.displayId).mode == .spaces else { return .all }
        guard store.lockScreenWallpaper?.isRequested != true, store.lockScreenWallpaper?.ownsDesktopProvider != true,
              store.activatingWallpaperID == nil, store.applyingWallpaperID == nil,
              automaticWallpapers?.scheduler.selectionIsSettled(on: row.displayId) == true,
              let visit = desktopSpaces?.visit(for: physicalDisplay) else { return .hold }
        let wallpaper = store.monitorInformationSnapshot.rows.first(where: { $0.displayId == row.displayId })?.wallpaperId ?? ""
        return .desktop(id: visit.spaceID, context: "\(visit.token):\(wallpaper):\(store.wallpaperContentRevision)")
    }

    private func retainedSpacePosterDisplays() -> Set<String> {
        guard let store else { return [] }
        return Set(store.settingsSnapshot.displays.compactMap { row in
            guard row.enabled, row.mode == .standalone,
                  WallpaperAutomationStore.shared.configuration(for: row.displayId).mode == .spaces,
                  let physical = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title),
                  automaticWallpapers?.scheduler.inFlight.contains(row.displayId) == true
                    || store.monitorInformationSnapshot.rows.contains(where: { $0.displayId == row.displayId && !$0.wallpaperId.isEmpty }) else { return nil }
            return String(physical)
        })
    }

    /// Apply callbacks run before BridgeStore releases its activation flag. Request scoped
    /// pixels on the next actor turn, after that flag and manual-choice bookkeeping settle.
    private func schedulePosterRefresh() {
        guard posterRefreshTask == nil, !shutdownInProgress, !shutdownComplete else { return }
        posterRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { posterRefreshTask = nil }
            guard !Task.isCancelled, !shutdownInProgress, !shutdownComplete else { return }
            desktopWallpaperSync?.refresh()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        let button = item.button
        let trayIcon = NSImage(named: "TrayIcon")
        if let button {
            button.image = trayIcon
                ?? NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "WallpaperMachine")
            button.image?.isTemplate = true
        }

        AppLog.info("startup: statusItem installed: button=\(button != nil) trayIconAssetResolved=\(trayIcon != nil)")

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuildMenu(menu)
    }

    /// Work around an AppKit/SwiftUI timing issue: when launched via
    /// LaunchServices (Finder double-click) in `.accessory` activation
    /// policy, a status item created in `applicationDidFinishLaunching`
    /// may be created correctly but never rendered because the SwiftUI
    /// Scene phase hasn't stabilized yet. Deferring by one runloop turn
    /// gives the Scene phase time to settle. Re-asserting the activation
    /// policy afterwards forces AppKit to re-register accessory-mode
    /// status items with the Window Server; rebuilding the menu alone
    /// only mutates `NSMenu` items and does not touch the status item's
    /// backing window, so it is insufficient by itself.
    private func synchronizeStatusItem() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.statusItem != nil else { return }
            // Re-assert the activation policy to force AppKit to
            // re-register the accessory-mode status item with the
            // Window Server after the SwiftUI Scene phase has settled.
            if self.controlPanelWindow == nil, self.whatsNewWindow == nil, self.previewWindow == nil { NSApp.setActivationPolicy(.accessory) }
            self.rebuildMenu()
        }
    }

    private func installDisplayChangeObserver() {
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.displayRefresh.request()
            }
        }
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "WallpaperMachine")
        let settings = menuItem("Settings…", action: #selector(openSettings))
        settings.keyEquivalent = ","
        applicationMenu.addItem(settings)
        applicationMenu.addItem(menuItem("Check for Updates…", action: #selector(checkForUpdates)))
        applicationMenu.addItem(.separator())
        let quit = menuItem("Quit WallpaperMachine", action: #selector(exitApplication))
        quit.keyEquivalent = "q"
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)

        // Command-W reaches the key window, so the panel hides exactly as its close button does.
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File"))
        fileMenu.addItem(
            withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        // Keep standard text editing shortcuts in search and setup fields.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        let editCommands: [(String.LocalizationValue, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ]
        for (title, action, key) in editCommands {
            editMenu.addItem(withTitle: String(localized: title), action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func rebuildMenu(_ menu: NSMenu? = nil) {
        guard let menu = menu ?? statusItem?.menu else {
            return
        }

        menu.removeAllItems()
        menu.addItem(menuItem("Control Panel", action: #selector(openControlPanel)))

        var actions: [NSMenuItem] = []
        if let store,
           playbackSnapshotCurrent,
           !store.appSnapshot.activeWallpaperIds.isEmpty
        {
            let playbackTitle: String.LocalizationValue = store.appSnapshot.playbackState == .paused ? "Play" : "Pause"
            actions.append(menuItem(playbackTitle, action: #selector(togglePlayback)))
        }
        if let store, !shutdownInProgress, !shutdownComplete,
           store.previousWallpaperID(displayId: controlPanelNavigation.targetDisplayID) != nil {
            actions.append(menuItem("Previous Wallpaper", action: #selector(activatePreviousWallpaper)))
        }
        if let store, !shutdownInProgress, !shutdownComplete,
           canActivateNextWallpaper(store: store, displayId: controlPanelNavigation.targetDisplayID)
        {
            actions.append(menuItem("Next Wallpaper", action: #selector(activateNextWallpaper)))
        }
        if let store, !shutdownInProgress, !shutdownComplete {
            let display = controlPanelNavigation.targetDisplayID
            let available = Dictionary(store.librarySnapshot.wallpapers.filter(\.supported).map { ($0.id, $0.title) },
                                       uniquingKeysWith: { first, _ in first })
            let recent = store.history.recent(on: display, available: Set(available.keys))
            if !recent.isEmpty {
                let parent = NSMenuItem(title: String(localized: "Recently used"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for id in recent.prefix(10) {
                    let item = NSMenuItem(title: available[id] ?? id, action: #selector(activateRecentWallpaper(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ["id": id, "display": display]
                    item.state = store.isWallpaperActive(id: id, displayId: display) ? .on : .off
                    submenu.addItem(item)
                }
                parent.submenu = submenu
                actions.append(parent)
            }
        }
        if ScreenLock.isAvailable {
            actions.append(menuItem("Lock Screen", action: #selector(lockScreen)))
        }
        if !actions.isEmpty {
            menu.addItem(.separator())
            actions.forEach(menu.addItem)
        }

        if let item = updateMenuItem() {
            menu.addItem(.separator())
            menu.addItem(item)
        }

        if let error = startupError ?? lastError {
            menu.addItem(.separator())
            menu.addItem(disabledMenuItem(error.localizedDescription))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Exit", action: #selector(exitApplication)))
    }

    private func menuItem(_ title: String.LocalizationValue, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: title),
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openControlPanel() {
        showControlPanel(selection: .wallpaper)
    }

    @objc func openSettings() {
        showControlPanel(selection: .settings)
    }

    @objc func checkForUpdates() {
        controlPanelNavigation.revealSettingsSection(.about)
        showControlPanel(selection: .settings)
        Task { _ = await appUpdater.checkForUpdates() }
    }

    /// Checks at launch and every six hours after, because a menu-bar app can run for weeks
    /// without relaunching. `Task.sleep` follows the continuous clock, so a Mac that slept
    /// through the interval checks as soon as it wakes.
    private func startAutomaticUpdates() {
        guard automaticUpdates == nil else { return }
        automaticUpdates = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runAutomaticUpdate()
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    /// Asks the Workshop about installed items at most once a day, unless turned off; the
    /// automatic update loop calls this too, since the app can run for weeks.
    private func checkWorkshopUpdatesIfDue() {
        guard let store, !shutdownInProgress, !shutdownComplete, playbackSnapshotCurrent else { return }
        workshopStore.updates.checkIfDue(
            installed: store.librarySnapshot.wallpapers.map(\.id), library: ClientPaths.libraryURL)
    }

    private func runAutomaticUpdate() async {
        checkWorkshopUpdatesIfDue()
        let state = await appUpdater.checkInBackground()
        rebuildMenu()
        guard !shutdownInProgress, !shutdownComplete, whatsNewWindow == nil,
              let version = state.availableVersion, version != promptedUpdateVersion else { return }
        switch state {
        case .ready:
            promptedUpdateVersion = version
            promptUpdate(
                title: String(localized: "WallpaperMachine \(version) is ready to install"),
                detail: String(localized: "It has been downloaded. WallpaperMachine quits and reopens to finish installing it."),
                confirm: String(localized: "Restart to Update"),
                confirmed: installDownloadedUpdate)
        case .available, .manual:
            promptedUpdateVersion = version
            promptUpdate(
                title: String(localized: "WallpaperMachine \(version) is available"),
                detail: String(localized: "See what's new and download it in Settings."),
                confirm: String(localized: "View Update"),
                confirmed: showUpdate)
        default:
            break
        }
    }

    /// Shown from the main run loop, not this task: a modal run inside a main-actor task would
    /// stall every other main-actor task until the alert closes.
    private func promptUpdate(title: String, detail: String, confirm: String, confirmed: @escaping () -> Void) {
        AppUpdateStore.performOnMainRunLoop { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shutdownInProgress, !self.shutdownComplete else { return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = detail
                alert.addButton(withTitle: confirm)
                alert.addButton(withTitle: String(localized: "Later"))
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn, !self.shutdownInProgress else { return }
                confirmed()
            }
        }
    }

    /// An error alert, shown from the main run loop for the reason `promptUpdate` gives; the
    /// callers run inside main-actor tasks and main-queue jobs.
    private func presentErrorAlert(_ error: Error) {
        AppUpdateStore.performOnMainRunLoop { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shutdownInProgress, !self.shutdownComplete else { return }
                NSAlert(error: error).runModal()
            }
        }
    }

    /// "Later" leaves the update one click away in the status menu.
    private func updateMenuItem() -> NSMenuItem? {
        switch appUpdater.state {
        case .ready(_, let version):
            return menuItem("Restart to Update to \(version)", action: #selector(installDownloadedUpdate))
        case .available(_, let version), .manual(_, let version):
            return menuItem("WallpaperMachine \(version) Available…", action: #selector(showUpdate))
        default:
            return nil
        }
    }

    @objc private func installDownloadedUpdate() {
        Task {
            await appUpdater.installUpdate()
            // A failed install explains itself, and offers GitHub Releases, in About.
            if case .error = appUpdater.state { showUpdate() }
        }
    }

    @objc private func showUpdate() {
        controlPanelNavigation.revealSettingsSection(.about)
        showControlPanel(selection: .settings)
    }

    private func showWhatsNewAfterUpdate() {
        guard !shutdownInProgress, whatsNewWindow == nil else { return }
        do {
            let history = try AppReleaseHistory()
            guard let announcement = whatsNewStore.announcement(
                history: history, existingUser: ClientPreferences.defaults.bool(forKey: WebPanelController.welcomeSeenKey)
            ) else { return }
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: WhatsNewViewController.defaultContentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = String(localized: "What’s New")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = WhatsNewViewController(
                announcement: announcement, preferences: whatsNewStore,
                initialLanguage: AppLanguageStore.shared.effective,
                close: { [weak window] in window?.performClose(nil) })
            window.contentMinSize = NSSize(width: 600, height: 480)
            // Installing a controller can resize the window to its content view's fitting size.
            window.setContentSize(WhatsNewViewController.defaultContentSize)
            window.center()
            whatsNewWindow = window
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            whatsNewStore.didPresent(announcement)
        } catch {
            AppLog.error("Bundled release history could not load: \(error.localizedDescription)")
        }
    }

    private func showControlPanel(selection: SidebarSelection) {
        controlPanelNavigation.selection = selection
        NSApp.setActivationPolicy(.regular)

        if let controlPanelWindow {
            ControlPanelWindow.constrainToScreen(controlPanelWindow)
            controlPanelWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller: NSHostingController<AnyView>
        if let store {
            controller = NSHostingController(
                rootView: AnyView(
                    ControlPanelView(
                        store: store,
                        navigation: controlPanelNavigation,
                        workshop: workshopStore,
                        pixiv: pixivStore,
                        updater: appUpdater,
                        imports: libraryImports
                    )
                )
            )
        } else {
            controller = NSHostingController(
                rootView: AnyView(BridgeUnavailableView(error: startupError ?? lastError))
            )
        }

        // AppKit owns this resizable window's bounds; content must accept its proposal
        // instead of promoting a long label or a split pane's ideal width to a window minimum.
        controller.sizingOptions = []
        let window = ControlPanelWindow.make(contentViewController: controller, delegate: self)
        let frameName = ControlPanelWindow.frameAutosaveName
        if !window.setFrameUsingName(frameName) { window.center() }
        ControlPanelWindow.constrainToScreen(window)
        window.setFrameAutosaveName(frameName)

        controlPanelWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePlayback() {
        guard let store,
              !shutdownInProgress,
              !shutdownComplete,
              playbackSnapshotCurrent,
              !store.appSnapshot.activeWallpaperIds.isEmpty
        else {
            return
        }

        Task {
            do {
                if store.appSnapshot.playbackState == .paused {
                    try await store.playAllAsync()
                } else {
                    try await store.pauseAllAsync()
                }
                lastError = nil
                playbackSnapshotCurrent = true
                rebuildMenu()
            } catch {
                lastError = error
                playbackSnapshotCurrent = false
                rebuildMenu()
                presentErrorAlert(error)
            }
        }
    }

    /// A display whose playlist rotates moves along the playlist; any other display takes the
    /// next wallpaper in library order.
    private func showWallpaperPreview(_ selection: WallpaperPreviewSession.Selection) {
        guard let store, !shutdownInProgress, !shutdownComplete else { return }
        wallpaperEnergy?.invalidate()
        if previewWindow == nil {
            let loader = WallpaperPreviewLoader()
            let session = WallpaperPreviewSession(load: { [weak store] selection in
                guard let store else { throw CancellationError() }
                var request = try await store.wallpaperPreviewRequestAsync(id: selection.wallpaperID,
                    displayID: selection.displayID, textOverrides: selection.textOverrides)
                let placement = StillImagePlacementStore.shared
                if request.kind == .web, placement.generatedImage(wallpaperID: request.wallpaperID) != nil {
                    request.propertiesJSON = try placement.effectivePropertiesJSON(request.propertiesJSON,
                        wallpaperID: request.wallpaperID, displayID: selection.displayID)
                }
                return try await loader.validate(request)
            }, makeSurface: { request, generation in
                if request.kind == .web { return WebWallpaperPreviewSurface(request: request, generation: generation) }
                return SceneWallpaperPreviewSurface(request: request)
            })
            let controller = WallpaperPreviewWindowController(session: session)
            controller.onClosed = { [weak self, weak controller] in
                guard let self, self.previewWindow === controller else { return }
                self.previewWindow = nil
                self.wallpaperEnergy?.invalidate()
                if self.controlPanelWindow?.isVisible != true, self.whatsNewWindow == nil {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            previewWindow = controller
        }
        NSApp.setActivationPolicy(.regular)
        previewWindow?.present(selection)
    }

    private func canActivateNextWallpaper(store: BridgeStore, displayId: String) -> Bool {
        if PlaylistStore.shared.playlist(for: displayId).mode == .rotate {
            return playlistScheduler?.canSkip(displayId) ?? false
        }
        return store.nextWallpaperID(displayId: displayId) != nil
    }

    @objc private func activateNextWallpaper() {
        let displayId = controlPanelNavigation.targetDisplayID
        guard let store, !shutdownInProgress, !shutdownComplete,
              canActivateNextWallpaper(store: store, displayId: displayId)
        else {
            return
        }
        runAutomation(.next(display: displayId))
    }

    @objc private func activatePreviousWallpaper() {
        runAutomation(.previous(display: controlPanelNavigation.targetDisplayID))
    }

    @objc private func activateRecentWallpaper(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String],
              let id = value["id"], let display = value["display"] else { return }
        runAutomation(.apply(wallpaperID: id, display: display))
    }

    /// Runs a command from a link, a keyboard shortcut or the menu bar. A failure shows in the
    /// menu bar menu, as one from the menu itself does.
    private func runAutomation(_ command: AutomationCommand) {
        Task {
            do {
                try await AppAutomation.shared.perform(command)
                lastError = nil
            } catch {
                lastError = error
                AppLog.warn("\(String(describing: command)) failed: \(error.localizedDescription)")
            }
            rebuildMenu()
        }
    }

    /// Carries out a command from outside the window: the Shortcuts app, a link, a keyboard
    /// shortcut or the menu bar. Switches share the panel's per-display slot, so the latest
    /// request for a display wins.
    private func performAutomation(_ command: AutomationCommand) async throws {
        guard let store, !shutdownInProgress, !shutdownComplete else { throw AutomationError.notReady }
        switch command {
        case .play, .pause, .togglePlayback:
            try await store.commands.run {
                let paused = store.appSnapshot.playbackState == .paused
                let play = command == .play || (command == .togglePlayback && paused)
                if play, paused {
                    try await store.playAllAsync()
                } else if !play, !paused {
                    try await store.pauseAllAsync()
                }
            }
            playbackSnapshotCurrent = true
        case .previous(let display):
            let displayId = try automationDisplay(display, store: store)
            try await store.commands.run(slot: BridgeStore.activationSlot(displayId: displayId)) {
                _ = try self.automationDisplay(displayId, store: store)
                try await store.activatePreviousWallpaperAsync(displayId: displayId)
            }
        case .next(let display):
            let displayId = try automationDisplay(display, store: store)
            // The playlist's own next, with a fresh interval after it; a switch it is already
            // making counts as the answer rather than falling back to the library order.
            if PlaylistStore.shared.playlist(for: displayId).mode == .rotate {
                guard PlaylistStore.shared.skipHandler?(displayId) == true else {
                    throw AutomationError(
                        message: String(localized: "This display’s playlist has no other wallpaper to change to."))
                }
                return
            }
            // "Next" is measured from whatever the display shows when this one gets its turn.
            try await store.commands.run(slot: BridgeStore.activationSlot(displayId: displayId)) {
                _ = try self.automationDisplay(displayId, store: store)
                guard let id = store.nextWallpaperID(displayId: displayId) else { return }
                try await store.activateWallpaperAsync(id: id, displayId: displayId, userInitiated: true)
            }
        case .apply(let id, let display):
            let displayId = try automationDisplay(display, store: store)
            guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
                throw AutomationError(message: String(localized: "No installed wallpaper has the id “\(id)”."))
            }
            try await store.commands.run(slot: BridgeStore.activationSlot(displayId: displayId), subject: id) {
                _ = try self.automationDisplay(displayId, store: store)
                try await store.activateWallpaperAsync(id: id, displayId: displayId, userInitiated: true)
            }
        case .applyPlaylist(let id, let display):
            let displayID = try automationDisplay(display, store: store)
            try await store.commands.run(slot: BridgeStore.activationSlot(displayId: displayID)) {
                _ = try self.automationDisplay(displayID, store: store)
                try WallpaperAutomationController.applyPlaylist(id, to: displayID, playlists: .shared, collections: .shared)
                WallpaperAutomationStore.shared.manualChoice?(displayID)
            }
        case .applyPreset(let id):
            let presets = WallpaperPresetStore.shared
            let preset = try presets.preset(id: id)
            guard store.librarySnapshot.wallpapers.contains(where: { $0.id == preset.wallpaperID && $0.supported }) else {
                throw AutomationError(message: String(localized: "This preset’s wallpaper is no longer installed."))
            }
            try await store.commands.run(slot: "preset:\(preset.wallpaperID)", subject: preset.wallpaperID) {
                let current = try presets.preset(id: id)
                let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: current.wallpaperID)
                try await presets.apply(current, options: options, bridge: store, userInitiated: true)
            }
        case .applyDisplayLayout(let id):
            let layout = try WallpaperDisplayLayoutStore.shared.layout(id)
            try await store.applyDisplayTransferAsync(.layout(layout.assignments))
        case .open(let page):
            switch page {
            case .discover?:
                if !workshopStore.hasLoaded && !workshopStore.isLoading { workshopStore.search() }
                showControlPanel(selection: .workshop)
            case .pixiv?:
                if !pixivStore.hasLoaded && !pixivStore.isLoading { pixivStore.apply(pixivStore.query) }
                showControlPanel(selection: .pixiv)
            case .settings?:
                showControlPanel(selection: .settings)
            case .installed?:
                showControlPanel(selection: .wallpaper)
            case nil:
                showControlPanel(selection: controlPanelNavigation.selection ?? .wallpaper)
            }
        }
    }

    private static func availableAutomationDisplays(store: BridgeStore) -> [BridgeDisplaySettingsRow] {
        let connected = Set(WebWallpaperHost.systemScreens().map(\.id))
        return store.settingsSnapshot.displays.filter { display in
            guard display.enabled, display.mode == .standalone,
                let physicalID = ResolvedDisplayTitles.liveDisplayID(display.displayId, title: display.title)
            else { return false }
            return connected.contains(physicalID)
        }
    }

    /// The display a command names, or the panel's target display; only an enabled display
    /// that shows its own wallpaper can be switched.
    private func automationDisplay(_ requested: String?, store: BridgeStore) throws -> String {
        let id = requested ?? controlPanelNavigation.targetDisplayID
        guard Self.availableAutomationDisplays(store: store).contains(where: { $0.displayId == id }) else {
            throw AutomationError(message: String(localized: "No enabled display showing its own wallpaper has the id “\(id)”."))
        }
        return id
    }

    @objc private func lockScreen() {
        ScreenLock.lock()
    }

    @objc private func exitApplication() {
        NSApp.terminate(nil)
    }

    private func bootstrapStore() {
        AppLog.info("startup: bootstrapAsync start")
        guard let store else {
            AppLog.info("startup: bootstrapAsync skipped: store is nil")
            return
        }

        Task {
            do {
                try await store.bootstrapAsync()
                startupError = nil
                lastError = nil
                playbackSnapshotCurrent = true
                AppLog.info("startup: bootstrapAsync completed successfully")
                checkWorkshopUpdatesIfDue()
                // Links, keyboard shortcuts and the Shortcuts app act from here on.
                AppAutomation.shared.handler = { [weak self] command in
                    guard let self else { throw AutomationError.notReady }
                    try await self.performAutomation(command)
                }
            } catch {
                AppLog.error("startup: bootstrapAsync FAILED: \(error.localizedDescription)")
                lastError = error
                playbackSnapshotCurrent = false
                // The panel opens without a started library, and Settings is where a failed start
                // is put right; every other command answers at once instead of waiting it out.
                AppAutomation.shared.handler = { [weak self] command in
                    guard let self, case .open = command else { throw AutomationError.notReady }
                    try await self.performAutomation(command)
                }
            }
            rebuildMenu()
            // Also after a failed start: the update may be the fix.
            startAutomaticUpdates()
        }
    }

    private func refreshStoreSnapshot() {
        guard let store,
              !shutdownInProgress,
              !shutdownComplete
        else {
            return
        }

        Task {
            do {
                try await store.refreshAllAsync()
                lastError = nil
                playbackSnapshotCurrent = true
            } catch {
                lastError = error
                playbackSnapshotCurrent = false
            }
            rebuildMenu()
        }
    }

    /// Whether the bridge took the refresh.
    private func refreshDisplaysFromSystemEvent() async -> Bool {
        guard let store,
              !shutdownInProgress,
              !shutdownComplete
        else {
            return false
        }

        let refreshed: Bool
        do {
            try await store.refreshDisplaysAsync()
            lastError = nil
            playbackSnapshotCurrent = true
            refreshed = true
        } catch {
            lastError = error
            playbackSnapshotCurrent = false
            refreshed = false
        }
        rebuildMenu()
        return refreshed
    }

    /// The applied desktop Scenes that have consented to now-playing.
    ///
    /// The bridge answers, not the library snapshot: consent is per wallpaper
    /// and the snapshot does not carry it. Nothing reads the system player
    /// while this is empty, so a user who left the setting off is never asked
    /// for Automation permission, and a handle that was not there before is a
    /// scene that still has to be told what is playing.
    private static func sceneMediaHandles(store: BridgeStore) async -> Set<UInt64> {
        do {
            return Set(try await store.bridge.systemMediaSceneHandles())
        } catch {
            AppLog.warn("Scene media consumers could not be read: \(error.localizedDescription)")
            return []
        }
    }

}

private struct BridgeUnavailableView: View {
    let error: Error?

    var body: some View {
        ContentUnavailableView(
            "Bridge Unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(error?.localizedDescription ?? String(localized: "The rendering bridge could not be started."))
        )
        .frame(minWidth: 640, minHeight: 420)
    }
}
