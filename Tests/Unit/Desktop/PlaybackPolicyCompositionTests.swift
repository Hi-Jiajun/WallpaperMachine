import XCTest
@testable import WallpaperMachine

@MainActor
private final class CompositionProbe {
    var presentations: [GlobalPresentation] = []
    var audio: [Bool] = []
    var sessionLocked = false
    var sleepAction = DisplaySleepAction.pause
    var rules: Set<AppRuleAction> = []
    var otherAudio = false
    var otherAudioAction = OtherAudioAction.keepRunning
    var userMuted = false
}

@MainActor
final class PlaybackPolicyCompositionTests: XCTestCase {
    private let workspaceCenter = NotificationCenter()
    private let lockCenter = NotificationCenter()
    private let windowCenter = NotificationCenter()

    private func makePolicy(_ probe: CompositionProbe) -> WallpaperPresentationPolicy {
        WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { [WallpaperSurfaceVisibility(displayID: 1, isVisible: true)] },
            isSessionLocked: { probe.sessionLocked },
            displaySleepAction: { probe.sleepAction },
            appRuleActions: { probe.rules },
            otherAudioActive: { probe.otherAudio },
            otherAudioAction: { probe.otherAudioAction },
            userMuted: { probe.userMuted },
            occlusionSettleDelay: .zero,
            applyGlobal: { presentation, completion in
                probe.presentations.append(presentation)
                completion(.success(()))
            },
            applyAudio: { suppressed, completion in
                probe.audio.append(suppressed)
                completion(.success(()))
            },
            applyDisplay: { _, _, completion in completion(.success(())) })
    }

    func testDisplaySleepStopUnloadsAndPauseOnlySuspends() {
        let probe = CompositionProbe()
        probe.sleepAction = .stop
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(probe.presentations, [.unloaded])
        XCTAssertEqual(policy.globalPresentation, .unloaded)
        XCTAssertTrue(policy.isSuspended)

        probe.sleepAction = .pause
        policy.evaluate()
        XCTAssertEqual(policy.globalPresentation, .suspended)
        XCTAssertEqual(probe.presentations.last, .suspended)
    }

    func testLockPlusPauseRuleSuspendsAndStopBeatsPause() {
        let probe = CompositionProbe()
        probe.sessionLocked = true
        probe.rules = [.pause]
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.presentations, [.suspended])
        XCTAssertTrue(probe.audio.isEmpty, "Pause does not mute")

        probe.rules = [.pause, .stop]
        policy.evaluate()
        XCTAssertEqual(policy.globalPresentation, .unloaded)
        XCTAssertEqual(probe.presentations.last, .unloaded)
    }

    func testMuteComesFromARuleOrFromOtherAudio() {
        let probe = CompositionProbe()
        probe.rules = [.mute]
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.audio, [true])
        XCTAssertTrue(probe.presentations.isEmpty, "Mute leaves presentation running")
        XCTAssertFalse(policy.isSuspended)

        probe.rules = []
        policy.evaluate()
        XCTAssertEqual(probe.audio.last, false)

        probe.otherAudio = true
        probe.otherAudioAction = .mute
        policy.evaluate()
        XCTAssertEqual(probe.audio.last, true)
        XCTAssertTrue(probe.presentations.isEmpty)

        probe.otherAudioAction = .pause
        policy.evaluate()
        XCTAssertEqual(probe.audio.last, false)
        XCTAssertEqual(probe.presentations, [.suspended])
    }

    /// The user's own mute of every wallpaper is one more reason for the bridge's single
    /// audio-suppression flag, not a replacement for the others: it silences without touching
    /// presentation, and what else is muting keeps holding when it is lifted.
    func testUserMuteComposesWithRulesAndOtherAudio() {
        let probe = CompositionProbe()
        probe.userMuted = true
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.audio, [true], "A mute that was already on at launch reaches the bridge")
        XCTAssertTrue(policy.isAudioSuppressed)
        XCTAssertTrue(probe.presentations.isEmpty, "Muting never pauses or unloads anything")
        XCTAssertFalse(policy.isSuspended)

        // A mute rule and other-app audio hold as well, so lifting the user's mute changes nothing.
        probe.rules = [.mute]
        probe.otherAudio = true
        probe.otherAudioAction = .mute
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true], "Already suppressed: no second delivery")
        probe.userMuted = false
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true], "The rule and the other audio still mute")
        XCTAssertTrue(policy.isAudioSuppressed)

        probe.rules = []
        policy.evaluate()
        XCTAssertTrue(policy.isAudioSuppressed, "Other-app audio alone still mutes")
        probe.otherAudio = false
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true, false], "Nothing mutes any more")
        XCTAssertFalse(policy.isAudioSuppressed)

        // And back on from silence, with no rule involved.
        probe.userMuted = true
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true, false, true])
        XCTAssertTrue(probe.presentations.isEmpty)
    }

    func testTeardownRestoresSoundWhateverTheUserChose() {
        let probe = CompositionProbe()
        probe.userMuted = true
        let policy = makePolicy(probe)
        policy.start()
        XCTAssertEqual(probe.audio, [true])

        policy.stop()
        XCTAssertEqual(probe.audio.last, false, "Teardown must never leave a surface muted")
        XCTAssertFalse(policy.isAudioSuppressed)
    }

    func testKeepRunningIgnoresOtherAudio() {
        let probe = CompositionProbe()
        probe.otherAudio = true
        probe.otherAudioAction = .keepRunning
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertTrue(probe.presentations.isEmpty)
        XCTAssertTrue(probe.audio.isEmpty)
        XCTAssertEqual(policy.globalPresentation, .running)
        XCTAssertFalse(policy.isAudioSuppressed)
    }

    func testStopRestoresRunningAndUnmuted() {
        let probe = CompositionProbe()
        probe.rules = [.stop, .mute]
        let policy = makePolicy(probe)
        policy.start()
        XCTAssertEqual(probe.presentations, [.unloaded])
        XCTAssertEqual(probe.audio, [true])

        policy.stop()
        XCTAssertEqual(probe.presentations.last, .running)
        XCTAssertEqual(probe.audio.last, false)
        XCTAssertEqual(policy.globalPresentation, .running)
        XCTAssertFalse(policy.isAudioSuppressed)
        XCTAssertFalse(policy.isSuspended)
    }
}
