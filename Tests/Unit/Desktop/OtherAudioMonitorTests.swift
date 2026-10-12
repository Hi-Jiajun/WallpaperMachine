import XCTest
@testable import WallpaperMachine

private final class FakeProcessAudioSource: ProcessAudioSource {
    var samples: [ProcessAudioSample] = []
    var onChange: (@MainActor () -> Void)?
    private(set) var running = false

    func sample() -> [ProcessAudioSample] { samples }
    func start() { running = true }
    func stop() { running = false; onChange = nil }
    @MainActor func emit() { onChange?() }
}

@MainActor
final class OtherAudioMonitorTests: XCTestCase {
    private let ownPID: pid_t = 10
    private let childPID: pid_t = 42
    private let otherPID: pid_t = 99

    private func makeMonitor(
        _ source: FakeProcessAudioSource,
        preferences: PlaybackPreferences? = nil,
        activate: Duration = .milliseconds(40),
        deactivate: Duration = .milliseconds(120)
    ) -> OtherAudioMonitor {
        OtherAudioMonitor(
            preferences: preferences,
            source: source,
            ownPID: ownPID,
            responsiblePID: { pid in pid == self.childPID ? self.ownPID : pid },
            activateDelay: activate,
            deactivateDelay: deactivate)
    }

    func testOwnProcessAndResponsibleChildDoNotCountAsOtherAudio() async throws {
        let source = FakeProcessAudioSource()
        source.samples = [
            ProcessAudioSample(pid: ownPID, isRunningOutput: true),
            ProcessAudioSample(pid: childPID, isRunningOutput: true),
        ]
        let monitor = makeMonitor(source, activate: .zero, deactivate: .zero)
        monitor.start()
        defer { monitor.stop() }
        source.emit()
        XCTAssertFalse(monitor.isActive, "Our process and the processes we are responsible for are not other audio")

        source.samples.append(ProcessAudioSample(pid: otherPID, isRunningOutput: true))
        source.emit()
        XCTAssertTrue(monitor.isActive)
    }

    func testBecomingActiveWaitsAndATrackGapDoesNotClear() async throws {
        let source = FakeProcessAudioSource()
        let monitor = makeMonitor(source)
        monitor.start()
        defer { monitor.stop() }

        source.samples = [ProcessAudioSample(pid: otherPID, isRunningOutput: true)]
        source.emit()
        XCTAssertFalse(monitor.isActive, "Other audio must settle before it is reported")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(monitor.isActive)

        source.samples = []
        source.emit()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(monitor.isActive, "A gap shorter than the inactive settle must not clear other audio")
        source.samples = [ProcessAudioSample(pid: otherPID, isRunningOutput: true)]
        source.emit()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(monitor.isActive, "Audio that returns during the gap must stay active")
    }

    func testOtherAudioClearsOnlyAfterTheInactiveSettle() async throws {
        let source = FakeProcessAudioSource()
        let monitor = makeMonitor(source)
        monitor.start()
        defer { monitor.stop() }
        source.samples = [ProcessAudioSample(pid: otherPID, isRunningOutput: true)]
        source.emit()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(monitor.isActive)

        source.samples = []
        source.emit()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(monitor.isActive)
    }

    func testKeepRunningDoesNotListen() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.otherAudioAction, .keepRunning)
        let source = FakeProcessAudioSource()
        source.samples = [ProcessAudioSample(pid: otherPID, isRunningOutput: true)]
        let monitor = makeMonitor(source, preferences: preferences, activate: .zero)
        monitor.start()
        defer { monitor.stop() }
        source.emit()
        XCTAssertFalse(source.running)
        XCTAssertFalse(monitor.isActive)
    }

    func testChangingPolicyReinstallsAudioChangeCallback() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let preferences = PlaybackPreferences(defaults: defaults)
        let source = FakeProcessAudioSource()
        let monitor = makeMonitor(source, preferences: preferences, activate: .zero, deactivate: .zero)
        monitor.start()
        defer { monitor.stop() }
        for action in [OtherAudioAction.mute, .pause] {
            preferences.otherAudioAction = action
            source.samples = [ProcessAudioSample(pid: otherPID, isRunningOutput: true)]
            source.emit()
            XCTAssertTrue(monitor.isActive)
            preferences.otherAudioAction = .keepRunning
            XCTAssertFalse(monitor.isActive)
            source.samples = []
            preferences.otherAudioAction = action
            source.samples = [ProcessAudioSample(pid: otherPID, isRunningOutput: true)]
            source.emit()
            XCTAssertTrue(monitor.isActive, "A restarted source must continue reporting changes")
            source.samples = []
            source.emit()
            XCTAssertFalse(monitor.isActive)
        }
    }
}
