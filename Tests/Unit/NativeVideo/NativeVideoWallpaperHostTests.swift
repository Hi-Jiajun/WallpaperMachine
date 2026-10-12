import AppKit
import ImageIO
import XCTest

@testable import WallpaperMachine

/// The routing and fallback contract of the experimental native video backend.
///
/// Three properties decide whether this backend is safe to ship switched off:
/// a wallpaper it cannot honour goes back to the scene engine exactly once, a
/// display's own visibility never overrides the user's own pause, and a
/// refusal stops applying once the configuration it described has changed.
@MainActor
final class NativeVideoWallpaperHostTests: XCTestCase {
    private func wallpaper(
        displayID: UInt32 = 7,
        id: String = "300",
        fps: UInt32 = 60,
        admissionFps: UInt32? = nil,
        paused: Bool = false,
        volume: Float = 1.0,
        muted: Bool = false,
        admissionKey: UInt64 = 1
    ) -> BridgeNativeVideoWallpaper {
        BridgeNativeVideoWallpaper(
            displayId: displayID,
            startupRevision: 0,
            wallpaperId: id,
            title: "Clip",
            mediaPath: "/tmp/does-not-need-to-exist/clip.mp4",
            fps: fps,
            admissionFps: admissionFps ?? fps,
            admissionKey: admissionKey,
            paused: paused,
            volume: volume,
            muted: muted,
            scalingMode: .fill,
            scalingFactor: 1.0)
    }

    private final class Recorder {
        var rejected: [(id: String, key: UInt64, reason: String)] = []
        var fetched = 0
        var presented = 0
        var stopped = 0
        var admissionProbes: [UInt64] = []
        var refusalSequence: [NativeVideoRefusal?] = []
    }

    /// Stands in for the desktop window. The controller's rules are what these
    /// tests are about, and an automated run has no authorization to put a
    /// window on the desktop. The real window and player are covered by
    /// `NativeVideoPlayerMediaTests`, which is opt-in.
    @MainActor
    private final class FakeSurface: NativeVideoSurface {
        private let recorder: Recorder
        private var userPaused: Bool
        private var suspended = false
        private(set) var isStopped = false
        var isReadyForDisplay = false
        var onReadyForDisplay: (@MainActor () -> Void)?
        var volume: Float = 1
        var muted = false
        var posterLayer: CALayer? = CALayer()
        private(set) var frame = NSRect.zero
        func setScreenFrame(_ frame: NSRect) { self.frame = frame }
        /// Poster answer, and how long it takes. The delay is what lets a test
        /// replace the surface while a request is still in flight.
        var poster: CGImage?
        var posterDelay: Duration = .zero
        /// Delivered synchronously the moment a callback is installed, which
        /// is what the real player does when it was already holding a failure.
        var failureOnInstall: String?
        var onPreparationFailure: (@MainActor (UInt64, String) -> Void)? {
            didSet {
                guard let failureOnInstall, onPreparationFailure != nil else { return }
                self.failureOnInstall = nil
                onPreparationFailure?(generation, failureOnInstall)
            }
        }
        var onAudioDropped: (@MainActor (String) -> Void)?
        /// The generation this surface was opened with, so a test can report a
        /// failure as either this surface's or a stale one's.
        let generation: UInt64

        init(recorder: Recorder, paused: Bool, generation: UInt64) {
            self.recorder = recorder
            self.userPaused = paused
            self.generation = generation
        }

        /// Stands in for `AVPlayerItem.status` becoming `.failed`.
        func failPreparation(_ detail: String, generation: UInt64? = nil) {
            onPreparationFailure?(generation ?? self.generation, detail)
        }

        func setVolume(_ volume: Float, muted: Bool) {
            self.volume = volume
            self.muted = muted
        }
        func setScaling(_ mode: BridgeScalingMode) {}
        func setUserPaused(_ paused: Bool) { userPaused = paused }
        func setPresentationSuspended(_ suspended: Bool) { self.suspended = suspended }
        var isPlaying: Bool { !isStopped && !userPaused && !suspended }
        func posterImage() async -> CGImage? {
            if posterDelay != .zero { try? await Task.sleep(for: posterDelay) }
            return poster
        }
        func present() { recorder.presented += 1 }
        func stop() {
            isStopped = true
            recorder.stopped += 1
        }
    }

