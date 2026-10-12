import AppKit
import CryptoKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// Encodes final renderer pixels, not a screen capture or a Workshop cover.
///
/// JPEG rather than PNG: a full-size Retina frame encodes several times faster
/// and is about a third of the size, and the system wallpaper is mostly seen
/// scaled down in Mission Control or for a moment beneath a loading renderer.
enum DesktopPosterEncoder {
    static let fileExtension = "jpg"
    static let quality = 0.9

    static func jpeg(pixels: Data, width: Int, height: Int, bgra: Bool) throws -> Data {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32 * 1024 * 1024,
              pixels.count == width * height * 4,
              let provider = CGDataProvider(data: pixels as CFData) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let info = bgra
            ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}

struct DesktopPosterFrame: Sendable {
    var pixels: Data
    var width: Int
    var height: Int
    var bgra: Bool

    /// Identifies the pixels, so a frame identical to the current poster is
    /// neither encoded nor written again.
    var digest: Data {
        var hash = SHA256()
        withUnsafeBytes(of: (width, height, bgra)) { hash.update(bufferPointer: $0) }
        hash.update(data: pixels)
        return Data(hash.finalize())
    }

    static func rgba(_ image: CGImage) -> DesktopPosterFrame? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32 * 1024 * 1024,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? DesktopPosterFrame(pixels: pixels, width: width, height: height, bgra: false) : nil
    }

    @MainActor
    func publish(for layer: CALayer, to center: NotificationCenter, context: String? = nil) {
        center.post(name: DesktopPosterNotification.ready, object: layer,
                    userInfo: ["pixels": pixels, "width": width, "height": height, "bgra": bgra, "context": context ?? ""])
    }
}

enum DesktopPosterNotification {
    static let request = Notification.Name("WallpaperMachine.requestDesktopPoster")
    static let ready = Notification.Name("WallpaperMachine.desktopPosterReady")
}

/// `layer` identifies the surface: the renderer's `CAMetalLayer`, or a web
/// wallpaper view's backing layer. Its owner answers the poster request.
struct DesktopPosterSurface {
    var layer: CALayer
    var display: String
}

enum DesktopPosterScope: Equatable {
    case all
    case desktop(id: String, context: String)
    case hold

    var context: String? { if case .desktop(_, let context) = self { return context }; return nil }
}

/// The first ready frame is submitted to all native desktop Spaces immediately.
/// Window enumeration and frame encoding are injected for headless regression
/// tests, including layer replacement and out-of-order completion.
///
/// Mission Control shows this system wallpaper, not the live window, so the
/// poster is taken again shortly after a wallpaper starts, changes or resumes
/// (intros, fades and settings that take a moment to show), on a Space change
/// or wake, and optionally every few minutes. A frame identical to the current
/// poster costs a readback and a hash; nothing is encoded or written.
@MainActor
final class DesktopWallpaperSync {
    /// Delays after a start, change or resume at which the poster is taken again.
    static let settleCaptureDelays: [Duration] = [.seconds(3), .seconds(15)]
    static let periodicRefreshInterval: Duration = .seconds(300)

    private let ledger: DesktopWallpaperLedger
    private var frameObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var posters: [ObjectIdentifier: Data] = [:]
    private var posterScopes: [ObjectIdentifier: DesktopPosterScope] = [:]
    /// The pixels each layer's poster was encoded from.
    private var frameDigests: [ObjectIdentifier: Data] = [:]
    private var revisions: [ObjectIdentifier: UInt64] = [:]
    /// When each layer's poster frame was received, so a display that briefly has two wallpaper
    /// windows (one replacing the other) shows the newer poster, never neither. Counted on
    /// receipt, not when encoding ends, so a slow encode cannot reverse the order.
    private var arrivals: [ObjectIdentifier: UInt64] = [:]
    private var arrivalCount: UInt64 = 0
    private let surfaces: @MainActor () -> [DesktopPosterSurface]
    private let frameCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter?
    private let encode: @Sendable (DesktopPosterFrame) async throws -> Data
    private let scope: @MainActor (String) -> DesktopPosterScope
    private let beforeDesktopChange: @MainActor () -> Void
    private let retainedDisplays: @MainActor () -> Set<String>
    private var knownDisplays = Set<String>()
    private var retry: Task<Void, Never>?
    /// Synchronizes again once unconfirmed poster writes should read back.
    private var confirming: Task<Void, Never>?
    private let confirmationDelay: Duration
    private var lastRefresh: ContinuousClock.Instant?
    private var coalesced: Task<Void, Never>?
    private static let refreshInterval: Duration = .milliseconds(500)
    private let settleDelays: [Duration]
    private let periodicInterval: Duration
    private var settling: Task<Void, Never>?
    private var periodic: Task<Void, Never>?
    /// Whether a surface's wallpaper is presenting, so a later capture can show
    /// something new. Settling and periodic captures skip the others; a new
    /// wallpaper, a Space change and a wake still capture every surface.
    var canCapture: @MainActor (DesktopPosterSurface) -> Bool = { _ in true }
    /// Takes the poster again every `periodicRefreshInterval` while on.
    var refreshesPeriodically = false {
        didSet { if refreshesPeriodically != oldValue { schedulePeriodicCaptures() } }
    }
    private var stopped = false
    /// Whether the refresh that fires next reads fresh frames; coalesced calls
    /// capture when any of them asked to.
    private var pendingCapture = false
    var isSuspended: Bool { stopped }

