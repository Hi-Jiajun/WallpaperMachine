import AVFoundation
import AppKit
import VideoToolbox

/// Owns the `AVQueuePlayer` / `AVPlayerLooper` / `AVPlayerLayer` trio for one
/// display.
///
/// `AVPlayerLooper` is what makes gapless looping the system's problem rather
/// than ours; it keeps more than one copy of the item queued by design, which
/// is why the counters report queued items rather than claiming a single one.
@MainActor
final class NativeVideoPlayer {
    /// Ceiling on how long one poster request will wait for the playing item
    /// to hand over a frame before falling back. Bounded so a stalled item
    /// cannot hold a request open, and short enough that a poster request is
    /// never mistaken for a reason to keep the decoder awake.
    static let posterWaitStep = Duration.milliseconds(25)
    static let posterWaitSteps = 12

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let layer = AVPlayerLayer()
    private let surface: RuntimeSurfaceKey
    private let counters: RuntimeCounters
    /// The user's own Play/Pause choice, kept apart from presentation
    /// suspension so revealing a display never overrides it.
    private var userPaused: Bool
    private var presentationSuspended = false
    private var stopped = false

    /// Attached only while a poster request is in flight, and always to the
    /// item that is playing right now rather than to the looper's template.
    /// A permanently attached output would mean a second, continuous readback
    /// of every frame for a picture nobody asked for.
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var outputItem: AVPlayerItem?
    /// The single in-flight poster request. Concurrent callers await this one
    /// instead of each opening their own read path.
    private var posterRequest: Task<CGImage?, Never>?
    /// Last frame this player actually produced. A paused player answers from
    /// here rather than resuming to make a picture.
    private var lastPoster: CGImage?
    /// KVO on the item's and the looper's status. Held for the player's life
    /// so a failure that arrives late still reaches the host.
    private var statusObservations: [NSKeyValueObservation] = []
    /// Status observation for the item that is playing right now, re-pointed
    /// as the loop replaces it.
    private var currentItemObservation: NSKeyValueObservation?
    private weak var observedItem: AVPlayerItem?
    private var failureReported = false
    /// The file this player was loaded with. Once the audio has been dropped
    /// the playing item's asset is a composition, so the poster fallback and
    /// the silent rebuild open the file from here rather than from the item.
    private var mediaURL: URL?
    /// Set once the item carrying the clip's audio has failed and been
    /// replaced by a video-only one. One attempt only: a failure of the
    /// video-only item is about the picture and goes to the host.
    private var audioDropped = false
    private var rebuild: Task<Void, Never>?
    /// The clip's display matrix, read once at load. `nil` until the read
    /// finishes; a clip whose matrix cannot be read is treated as upright.
    ///
    /// The picture the layer shows has this matrix applied, but the frames a
    /// video output hands back do not, so it decides which poster path can be
    /// trusted for an upright result.
    private var displayTransform: CGAffineTransform?
    private var orientationTask: Task<Void, Never>?
    /// Reported when the clip keeps playing without its audio, with the
    /// failure that caused it, so the host can log it against its load.
    var onAudioDropped: (@MainActor (String) -> Void)?
    /// A failure seen before anyone was listening. The host installs its
    /// callback after constructing the surface, and a synchronous failure at
    /// load would otherwise be dropped on the floor — which is the one case
    /// where the display ends up black with no hand-off.
    private var pendingFailure: String?
    var isReadyForDisplay: Bool { !stopped && layer.isReadyForDisplay }
    var onReadyForDisplay: (@MainActor () -> Void)? {
        didSet { if isReadyForDisplay { onReadyForDisplay?() } }
    }

    /// Reported when the platform player cannot prepare or play the asset,
    /// with this surface's generation so a late failure cannot be attributed
    /// to whatever replaced it.
    var onPreparationFailure: (@MainActor (UInt64, String) -> Void)? {
        didSet {
            guard let pendingFailure, onPreparationFailure != nil else { return }
            self.pendingFailure = nil
            onPreparationFailure?(surface.generation, pendingFailure)
        }
    }

    init(
        surface: RuntimeSurfaceKey,
        counters: RuntimeCounters,
        paused: Bool
    ) {
        self.surface = surface
        self.counters = counters
        self.userPaused = paused
        player.actionAtItemEnd = .advance
        // Nothing here needs the system's "now playing" treatment, and taking
        // the audio session focus would interrupt whatever the user is
        // listening to.
        player.preventsDisplaySleepDuringVideoPlayback = false
        layer.player = player
        layer.videoGravity = .resizeAspectFill
    }