    private static func makeImage() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    private var surfacesMade: [UInt32: FakeSurface] = [:]
    private var screenFrames: [(id: UInt32, frame: NSRect)] = []
    /// Makes every surface this factory builds fail as its callback is installed.
    private var surfaceFailureOnInstall: String?

    private func makeHost(
        wallpapers: [BridgeNativeVideoWallpaper],
        refusal: NativeVideoRefusal? = nil,
        refusalByKey: [UInt64: NativeVideoRefusal] = [:],
        /// Consumed one entry per probe, so a transient failure that clears on
        /// a retry can be expressed. Falls through to the other two once empty.
        refusalSequence: [NativeVideoRefusal?] = [],
        recorder: Recorder,
        frameCenter: NotificationCenter = NotificationCenter()
    ) -> NativeVideoWallpaperHost {
        recorder.refusalSequence = refusalSequence
        return NativeVideoWallpaperHost(
            fetch: {
                recorder.fetched += 1
                return wallpapers
            },
            reject: { id, key, reason in
                recorder.rejected.append((id: id, key: key, reason: reason))
            },
            screens: { [weak self] in self?.screenFrames ?? [] },
            refusal: { _, fps in
                // The injected decision stands in for the asset probe; the key
                // is reconstructed from the target rate the host passed, which
                // is the input the real rule reads.
                recorder.admissionProbes.append(UInt64(fps))
                if !recorder.refusalSequence.isEmpty {
                    return recorder.refusalSequence.removeFirst()
                }
                return refusalByKey[UInt64(fps)] ?? refusal
            },
            makeSurface: { [weak self] _, frame, key, paused in
                let surface = FakeSurface(
                    recorder: recorder, paused: paused, generation: key.generation)
                surface.setScreenFrame(frame)
                surface.failureOnInstall = self?.surfaceFailureOnInstall
                self?.surfacesMade[key.displayID] = surface
                return surface
            },
            frameCenter: frameCenter,
            counters: RuntimeCounters())
    }