    convenience init(folder: URL, scope: @escaping @MainActor (String) -> DesktopPosterScope = { _ in .all },
                     retainedDisplays: @escaping @MainActor () -> Set<String> = { [] },
                     beforeDesktopChange: @escaping @MainActor () -> Void = {}) throws {
        try self.init(folder: folder, workspace: SystemDesktopPictureWorkspace(), surfaces: {
            WallpaperPresentationPolicy.wallpaperWindows().compactMap { window in
                guard let layer = window.contentView?.layer,
                      let screen = window.screen, let id = SystemDesktopPictureWorkspace.id(screen) else { return nil }
                return DesktopPosterSurface(layer: layer, display: id)
            }
        }, frameCenter: .default, workspaceCenter: NSWorkspace.shared.notificationCenter,
                      scope: scope, retainedDisplays: retainedDisplays, beforeDesktopChange: beforeDesktopChange)
    }

    init(folder: URL, workspace: any DesktopPictureWorkspace,
         surfaces: @escaping @MainActor () -> [DesktopPosterSurface],
         frameCenter: NotificationCenter, workspaceCenter: NotificationCenter? = nil,
         scope: @escaping @MainActor (String) -> DesktopPosterScope = { _ in .all },
         retainedDisplays: @escaping @MainActor () -> Set<String> = { [] },
         beforeDesktopChange: @escaping @MainActor () -> Void = {},
         encode: @escaping @Sendable (DesktopPosterFrame) async throws -> Data = { frame in
             try await Task.detached(priority: .userInitiated) {
                 try DesktopPosterEncoder.jpeg(pixels: frame.pixels, width: frame.width, height: frame.height, bgra: frame.bgra)
             }.value
         },
         settleDelays: [Duration] = DesktopWallpaperSync.settleCaptureDelays,
         periodicInterval: Duration = DesktopWallpaperSync.periodicRefreshInterval,
         confirmationDelay: Duration = DesktopWallpaperLedger.confirmationWindow) throws {
        ledger = try DesktopWallpaperLedger(folder: folder, workspace: workspace,
                                            confirmationWindow: confirmationDelay)
        self.confirmationDelay = confirmationDelay
        self.surfaces = surfaces
        self.frameCenter = frameCenter
        self.workspaceCenter = workspaceCenter
        self.scope = scope; self.beforeDesktopChange = beforeDesktopChange
        self.retainedDisplays = retainedDisplays
        self.encode = encode
        self.settleDelays = settleDelays.sorted()
        self.periodicInterval = periodicInterval
    }

