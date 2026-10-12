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
    private var battery: FakeBatteryLevel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        preferences = PlaybackPreferences(defaults: defaults)
        focus = FocusFilterState(defaults: defaults)
        systemCenter = NotificationCenter()
        lowPower = false
        thermal = .nominal
        battery = FakeBatteryLevel()
    }

    override func tearDown() {
        defaults = nil
        preferences = nil
        focus = nil
        systemCenter = nil
        battery = nil
        super.tearDown()
    }

    private func makeMonitor() -> SystemConditionMonitor {
        SystemConditionMonitor(
            preferences: preferences, focus: focus, systemCenter: systemCenter,
            isLowPowerModeEnabled: { self.lowPower }, thermalState: { self.thermal }, battery: battery)
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

    func testLowBatteryActsOnlyOnceTheUserChoseAnAction() {
        battery.reading = BatteryReading(percent: 15, isDischarging: true)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "Keep running is the default")
        XCTAssertFalse(battery.isObserving, "Nothing is observed until an action is chosen")
        XCTAssertEqual(battery.reads, 0, "Nothing is read until an action is chosen")

        preferences.lowBatteryAction = .pause
        XCTAssertEqual(monitor.actions, [.pause], "Already low when the rule is chosen engages at once")
        XCTAssertTrue(battery.isObserving)

        battery.change(to: BatteryReading(percent: 22, isDischarging: true))
        XCTAssertEqual(monitor.actions, [.pause], "22% is still inside the margin above the 20% level")
        battery.change(to: BatteryReading(percent: 26, isDischarging: true))
        XCTAssertTrue(monitor.actions.isEmpty, "Five points above the level resumes")
        battery.change(to: BatteryReading(percent: 21, isDischarging: true))
        XCTAssertTrue(monitor.actions.isEmpty, "Falling back to 21% is not low again")
        battery.change(to: BatteryReading(percent: 20, isDischarging: true))
        XCTAssertEqual(monitor.actions, [.pause])

        preferences.lowBatteryAction = .keepRunning
        XCTAssertTrue(monitor.actions.isEmpty, "Choosing Keep running releases")
        XCTAssertFalse(battery.isObserving, "and stops observing")
    }

    func testPluggingInReleasesAtAnyChargeAndThresholdChangesApplyAtOnce() {
        preferences.lowBatteryAction = .stop
        battery.reading = BatteryReading(percent: 28, isDischarging: true)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "28% is above the default 20% level")

        preferences.lowBatteryThreshold = 30
        XCTAssertEqual(monitor.actions, [.stop], "Raising the level above the charge engages")
        preferences.lowBatteryThreshold = 20
        XCTAssertTrue(monitor.actions.isEmpty, "Lowering it more than the margin below the charge releases")

        battery.change(to: BatteryReading(percent: 8, isDischarging: true))
        XCTAssertEqual(monitor.actions, [.stop])
        battery.change(to: BatteryReading(percent: 8, isDischarging: false))
        XCTAssertTrue(monitor.actions.isEmpty, "Plugging in releases however low the charge is")
    }

    func testAMacWithoutAnInternalBatteryNeverEngages() {
        preferences.lowBatteryAction = .pause
        battery.reading = nil
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty)
        battery.change(to: nil)
        XCTAssertTrue(monitor.actions.isEmpty)
    }

    func testLowBatteryJoinsTheOtherConditionsAndStopReleasesIt() {
        preferences.lowPowerModeAction = .pause
        preferences.lowBatteryAction = .stop
        lowPower = true
        battery.reading = BatteryReading(percent: 9, isDischarging: true)
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertEqual(monitor.actions, [.pause, .stop], "Each condition contributes its own action")

        monitor.stop()
        XCTAssertTrue(monitor.actions.isEmpty, "A stopped monitor must never leave wallpapers stopped")
        XCTAssertFalse(battery.isObserving, "and observes nothing")
        battery.reading = BatteryReading(percent: 5, isDischarging: true)
        preferences.lowBatteryThreshold = 30
        XCTAssertTrue(monitor.actions.isEmpty, "Nothing is evaluated after stop")

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.actions, [.pause, .stop], "A restart evaluates the current charge afresh")
    }

    func testRefreshingReadsAChangeNobodyAnnouncedOnlyWhileTheRuleIsOn() {
        battery.reading = BatteryReading(percent: 50, isDischarging: false)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        battery.reading = BatteryReading(percent: 12, isDischarging: true)
        monitor.refreshBattery()
        XCTAssertEqual(battery.reads, 0, "With Keep running there is nothing to read")
        XCTAssertTrue(monitor.actions.isEmpty)

        preferences.lowBatteryAction = .pause
        XCTAssertEqual(monitor.actions, [.pause])
        battery.reading = BatteryReading(percent: 80, isDischarging: false)
        monitor.refreshBattery()
        XCTAssertTrue(monitor.actions.isEmpty, "A wake that finds the Mac plugged in releases without a notification")
    }
}

/// A battery the test drives: `reading` is what the monitor sees, `change(to:)` also announces it.
@MainActor
private final class FakeBatteryLevel: BatteryLevelSource {
    var stored: BatteryReading?
    private(set) var reads = 0
    private(set) var isObserving = false
    private var onChange: (@MainActor () -> Void)?

    var reading: BatteryReading? {
        get {
            reads += 1
            return stored
        }
        set { stored = newValue }
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        isObserving = true
        self.onChange = onChange
    }

    func stop() {
        isObserving = false
        onChange = nil
    }

    func change(to reading: BatteryReading?) {
        stored = reading
        onChange?()
    }
}
