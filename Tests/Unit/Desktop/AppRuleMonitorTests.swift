import XCTest
@testable import WallpaperMachine

@MainActor
final class AppRuleMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var preferences: PlaybackPreferences!
    private var workspaceCenter: NotificationCenter!
    private var running: Set<String> = []
    private var frontmost: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        preferences = PlaybackPreferences(defaults: defaults)
        workspaceCenter = NotificationCenter()
        running = []
        frontmost = nil
    }

    override func tearDown() {
        defaults = nil
        preferences = nil
        workspaceCenter = nil
        super.tearDown()
    }

    private func makeMonitor() -> AppRuleMonitor {
        AppRuleMonitor(
            preferences: preferences,
            workspaceCenter: workspaceCenter,
            runningBundleIDs: { self.running },
            frontmostBundleID: { self.frontmost })
    }

    func testRunningRuleFiresOnlyWhileThatAppIsRunning() {
        let rule = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        try? preferences.updateRule(id: rule.id, action: .pause)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "A running rule does not fire before the app launches")

        running = ["com.example.Player"]
        workspaceCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertEqual(monitor.actions, [.pause])

        running = []
        workspaceCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty)
    }

    func testFrontmostRuleIgnoresABackgroundInstance() {
        let rule = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        try? preferences.updateRule(id: rule.id, condition: .frontmost)
        try? preferences.updateRule(id: rule.id, action: .mute)
        running = ["com.example.Player"]
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "Running in the background is not in front")

        frontmost = "com.example.Player"
        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(monitor.actions, [.mute])

        frontmost = "com.example.Other"
        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty)
    }

    func testRemovingTheLastRuleClearsActionsEvenIfTheAppStaysRunning() {
        let rule = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        running = ["com.example.Player"]
        let changes = ChangeCount()
        let monitor = makeMonitor()
        monitor.onChange = { changes.value += 1 }
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.actions, [.pause])
        XCTAssertEqual(changes.value, 1)

        preferences.removeRule(id: rule.id)
        XCTAssertTrue(monitor.actions.isEmpty)
        running = ["com.example.Player", "com.example.Other"]
        workspaceCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty, "With no rules left, launches do not revive an action")
    }
}

private final class ChangeCount: @unchecked Sendable {
    var value = 0
}