    func start() {
        guard frameObserver == nil, !stopped else { return }
        frameObserver = frameCenter.addObserver(
            forName: DesktopPosterNotification.ready, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.receive(notification) }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            guard let workspaceCenter else { break }
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAfterDesktopChange() }
            })
        }
        schedulePeriodicCaptures()
    }

    /// Brings every desktop up to date with the current poster. `capture` also
    /// asks each surface for a fresh frame first, which is what a new or
    /// changed wallpaper needs, and takes it again as the wallpaper settles.
    func refresh(capture: Bool = true) {
        refresh(capture: capture, settle: capture)
    }

    /// A display's wallpaper plays again after a pause, a cover or display
    /// sleep: an intro may only now be running, so the poster is taken again
    /// as it settles.
    func presentationResumed() {
        scheduleSettleCaptures()
    }

    private func refresh(capture: Bool, settle: Bool) {
        guard !stopped else { return }
        if settle { scheduleSettleCaptures() }
        pendingCapture = pendingCapture || capture
        let now = ContinuousClock.now
        if let last = lastRefresh, now - last < Self.refreshInterval {
            guard coalesced == nil else { return }
            let wait = Self.refreshInterval - (now - last)
            coalesced = Task { [weak self] in
                do { try await Task.sleep(for: wait) } catch { return }
                guard let self, !self.stopped else { return }
                self.coalesced = nil
                self.lastRefresh = ContinuousClock.now
                self.performRefresh()
            }
            return
        }
        lastRefresh = now
        performRefresh()
    }

    /// A Space change or wake shows a desktop the poster may not be on yet: the
    /// current poster is applied at once and a fresh frame is asked for, since
    /// an animated wallpaper has moved on since its poster was taken. Desktops
    /// that kept refusing posters are tried again.
    private func refreshAfterDesktopChange() {
        beforeDesktopChange()
        ledger.retryRefusedDesktops()
        refresh(capture: true, settle: false)
    }

    private func scheduleSettleCaptures() {
        settling?.cancel()
        settling = nil
        guard !stopped, frameObserver != nil, !settleDelays.isEmpty else { return }
        let delays = settleDelays
        settling = Task { [weak self] in
            var elapsed = Duration.zero
            for delay in delays {
                do { try await Task.sleep(for: delay - elapsed) } catch { return }
                elapsed = delay
                guard let self, !self.stopped else { return }
                self.requestPresentingFrames()
            }
        }
    }

    private func schedulePeriodicCaptures() {
        periodic?.cancel()
        periodic = nil
        guard refreshesPeriodically, !stopped, frameObserver != nil else { return }
        let interval = periodicInterval
        periodic = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !self.stopped else { return }
                self.requestPresentingFrames()
            }
        }
    }

    /// Asks only presenting surfaces: a suspended one would draw the frame its
    /// poster already shows.
    private func requestPresentingFrames() {
        for surface in surfaces() where canCapture(surface) {
            requestFrame(for: surface)
        }
    }

    private func requestFrame(for surface: DesktopPosterSurface) {
        let scope = scope(surface.display)
        guard scope != .hold else { return }
        frameCenter.post(name: DesktopPosterNotification.request, object: surface.layer,
                         userInfo: ["context": scope.context ?? ""])
    }

    private func performRefresh() {
        guard !stopped else { return }
        let capture = pendingCapture
        pendingCapture = false
        // Request GPU pixels before potentially slow native Space enumeration
        // and journal I/O, so readback can overlap synchronization.
        // No debounce: an Apply must not wait for a 400 ms timer, another
        // snapshot, or an activeSpaceDidChange notification to request pixels.
        if capture {
            for surface in surfaces() {
                requestFrame(for: surface)
            }
        }
        synchronizeAllSpaces()
    }

    func stop() {
        do { try stopAndRestore() } catch { report(error) }
    }

    /// Stop poster writes without restoring through the legacy image API. The
    /// native provider journals the current poster; keep its file and ledger
    /// alive until that provider releases ownership.
    func suspendForNativeProvider() {
        stopped = true
        retry?.cancel()
        confirming?.cancel()
        confirming = nil
        coalesced?.cancel()
        coalesced = nil
        settling?.cancel()
        settling = nil
        periodic?.cancel()
        periodic = nil
        lastRefresh = nil
        if let frameObserver { frameCenter.removeObserver(frameObserver) }
        frameObserver = nil
        for observer in workspaceObservers { workspaceCenter?.removeObserver(observer) }
        workspaceObservers.removeAll()
        posters.removeAll()
        posterScopes.removeAll()
        knownDisplays.removeAll()
        frameDigests.removeAll()
        revisions.removeAll()
        arrivals.removeAll()
    }

    func stopAndRestore() throws {
        suspendForNativeProvider()
        try ledger.restoreAll()
    }

    /// Native Desktop/Idle restoration signals WallpaperAgent to reload. Wait
    /// for its poster selection to become readable and for our restoration to
    /// persist before allowing the app to exit.
    ///
    /// A poster can stay named where no per-Space write reaches it: macOS 27 can
    /// copy a Space write into the display-wide and system-default
    /// selections. Once every desktop that can be written is restored and
    /// reads back, that leftover reference no longer blocks quitting, or the
    /// app could never quit. A restoration that never reads back still does.
    func restoreForTermination(
        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) }
    ) async throws {
        suspendForNativeProvider()
        for attempt in 0..<25 {
            try Task.checkCancellation()
            do {
                try ledger.restoreAll()
                return
            } catch {
                guard attempt < 24 else {
                    guard error as? DesktopWallpaperLedger.Failure == .restorationPending else { throw error }
                    AppLog.warn("Quitting while macOS still names a desktop poster in its wallpaper store; every writable desktop was restored")
                    return
                }
                try await wait()
            }
        }
    }

    private func receive(_ notification: Notification) {
        guard !stopped, let layer = notification.object as? CALayer,
              let surface = surfaces().first(where: { $0.layer === layer }),
              let values = notification.userInfo,
              let pixels = values["pixels"] as? Data,
              let width = values["width"] as? Int, let height = values["height"] as? Int,
              let bgra = values["bgra"] as? Bool else { return }
        let receivedScope = scope(surface.display)
        guard receivedScope != .hold,
              (values["context"] as? String ?? "") == (receivedScope.context ?? "") else { return }
        let key = ObjectIdentifier(layer)
        let revision = (revisions[key] ?? 0) &+ 1
        revisions[key] = revision
        arrivalCount &+= 1
        let arrival = arrivalCount
        let encode = self.encode
        let frame = DesktopPosterFrame(pixels: pixels, width: width, height: height, bgra: bgra)
        Task(priority: .userInitiated) { [weak self, weak layer] in
            let digest = await Task.detached(priority: .userInitiated) { frame.digest }.value
            guard let self, let layer, self.isNewest(revision, of: layer),
                  self.scope(surface.display) == receivedScope else { return }
            if self.posters[key] != nil, self.frameDigests[key] == digest {
                // The same pixels can belong to a new Space visit. Reuse their encoding
                // only after a fresh response validates the new context, then publish there.
                self.posterScopes[key] = receivedScope
                self.arrivals[key] = arrival
                self.synchronizeAllSpaces()
                return
            }
            do {
                let image = try await encode(frame)
                guard self.isNewest(revision, of: layer),
                      self.scope(surface.display) == receivedScope else { return }
                self.posters[key] = image
                self.posterScopes[key] = receivedScope
                self.frameDigests[key] = digest
                self.arrivals[key] = arrival
                self.synchronizeAllSpaces()
            } catch { self.report(error) }
        }
    }

    /// Only the newest frame of a surface still on screen may become its poster.
    private func isNewest(_ revision: UInt64, of layer: CALayer) -> Bool {
        !stopped && revisions[ObjectIdentifier(layer)] == revision
            && surfaces().contains(where: { $0.layer === layer })
    }

    private func synchronizeAllSpaces(attempt: Int = 0) {
        let surfaces = surfaces()
        let keys = Set(surfaces.map { ObjectIdentifier($0.layer) })
        posters = posters.filter { keys.contains($0.key) }
        posterScopes = posterScopes.filter { keys.contains($0.key) }
        frameDigests = frameDigests.filter { keys.contains($0.key) }
        revisions = revisions.filter { keys.contains($0.key) }
        arrivals = arrivals.filter { keys.contains($0.key) }
        var byDisplay: [String: Data] = [:]
        var newest: [String: UInt64] = [:]
        var targetSpaces: [String: Set<String>] = [:]
        let retained = retainedDisplays()
        knownDisplays.formUnion(surfaces.map(\.display))
        knownDisplays.formUnion(retained)
        for display in knownDisplays {
            switch scope(display) {
            case .all: break
            case .desktop(let id, _): targetSpaces[display] = [id]
            case .hold: targetSpaces[display] = []
            }
        }
        for surface in surfaces {
            let currentScope = scope(surface.display)
            // A window with no poster yet must not take away the one its sibling has.
            let key = ObjectIdentifier(surface.layer)
            guard currentScope != .hold, posterScopes[key] == currentScope,
                  let poster = posters[key], let arrival = arrivals[key],
                  arrival >= newest[surface.display] ?? 0 else { continue }
            byDisplay[surface.display] = poster
            newest[surface.display] = arrival
        }
        retry?.cancel()
        defer { scheduleConfirmation() }
        do {
            try ledger.synchronize(posters: byDisplay, liveDisplays: Set(surfaces.map(\.display)).union(retained), targetSpaces: targetSpaces)
        } catch {
            report(error)
            // Retry native asynchronous acknowledgement/Space creation races,
            // not the initial update. Never require the user to visit a Space.
            guard attempt < 3, !stopped else { return }
            retry = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100 * (attempt + 1))) } catch { return }
                guard let self, !self.stopped else { return }
                self.synchronizeAllSpaces(attempt: attempt + 1)
            }
        }
    }

    /// A poster write WallpaperAgent has not applied yet is checked again,
    /// rather than rewritten or counted as refused at once.
    private func scheduleConfirmation() {
        confirming?.cancel()
        confirming = nil
        guard ledger.awaitsConfirmation, !stopped else { return }
        let delay = confirmationDelay
        confirming = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !self.stopped else { return }
            self.confirming = nil
            self.synchronizeAllSpaces()
        }
    }

    private func report(_ error: Error) {
        // A native-poster failure must not stop live playback or show a modal.
        AppLog.error("Native desktop poster sync failed: \(error.localizedDescription)")
    }
}
