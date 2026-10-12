import XCTest
@testable import WallpaperMachine

@MainActor
final class SystemConditionMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var preferences: PlaybackPreferences!
    private var focus: FocusFilterState!
    private var systemCenter: NotificationCenter!
    private var lowPower = false
    private var thermal = ProcessInfo.ThermalState.nominal

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        preferences = PlaybackPreferences(defaults: defaults)
        focus = FocusFilterState(defaults: defaults)
        systemCenter = NotificationCenter()
        lowPower = false
        thermal = .nominal
    }

    override func tearDown() {
        defaults = nil
        preferences = nil
        focus = nil
        systemCenter = nil
        super.tearDown()
    }

    private func makeMonitor() -> SystemConditionMonitor {
        SystemConditionMonitor(
            preferences: preferences, focus: focus, systemCenter: systemCenter,
            isLowPowerModeEnabled: { self.lowPower }, thermalState: { self.thermal })
    }

    func testLowPowerModeActsOnlyOnceTheUserChoseAnAction() {
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        lowPower = true
        systemCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty, "Keep running is the default")

        preferences.lowPowerModeAction = .pause
        XCTAssertEqual(monitor.actions, [.pause])

        lowPower = false
        systemCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty, "Leaving Low Power Mode resumes")
    }

    func testOnlySeriousAndCriticalHeatCount() {
        preferences.thermalAction = .stop
        let monitor = makeMonitor()
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.start()
        defer { monitor.stop() }
        for state in [ProcessInfo.ThermalState.nominal, .fair] {
            thermal = state
            systemCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            XCTAssertTrue(monitor.actions.isEmpty)
        }
        thermal = .serious
        systemCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(monitor.actions, [.stop])
        thermal = .critical
        systemCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(monitor.actions, [.stop])
        XCTAssertEqual(changes, 1, "Staying hot is not a change")
    }

    func testFocusFilterJoinsTheOtherConditions() {
        preferences.lowPowerModeAction = .pause
        lowPower = true
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        focus.set(.mute)
        XCTAssertEqual(monitor.actions, [.pause, .mute])
        focus.set(nil)
        XCTAssertEqual(monitor.actions, [.pause])
    }

    func testFocusFilterStateOutlivesTheApp() {
        focus.set(.stop)
        XCTAssertEqual(FocusFilterState(defaults: defaults).action, .stop)
        focus.set(nil)
        XCTAssertNil(FocusFilterState(defaults: defaults).action)
    }

    func testStoppingReleasesEveryAction() {
        preferences.thermalAction = .pause
        thermal = .critical
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertEqual(monitor.actions, [.pause])
        monitor.stop()
        XCTAssertTrue(monitor.actions.isEmpty, "A stopped monitor must never leave wallpapers paused")
        preferences.thermalAction = .stop
        XCTAssertTrue(monitor.actions.isEmpty, "Nothing is observed after stop")
    }
}