    func testStartupWaitsForSurfaceReadinessAndAcknowledgesNewRevisions() async throws {
        screenFrames = [(7, NSRect(x: 0, y: 0, width: 80, height: 60))]
        var descriptor = wallpaper()
        descriptor.startupRevision = 4
        let host = makeHost(wallpapers: [], recorder: Recorder())
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }
        defer { host.shutdown() }
        await host.apply([descriptor])
        XCTAssertEqual(states.map(\.phase), [.loading])
        let surface = try XCTUnwrap(surfacesMade[7])
        surface.isReadyForDisplay = true
        surface.onReadyForDisplay?()
        XCTAssertEqual(states.last?.phase, .ready)
        XCTAssertEqual(states.last?.startupRevision, 4)
        descriptor.startupRevision = 5
        await host.apply([descriptor])
        XCTAssertTrue(surfacesMade[7] === surface)
        XCTAssertEqual(states.last?.startupRevision, 5)
        XCTAssertEqual(states.last?.phase, .ready)
        let count = states.count
        await host.apply([descriptor])
        XCTAssertEqual(states.count, count)
        var replacement = wallpaper(id: "replacement", admissionKey: 2)
        replacement.startupRevision = 6
        await host.apply([replacement])
        let afterReplacement = states.count
        surface.onReadyForDisplay?()
        surface.failPreparation("late failure")
        XCTAssertEqual(states.count, afterReplacement)
        XCTAssertEqual(states.last?.wallpaperID, "replacement")
        XCTAssertEqual(states.last?.phase, .loading)
    }

    func testPreparationFailureEndsStartupWithoutReportingReady() async throws {
        screenFrames = [(7, NSRect(x: 0, y: 0, width: 80, height: 60))]
        let host = makeHost(wallpapers: [], recorder: Recorder())
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }
        defer { host.shutdown() }
        await host.apply([wallpaper()])
        try XCTUnwrap(surfacesMade[7]).failPreparation("synthetic unavailable media")
        XCTAssertEqual(states.last?.phase, .failed)
        XCTAssertNotNil(states.last?.message)
        XCTAssertFalse(states.contains { $0.phase == .ready })
    }

    override func setUp() {
        super.setUp()
        surfacesMade = [:]
        screenFrames = [
            (id: 7, frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
            (id: 9, frame: NSRect(x: 200, y: 0, width: 200, height: 100)),
        ]
        surfaceFailureOnInstall = nil
    }

    func testAWallpaperTheBackendCannotHonourIsHandedBack() async {
        // A 60 fps clip under a 30 fps target cannot be honoured without either
        // slowing the video down or copying every frame through the CPU, so the
        // scene engine has to take it.
        //
        // This deliberately does NOT assert "exactly once across two offers".
        // That was the old local skip list, and it is what left a display with
        // no backend when the bridge legitimately re-offered a key. Not
        // oscillating between backends is the bridge's guarantee, pinned by
        // `a_refused_wallpaper_goes_back_to_the_engine_and_stays_there`: it
        // records the refusal and stops offering. The host's job is to answer
        // what it is actually offered.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(fps: 30)],
            refusal: .targetFrameRateBelowContent(target: 30, bound: 60, source: "minFrameDuration"),
            recorder: recorder)

        await host.apply([wallpaper(fps: 30)])

        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.id, "300")
        XCTAssertTrue(recorder.rejected.first?.reason.contains("target frame rate") == true)
        XCTAssertTrue(host.isEmpty, "a refused wallpaper must not leave a window behind")
        host.shutdown()
    }

    func testTheRefusalTravelsWithTheKeyItWasDecidedAgainst() async {
        // A verdict that arrives after the user changed the target rate
        // describes a configuration that no longer exists. The bridge can only
        // tell that if the key is reported with the refusal.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(fps: 30, admissionKey: 0xBEEF)],
            refusal: .targetFrameRateBelowContent(target: 30, bound: 60, source: "nominalFrameRate"),
            recorder: recorder)

        await host.apply([wallpaper(fps: 30, admissionKey: 0xBEEF)])

        XCTAssertEqual(recorder.rejected.first?.key, 0xBEEF)
        host.shutdown()
    }

    func testChangingTheTargetRateIsEvaluatedAgainRatherThanStayingRefused() async {
        // The round-3 behaviour: once refused, refused for the session. Raising
        // the target to something the clip fits has to bring it back.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalByKey: [
                30: .targetFrameRateBelowContent(target: 30, bound: 60, source: "nominalFrameRate")
            ],
            recorder: recorder)

        await host.apply([wallpaper(fps: 30, admissionKey: 30)])
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(recorder.rejected.count, 1)

        await host.apply([wallpaper(fps: 60, admissionKey: 60)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the new configuration must be evaluated")
        XCTAssertEqual(recorder.rejected.count, 1, "and must not inherit the old verdict")
        host.shutdown()
    }

    func testLoweringTheTargetRateUnderARunningClipReEvaluatesIt() async {
        // The wallpaper id does not change, so round 4's first version kept
        // the player and only pushed the new descriptor at it: a 60 fps clip
        // carried on playing at 60 under a 30 fps target. Admission exists to
        // stop exactly that, so a changed admission key has to go through it.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalByKey: [
                30: .targetFrameRateBelowContent(target: 30, bound: 60, source: "minFrameDuration")
            ],
            recorder: recorder)
        await host.apply([wallpaper(fps: 60, admissionKey: 60)])
        XCTAssertEqual(host.activeDisplayIDs, [7])

        await host.apply([wallpaper(fps: 30, admissionKey: 30)])

        XCTAssertTrue(
            host.isEmpty, "the accepted player must not survive a target it was never admitted for")
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.key, 30)
        XCTAssertEqual(recorder.stopped, 1, "and it must be stopped, not merely dropped")
        host.shutdown()
    }

    func testReplacingTheMediaAtTheSamePathReloadsTheSurface() async {
        // Same id, same path, different bytes — which the key covers through
        // the file's length and mtime. Keeping the player would go on showing
        // the file that is no longer there.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(admissionKey: 1)])
        let first = host.surfaceGenerationForTest

        await host.apply([wallpaper(admissionKey: 2)])

        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertNotEqual(
            host.surfaceGenerationForTest, first, "new media identity is a new surface")
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(recorder.admissionProbes.count, 2, "and it is admitted again, not assumed")
        host.shutdown()
    }

    func testAnAssetThatFailsToPlayAfterAdmissionIsHandedToTheSceneEngine() async {
        // Metadata loading and playback are different things. A clip whose
        // track properties read cleanly can still fail to decode, and only the
        // player sees that. Without a hand-off the display shows black with
        // the scene engine excluded — both backends off one display.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(admissionKey: 9)])
        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertTrue(recorder.rejected.isEmpty, "admission accepted it")

        surfacesMade[7]?.failPreparation("decoder could not open the track")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(host.isEmpty, "the failed player must stop")
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.key, 9)
        XCTAssertTrue(
            recorder.rejected.first?.reason.contains("could not play") == true,
            "the reason must say playback failed, not that the metadata was refused")
        host.shutdown()
    }

    func testAClipThatKeepsPlayingWithoutItsAudioStaysNative() async {
        // An audio output that will not start fails the whole item, and the
        // player answers by playing the picture alone. That is the player
        // recovering, not failing: handing it back here would put the clip on
        // the scene engine for the session, which is how issue 31 ended up
        // with a black desktop.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(admissionKey: 5)])
        let surface = surfacesMade[7]

        surface?.onAudioDropped?("audio output could not start")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertTrue(host.isPlaying(displayID: 7) == true)
        XCTAssertEqual(recorder.stopped, 0)
        XCTAssertTrue(recorder.rejected.isEmpty, "nothing is handed to the scene engine")
        host.shutdown()
    }

    func testAFailureOnTheFirstDisplayIsNotDiscardedBecauseASecondOpened() async {
        // `surfaceGeneration` is host-wide, so comparing a failure against it
        // discarded display 7's real failure the moment display 9 opened: that
        // display stayed native-selected with the scene engine excluded and
        // showed black. Staleness has to be surface identity, not a counter.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([
            wallpaper(displayID: 7, id: "300", admissionKey: 1),
            wallpaper(displayID: 9, id: "301", admissionKey: 2),
        ])
        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        let first = surfacesMade[7]

        first?.failPreparation("decoder could not open the track")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            host.activeDisplayIDs, [9],
            "the failing display must hand over; the other must keep playing")
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.key, 1)
        host.shutdown()
    }

    func testASurfaceThatFailsWhileItsCallbackIsInstalledIsNeverPresented() async {
        // The player can already be holding a failure when the host installs
        // its callback, and installing delivers it synchronously — so the
        // hand-off closes this surface in the middle of opening it. Carrying on
        // to present() would order a stopped, unregistered window onto the
        // desktop: an orphan nothing owns and nothing can close.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        surfaceFailureOnInstall = "decoder could not open the track"

        await host.apply([wallpaper(admissionKey: 12)])
        // The hand-off is spawned from the failure callback, so let it drain.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.presented, 0, "a surface that failed on install must not be shown")
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(recorder.stopped, 1, "and it must have been stopped")
        XCTAssertEqual(recorder.rejected.count, 1, "the scene engine takes it")
        host.shutdown()
    }

    func testAPlaybackFailureFromAReplacedSurfaceIsIgnored() async {
        // The asynchronous twin of the poster case: a failure that arrives
        // after this display moved on must not condemn whatever is playing now.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        let stale = surfacesMade[7]
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        XCTAssertEqual(host.activeDisplayIDs, [7])

        stale?.failPreparation("late failure", generation: 1)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            host.activeDisplayIDs, [7], "the current wallpaper must still be playing")
        XCTAssertTrue(recorder.rejected.isEmpty, "and nothing may be handed back for it")
        host.shutdown()
    }

    func testATransientMetadataFailureIsRetriedRatherThanDemotingTheWallpaper() async {
        // A file still being written, or a busy volume, says nothing about
        // whether this backend can honour the content. Treating it as a
        // refusal would hand the wallpaper away for the whole session.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalSequence: [.preparationFailed("resource temporarily unavailable"), nil],
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 5)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the retry has to be allowed to succeed")
        XCTAssertTrue(recorder.rejected.isEmpty, "a transient failure is not a refusal")
        XCTAssertEqual(recorder.admissionProbes.count, 2)
        host.shutdown()
    }

    func testAPersistentMetadataFailureStopsRetryingAndHandsOff() async {
        // The other half of the bound: a file that never loads must not leave
        // the display with no wallpaper at all, and must not be re-read
        // forever.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusal: .preparationFailed("input/output error"),
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 6)])
        await host.apply([wallpaper(admissionKey: 6)])

        XCTAssertEqual(
            recorder.admissionProbes.count, NativeVideoWallpaperHost.admissionAttemptLimit,
            "retries are bounded and the settled answer is cached, so the second offer "
                + "costs no further file reads")
        XCTAssertEqual(
            recorder.rejected.count, 2, "each offer is answered; the bridge is what stops offering")
        XCTAssertTrue(host.isEmpty)
        host.shutdown()
    }

    func testAKeyRefusedThenSupersededThenOfferedAgainIsReportedAgain() async {
        // The bridge prunes a refusal whose key no longer matches any live
        // display slot. Going 30 -> 60 -> 30 therefore brings key 30 back as a
        // fresh offer. A permanent local skip list made the host ignore it
        // while the bridge had already excluded the scene engine for that
        // display: no native surface, no scene, nothing on screen.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalByKey: [
                30: .targetFrameRateBelowContent(target: 30, bound: 60, source: "minFrameDuration")
            ],
            recorder: recorder)

        await host.apply([wallpaper(fps: 30, admissionKey: 30)])
        XCTAssertEqual(recorder.rejected.count, 1)

        await host.apply([wallpaper(fps: 60, admissionKey: 60)])
        XCTAssertEqual(host.activeDisplayIDs, [7], "60 is admissible")

        await host.apply([wallpaper(fps: 30, admissionKey: 30)])

        XCTAssertTrue(host.isEmpty, "30 is still not admissible")
        XCTAssertEqual(
            recorder.rejected.count, 2,
            "the offer must be answered again, not silently skipped")
        XCTAssertEqual(recorder.rejected.last?.key, 30)
        host.shutdown()
    }

    func testARepeatedOfferOfAStillRefusedKeyIsAnsweredEachTimeItIsOffered() async {
        // The bridge stops offering a key once it records the refusal, so in
        // practice this does not repeat. What must not happen is the host
        // deciding on its own to stop answering: that is the state where the
        // two sides disagree and a display falls through the gap.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusal: .notPlayable("no video track"),
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 77)])
        await host.apply([wallpaper(admissionKey: 77)])

        XCTAssertEqual(recorder.rejected.count, 2)
        XCTAssertEqual(
            recorder.admissionProbes.count, 1,
            "but the file is still only read once, because the verdict is cached")
        host.shutdown()
    }

    func testAMirrorIsJudgedByItsGroupsStrictestTargetNotTheSourcesOwn() async {
        // A 60 fps clip on a source display targeting 60, mirrored to a display
        // targeting 30. The bridge gives both members the same admission key
        // and an admissionFps of 30 — the strictest in the group. Probing the
        // per-display `fps` instead would evaluate 60, accept, and then play
        // the mirror at 60 under a 30 fps target: the silent rate change
        // admission exists to prevent, reached through the one path that used
        // to skip admission entirely.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalByKey: [
                30: .targetFrameRateBelowContent(target: 30, bound: 60, source: "minFrameDuration")
            ],
            recorder: recorder)

        await host.apply([
            wallpaper(displayID: 7, fps: 60, admissionFps: 30, admissionKey: 99),
            wallpaper(displayID: 9, fps: 30, admissionFps: 30, admissionKey: 99),
        ])

        XCTAssertEqual(recorder.admissionProbes, [30], "the group is probed at its strictest target")
        XCTAssertTrue(host.isEmpty, "neither member may play a rate the group cannot honour")
        XCTAssertFalse(recorder.rejected.isEmpty)
        XCTAssertTrue(
            recorder.rejected.allSatisfy { $0.key == 99 },
            "one key covers the group, so one recorded refusal sends all of it back")
        host.shutdown()
    }

    func testAMirrorGroupWithinTheClipsRateIsStillAdmitted() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)

        await host.apply([
            wallpaper(displayID: 7, fps: 120, admissionFps: 60, admissionKey: 100),
            wallpaper(displayID: 9, fps: 60, admissionFps: 60, admissionKey: 100),
        ])

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertEqual(recorder.admissionProbes, [60], "one probe covers the group")
        XCTAssertTrue(recorder.rejected.isEmpty)
        host.shutdown()
    }

    func testTheSameOfferIsProbedOnceEvenAcrossRepeatedPasses() async {
        // Reconcile runs on display changes, wallpaper changes and suspension
        // changes. Re-reading the media file on each of those would be a file
        // read per pass for a decision that cannot have changed.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)

        await host.apply([wallpaper(admissionKey: 11)])
        await host.apply([])
        await host.apply([wallpaper(admissionKey: 11)])

        XCTAssertEqual(recorder.admissionProbes.count, 1)
        host.shutdown()
    }

    func testAnUnplayableAssetIsHandedBackWithItsReason() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper()],
            refusal: .notPlayable("no video track"),
            recorder: recorder)

        await host.apply([wallpaper()])

        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertTrue(recorder.rejected.first?.reason.contains("no video track") == true)
        XCTAssertTrue(host.isEmpty)
        host.shutdown()
    }

    func testAnAcceptedWallpaperOpensExactlyOneSurfacePerDisplay() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")],
            recorder: recorder)

        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")])

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertTrue(recorder.rejected.isEmpty)
        XCTAssertEqual(recorder.presented, 2)
        host.shutdown()
        XCTAssertTrue(host.isEmpty, "shutdown must leave no player running")
        XCTAssertEqual(recorder.stopped, 2, "every surface has to be stopped, not just dropped")
    }

    func testHidingOneDisplayLeavesTheOtherPlaying() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")],
            recorder: recorder)
        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")])

        host.setPresentationSuspended(true, forDisplay: 9)

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertTrue(host.isPlaying(displayID: 7) == true)
        XCTAssertTrue(host.isPlaying(displayID: 9) == false)
        host.shutdown()
    }

    func testRevealingADisplayDoesNotStartAWallpaperTheUserPaused() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper(paused: true)], recorder: recorder)
        await host.apply([wallpaper(paused: true)])

        host.setPresentationSuspended(true, forDisplay: 7)
        host.setPresentationSuspended(false, forDisplay: 7)

        XCTAssertEqual(
            host.isPlaying(displayID: 7), false,
            "visibility must never clear the user's own pause")
        host.shutdown()
    }

    func testAGlobalResumeKeepsADisplayThatIsStillHiddenStopped() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper()])

        host.setPresentationSuspended(true, forDisplay: 7)
        host.setPresentationSuspended(true)
        host.setPresentationSuspended(false)

        XCTAssertEqual(host.isPlaying(displayID: 7), false)
        host.setPresentationSuspended(false, forDisplay: 7)
        XCTAssertEqual(host.isPlaying(displayID: 7), true)
        host.shutdown()
    }

    func testAClipStoppedByACoveredDesktopPlaysAgainWhenTheHostsReadTheBridgeAgain() async {
        // The bridge folds a covered desktop into the descriptor's `paused`, and
        // committing the change returns no snapshot. A pass that runs while it
        // holds (the status menu opening, the charger being plugged in) leaves
        // the clip user-paused by that reading, and uncovering the desktop only
        // lifts the host's own suspension: the reading stays until the hosts
        // are told to read again.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper(paused: false)], recorder: recorder)
        defer { host.shutdown() }
        await host.apply([wallpaper()])
        host.setPresentationSuspended(true)
        await host.apply([wallpaper(paused: true)])
        host.setPresentationSuspended(false)
        XCTAssertEqual(
            host.isPlaying(displayID: 7), false, "the covered reading is still what the clip holds")

        await reconcile(WallpaperHosts(web: nil, native: host), host)

        XCTAssertEqual(host.isPlaying(displayID: 7), true)
    }

    func testAClipOnADisplayThatWasHiddenPlaysAgainWhenTheHostsReadTheBridgeAgain() async {
        // The same for one display: its own suspension is part of that display's
        // `paused`, and showing it again returns no snapshot either. The other
        // display's reading is its own.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")],
            recorder: recorder)
        defer { host.shutdown() }
        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")])
        host.setPresentationSuspended(true, forDisplay: 9)
        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301", paused: true)])
        host.setPresentationSuspended(false, forDisplay: 9)
        XCTAssertEqual(host.isPlaying(displayID: 9), false)

        await reconcile(WallpaperHosts(web: nil, native: host), host)

        XCTAssertEqual(host.isPlaying(displayID: 9), true)
        XCTAssertEqual(host.isPlaying(displayID: 7), true, "and the display that never stopped plays on")
    }

    /// Reads the bridge again through `hosts` and waits for that pass to finish.
    private func reconcile(_ hosts: WallpaperHosts, _ host: NativeVideoWallpaperHost) async {
        let finished = expectation(description: "the host read the bridge again")
        host.onSurfacesChanged = { finished.fulfill() }
        hosts.reconcile()
        await fulfillment(of: [finished], timeout: 10)
    }

    func testAWallpaperThatLeavesTheNativeBackendStopsPlayingImmediately() async {
        // The bridge stops returning it — because the user switched wallpaper,
        // turned the backend off, or the routing changed. Leaving the player
        // running would mean two backends decoding for one display.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper()])
        XCTAssertEqual(host.activeDisplayIDs, [7])

        await host.apply([])

        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(
            recorder.stopped, 1,
            "the player must stop in the same pass, not when something else happens to run")
        host.shutdown()
    }

    func testSwitchingWallpaperOnOneDisplayReplacesTheSurface() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper(id: "300")])
        let firstGeneration = host.surfaceGenerationForTest

        await host.apply([wallpaper(id: "301", admissionKey: 2)])

        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertNotEqual(
            host.surfaceGenerationForTest, firstGeneration,
            "a new wallpaper is a new surface, so its counters are not merged with the old one's")
        host.shutdown()
    }

    func testAPosterFromAReplacedSurfaceIsNotPublished() async {
        // The request outlives the wallpaper it was made against. Publishing
        // its frame would put the previous clip's picture under the new one.
        let recorder = Recorder()
        let center = NotificationCenter()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder, frameCenter: center)
        host.start()
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        surfacesMade[7]?.poster = Self.makeImage()
        surfacesMade[7]?.posterDelay = .milliseconds(60)

        var published: [CALayer] = []
        let observer = center.addObserver(
            forName: DesktopPosterNotification.ready, object: nil,
            queue: .main
        ) { note in
            if let layer = note.object as? CALayer { published.append(layer) }
        }
        defer { center.removeObserver(observer) }

        center.post(
            name: DesktopPosterNotification.request, object: surfacesMade[7]?.posterLayer)
        // Replace the wallpaper while the request is still in flight.
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(
            published.isEmpty,
            "a frame produced by the surface that has been replaced must not be delivered")
        host.shutdown()
    }

    func testAPosterFromTheCurrentSurfaceReachesTheDesktopCoordinator() async throws {
        let recorder = Recorder()
        let center = NotificationCenter()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder, frameCenter: center)
        host.start()
        await host.apply([wallpaper()])
        surfacesMade[7]?.poster = Self.makeImage()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-poster-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = DesktopPictureTarget(display: "7", space: "test-space")
        let workspace = PosterWorkspace(target: target, original: root.appendingPathComponent("original.png"))
        let layer = try XCTUnwrap(surfacesMade[7]?.posterLayer)
        let updated = expectation(description: "native pixels published through the real desktop coordinator")
        let sync = try DesktopWallpaperSync(folder: root.appendingPathComponent("posters"), workspace: workspace,
            surfaces: { [DesktopPosterSurface(layer: layer, display: "7")] }, frameCenter: center,
            scope: { _ in .desktop(id: "test-space", context: "native-video-space-visit") })
        workspace.didWrite = { updated.fulfill() }
        sync.start()
        sync.refresh()
        await fulfillment(of: [updated], timeout: 2)

        let picture = try XCTUnwrap(workspace.picture)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(picture.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        let frame = try XCTUnwrap(DesktopPosterFrame.rgba(image))
        // ImageIO's ICC round trip can move an 8-bit channel by a few levels.
        for (actual, expected) in zip(frame.pixels.prefix(3), [255, 0, 0]) {
            XCTAssertEqual(Double(actual), Double(expected), accuracy: 4)
        }
        workspace.didWrite = nil
        try sync.stopAndRestore()
        host.shutdown()
    }

    func testScreenGeometryUpdatesWithoutRecreatingThePlayingSurface() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper()])
        let surface = try XCTUnwrap(surfacesMade[7])
        let movedAndResized = NSRect(x: -400, y: 80, width: 400, height: 300)
        screenFrames[0].frame = movedAndResized
        await host.apply([wallpaper()])
        XCTAssertTrue(surfacesMade[7] === surface)
        XCTAssertEqual(surface.frame, movedAndResized)
        XCTAssertTrue(surface.isPlaying)
        XCTAssertEqual(recorder.stopped, 0)
        host.shutdown()
    }

    func testPosterUsesTheSameFillCropOrStretchAsTheVideoSurface() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
            bytesPerRow: 32, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: index * 2, y: 0, width: 2, height: 4))
        }
        let source = try XCTUnwrap(context.makeImage())
        let fill = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(source, pixelSize: CGSize(width: 4, height: 4), stretching: false))
        let stretch = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(source, pixelSize: CGSize(width: 4, height: 4), stretching: true))
        let filled = try XCTUnwrap(DesktopPosterFrame.rgba(fill))
        let stretched = try XCTUnwrap(DesktopPosterFrame.rgba(stretch))
        XCTAssertEqual(Array(filled.pixels.prefix(3)), [0, 255, 0])
        for (actual, expected) in zip(stretched.pixels.prefix(3), [255, 0, 0]) {
            XCTAssertEqual(Double(actual), Double(expected), accuracy: 4)
        }
        XCTAssertEqual(fill.width, 4)
        XCTAssertEqual(fill.height, 4)
    }

    private final class PosterWorkspace: DesktopPictureWorkspace {
        let target: DesktopPictureTarget
        var picture: DesktopPicture?
        var didWrite: (() -> Void)?
        init(target: DesktopPictureTarget, original: URL) {
            self.target = target
            picture = DesktopPicture(url: original, scaling: 0, allowClipping: false, fill: [0, 0, 0, 1])
        }
        func targets() -> [DesktopPictureTarget] { [target] }
        func currentPicture(target: DesktopPictureTarget) -> DesktopPicture? { picture }
        func setPicture(_ picture: DesktopPicture, target: DesktopPictureTarget) {
            self.picture = picture
            didWrite?()
        }
        func referencedPictureURLs(targets: [DesktopPictureTarget]) -> Set<URL> { [] }
    }
}