    func attach(to view: NSView) {
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
    }

    func load(url: URL) {
        mediaURL = url
        let item = AVPlayerItem(url: url)
        readDisplayTransform(of: item.asset)
        start(item)
    }

    /// Reads the display matrix from the asset the player itself is loading,
    /// so the file is not opened a second time for it.
    private func readDisplayTransform(of asset: AVAsset) {
        orientationTask?.cancel()
        orientationTask = Task { @MainActor [weak self] in
            let transform: CGAffineTransform
            do {
                transform = try await Self.loadDisplayTransform(of: asset)
            } catch {
                AppLog.debug(
                    "native video: could not read the clip's orientation "
                        + "(\(Self.describe(error))); treating it as upright")
                transform = .identity
            }
            guard let self, !self.stopped, !Task.isCancelled else { return }
            self.displayTransform = transform
        }
    }

    /// The display matrix of the clip's first video track, or the identity for
    /// a clip with no video track.
    nonisolated static func loadDisplayTransform(of asset: AVAsset) async throws
        -> CGAffineTransform
    {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            return .identity
        }
        return try await video.load(.preferredTransform)
    }

    /// Whether a frame read back from a video output differs in orientation
    /// from the picture the layer shows.
    ///
    /// Any rotation or flip does: `AVPlayerItem.presentationSize` and the layer
    /// follow the matrix, while the output's buffers stay in the file's own
    /// orientation. Such a clip is read with `AVAssetImageGenerator`, which
    /// applies the matrix itself.
    nonisolated static func needsUprightGenerator(_ transform: CGAffineTransform) -> Bool {
        !transform.isIdentity
    }

    private func start(_ item: AVPlayerItem) {
        // AVPlayerLooper takes ownership of the queue, so it is created once
        // per item and replaced wholesale rather than mutated.
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.looper = looper
        counters.record(.nativeVideoItemCreated, for: surface)
        observeFailures(looper: looper)
        applyPlaybackState()
    }

    /// Takes the looper and its queued copies down, leaving the player and
    /// its layer in place for whatever is loaded next.
    private func releaseItem() {
        guard let looper else { return }
        // Removing the queue makes the item fail on its way out; that is this
        // teardown, not a fault worth reacting to.
        statusObservations.removeAll()
        currentItemObservation = nil
        observedItem = nil
        detachPosterOutput()
        // The looper holds the queue; disabling it first stops it re-filling
        // the queue while the items are being removed.
        looper.disableLooping()
        self.looper = nil
        player.removeAllItems()
        counters.record(.nativeVideoItemReleased, for: surface)
    }

    /// Watches for the asset turning out to be unplayable after admission
    /// already accepted it.
    ///
    /// Admission reads metadata; this is playback. A track whose properties
    /// load cleanly can still fail to decode — a truncated file, a codec this
    /// machine cannot play, a busy decoder. Nothing else observes that, so
    /// without this the wallpaper stays selected by a backend that cannot show
    /// it while the scene engine is excluded.
    ///
    /// **Not the template item.** `AVPlayerLooper` does not play the item it
    /// was constructed with; it enqueues copies of it. Observing the template
    /// watches an object that never plays and never fails, which is a fault
    /// that no fake-surface test can see. What matters is whatever
    /// `currentItem` is at the time, and the loop replaces that, so the
    /// observation follows it.
    private func observeFailures(looper: AVPlayerLooper) {
        statusObservations = [
            layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    self.onReadyForDisplay?()
                }
            },
            // `.initial` matters: the looper can already be `.failed` by the
            // time this runs, and a `.new`-only subscription would miss it.
            looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let detail = looper.error.map(Self.describe) ?? "player looper failed"
                MainActor.assumeIsolated { self?.playbackFailed(detail) }
            },
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                MainActor.assumeIsolated { self?.followCurrentItem(player.currentItem) }
            },
        ]
    }

    /// Re-points the item-status observation at whatever is playing now.
    private func followCurrentItem(_ item: AVPlayerItem?) {
        guard !stopped else { return }
        guard let item else {
            currentItemObservation = nil
            return
        }
        guard item !== observedItem else { return }
        observedItem = item
        currentItemObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            guard item.status == .failed else { return }
            let detail = item.error.map(Self.describe) ?? "player item failed"
            MainActor.assumeIsolated { self?.playbackFailed(detail) }
        }
    }

    /// The platform player failed. A clip with sound gets one more attempt
    /// without it before the host is told.
    ///
    /// AVFoundation fails the whole item when its audio output cannot start —
    /// no output device, or one that will not start (`kAudioQueueErr_CannotStart`)
    /// — and reports it as the generic `AVErrorUnknown`, with nothing that
    /// says which half of the clip failed. Muting does not help: the muted
    /// player still starts the audio queue. Handing that to the scene engine
    /// recorded the clip as unplayable for the session, although its picture
    /// plays perfectly well. Which half failed is decided by evidence rather
    /// than by error code: the clip is rebuilt with its video track alone, and
    /// a fault in the picture fails that item too and reaches the host as
    /// before. A clip with no audio has nothing to leave out and is reported
    /// straight away.
    private func playbackFailed(_ detail: String) {
        guard !stopped, !failureReported, rebuild == nil else { return }
        guard !audioDropped, let mediaURL else {
            reportPreparationFailure(detail)
            return
        }
        audioDropped = true
        rebuild = Task { @MainActor [weak self] in
            let silent = await Self.videoOnlyItem(url: mediaURL)
            guard let self, !self.stopped else { return }
            self.rebuild = nil
            guard let silent else {
                self.reportPreparationFailure(detail)
                return
            }
            self.releaseItem()
            self.onAudioDropped?(detail)
            self.start(silent)
        }
    }

    /// The clip with its audio left out, or `nil` when it has no audio track
    /// to leave out or its video track cannot be read.
    static func videoOnlyItem(url: URL) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: url)
        do {
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                let video = try await asset.loadTracks(withMediaType: .video).first
            else { return nil }
            let (range, transform) = try await video.load(.timeRange, .preferredTransform)
            let composition = AVMutableComposition()
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            try track.insertTimeRange(range, of: video, at: .zero)
            track.preferredTransform = transform
            return AVPlayerItem(asset: composition)
        } catch {
            return nil
        }
    }

    /// The error with its domain and code, and those of the errors beneath
    /// it. AVFoundation's own description is often only "The operation could
    /// not be completed", localized; the codes are what tell an audio device
    /// that would not start from a decoder fault in a report.
    nonisolated static func describe(_ error: Error) -> String {
        var codes: [String] = []
        var next: NSError? = error as NSError
        while let current = next, codes.count < 4 {
            codes.append("\(current.domain) \(current.code)")
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(error.localizedDescription) (\(codes.joined(separator: " < ")))"
    }

    /// Reported once. Both observations can fire for one underlying fault, and
    /// a second report would be a second hand-off for a wallpaper the host has
    /// already given away.
    private func reportPreparationFailure(_ detail: String) {
        guard !stopped, !failureReported else { return }
        failureReported = true
        guard onPreparationFailure != nil else {
            // Nobody is listening yet. Held rather than dropped; installing
            // the callback delivers it.
            pendingFailure = detail
            return
        }
        onPreparationFailure?(surface.generation, detail)
    }

    func setScaling(_ mode: BridgeScalingMode) {
        // The subset this backend declares. Anything else is refused before a
        // window is created, so there is no silent substitution here.
        layer.videoGravity = mode == .stretch ? .resize : .resizeAspectFill
    }

    func setVolume(_ volume: Float, muted: Bool) {
        player.volume = max(0, min(volume, 1))
        player.isMuted = muted
    }

    /// The user's own pause. Independent of presentation suspension: a display
    /// becoming visible again must not start a wallpaper the user paused.
    func setUserPaused(_ paused: Bool) {
        userPaused = paused
        applyPlaybackState()
    }

    func setPresentationSuspended(_ suspended: Bool) {
        guard presentationSuspended != suspended else { return }
        presentationSuspended = suspended
        counters.record(
            suspended ? .presentationSuspended : .presentationResumed, for: surface)
        applyPlaybackState()
    }

    var isPlaying: Bool { player.rate > 0 }

    /// Queued item count, as the system actually reports it.
    ///
    /// `AVPlayerLooper` keeps more than one copy of the template item queued to
    /// make the seam gapless, so this is deliberately not claimed to be one.
    var queuedItemCount: Int { player.items().count }

    /// The item the player is actually playing. Exposed because the loop
    /// replaces it: a poster taken from the looper's template would be a
    /// frame from a different object than the one on screen.
    var currentItemForTest: AVPlayerItem? { player.currentItem }
    var posterOutputIsAttachedForTest: Bool { videoOutput != nil }
    /// Playback position inside the item that is playing. A loop restarts it,
    /// which is how a test tells a wrap from a stall.
    var playbackTimeForTest: CMTime { player.currentItem?.currentTime() ?? .invalid }
    /// `AVPlayerLayer.isReadyForDisplay`. This means the layer has a frame it
    /// could display — not that anything reached a screen. The two are
    /// reported separately and the second one is not observable here.
    var layerIsReadyForDisplayForTest: Bool { layer.isReadyForDisplay }
    var itemStatusForTest: AVPlayerItem.Status? { player.currentItem?.status }
    var audioDroppedForTest: Bool { audioDropped }
    /// Sends the audio to an output that does not exist: an audio path that
    /// cannot start, reproduced without opening a real output device.
    func setAudioOutputDeviceForTest(_ uniqueID: String) {
        player.audioOutputDeviceUniqueID = uniqueID
    }

    /// One frame for a poster request, from the item that is playing.
    ///
    /// Concurrent requests coalesce into one. Nothing here resumes playback:
    /// a paused player answers from the last frame it produced, because
    /// resuming to take a screenshot would restart decode, audio and power
    /// draw the user had stopped.
    func posterImage() async -> CGImage? {
        guard !stopped else { return nil }
        if let posterRequest { return await posterRequest.value }
        let request = Task { @MainActor [weak self] in
            await self?.producePoster() ?? nil
        }
        posterRequest = request
        let image = await request.value
        if posterRequest == request { posterRequest = nil }
        return image
    }

    private func producePoster() async -> CGImage? {
        defer { detachPosterOutput() }
        // A header read that normally finished long ago; awaited so the first
        // request can never pick the path before the orientation is known.
        await orientationTask?.value
        if Self.needsUprightGenerator(displayTransform ?? .identity) {
            // The playing item's frames would come back un-rotated. Skip the
            // video output altogether rather than read frames to discard them.
            guard !stopped, let item = player.currentItem else { return lastPoster }
            return await generatorPoster(for: item) ?? lastPoster
        }
        for step in 0..<Self.posterWaitSteps {
            guard !stopped, let item = player.currentItem else { return lastPoster }
            // Re-resolved every step: crossing a loop boundary replaces
            // `currentItem`, and an output attached to the retired copy would
            // never produce another frame.
            let output = attachPosterOutput(to: item)
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time),
                let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                let image = Self.makeImage(from: buffer)
            {
                counters.record(.readinessFrameRendered, for: surface)
                lastPoster = image
                return image
            }
            if step + 1 < Self.posterWaitSteps {
                try? await Task.sleep(for: Self.posterWaitStep)
            }
        }
        guard !stopped else { return nil }
        if let item = player.currentItem, let image = await generatorPoster(for: item) {
            return image
        }
        // Still nothing: the last frame this player produced is a truthful
        // answer, and nil is a truthful "none yet". Neither resumes playback.
        return lastPoster
    }

    /// One upright frame from a one-shot image generator, created and
    /// released inside this request.
    ///
    /// It is a second decode of a few frames, which is why it is counted: a
    /// permanently retained generator would be a second decoder for the whole
    /// session. A rotated or mirrored clip takes this path for every poster,
    /// an upright one only when the playing item produced no frame in time.
    /// Playback is never resumed to make the picture.
    private func generatorPoster(for item: AVPlayerItem) async -> CGImage? {
        guard let mediaURL else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        counters.record(.nativeVideoPosterFallback, for: surface)
        guard let image = try? await generator.image(at: item.currentTime()).image,
            !stopped
        else { return nil }
        lastPoster = image
        return image
    }

    private func attachPosterOutput(to item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let output = videoOutput, outputItem === item { return output }
        detachPosterOutput()
        let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        outputItem = item
        return output
    }

    private func detachPosterOutput() {
        if let output = videoOutput, let item = outputItem {
            item.remove(output)
        }
        videoOutput = nil
        outputItem = nil
    }

    private static func makeImage(from buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        // Retains nothing: no Core Image context is kept alive between
        // requests, so a failed poster leaves no converter behind.
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            == noErr
        else { return nil }
        return image
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        // A request still in flight belongs to this surface. Cancelling it
        // here is what keeps its frame from being delivered to whatever opens
        // next on the same display.
        posterRequest?.cancel()
        posterRequest = nil
        rebuild?.cancel()
        rebuild = nil
        orientationTask?.cancel()
        orientationTask = nil
        detachPosterOutput()
        lastPoster = nil
        pendingFailure = nil
        onPreparationFailure = nil
        onReadyForDisplay = nil
        onAudioDropped = nil
        player.pause()
        releaseItem()
        layer.player = nil
        layer.removeFromSuperlayer()
    }

    private func applyPlaybackState() {
        guard !stopped else { return }
        if userPaused || presentationSuspended {
            player.pause()
        } else {
            player.play()
        }
    }
}
