import Foundation

/// Reports the rule actions that conditions of the whole Mac ask for: Low Power Mode, a hot Mac
/// and a low battery, each as the user chose under Playback, and whatever a Focus filter set.
/// They join the app rules' actions in `WallpaperPresentationPolicy`, so they pause, mute or
/// stop wallpapers the same way and never change the user's own Play/Pause. Only notifications
/// are observed; nothing is polled. The one source added for the battery is IOKit's power-source
/// notification, and it is observed only while a low-battery action is chosen.
@MainActor
final class SystemConditionMonitor {
    var onChange: (@MainActor () -> Void)?
    private(set) var actions: Set<AppRuleAction> = []

    private let preferences: PlaybackPreferences
    private let focus: FocusFilterState
    private let systemCenter: NotificationCenter
    private let preferencesCenter: NotificationCenter
    private let isLowPowerModeEnabled: @MainActor () -> Bool
    private let thermalState: @MainActor () -> ProcessInfo.ThermalState
    private let battery: any BatteryLevelSource
    private var lowBatteryGate = LowBatteryGate()
    private var isObservingBattery = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        preferences: PlaybackPreferences,
        focus: FocusFilterState,
        systemCenter: NotificationCenter = .default,
        preferencesCenter: NotificationCenter = .default,
        isLowPowerModeEnabled: (@MainActor () -> Bool)? = nil,
        thermalState: (@MainActor () -> ProcessInfo.ThermalState)? = nil,
        battery: (any BatteryLevelSource)? = nil
    ) {
        self.preferences = preferences
        self.focus = focus
        self.systemCenter = systemCenter
        self.preferencesCenter = preferencesCenter
        self.isLowPowerModeEnabled = isLowPowerModeEnabled ?? { ProcessInfo.processInfo.isLowPowerModeEnabled }
        self.thermalState = thermalState ?? { ProcessInfo.processInfo.thermalState }
        self.battery = battery ?? SystemBatteryLevel()
    }

    /// Serious and critical are the states in which macOS itself starts throttling.
    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    func start() {
        guard observers.isEmpty else {
            recompute()
            return
        }
        // ProcessInfo posts both on whichever thread noticed the change.
        let sources: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (systemCenter, .NSProcessInfoPowerStateDidChange, nil),
            (systemCenter, ProcessInfo.thermalStateDidChangeNotification, nil),
            (preferencesCenter, PlaybackPreferences.didChangeNotification, preferences),
            (preferencesCenter, FocusFilterState.didChangeNotification, focus),
        ]
        for (center, name, object) in sources {
            observers.append((center, center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            }))
        }
        recompute()
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        stopObservingBattery()
        publish([])
    }

    /// Reads the battery again, for a moment the Mac may have changed it without a notification,
    /// such as a plug or unplug during sleep. Does nothing while no low-battery action is chosen.
    func refreshBattery() {
        guard isObservingBattery else { return }
        recompute()
    }

    private func recompute() {
        guard !observers.isEmpty else { return }
        var next = Set<AppRuleAction>()
        if isLowPowerModeEnabled(), let action = preferences.lowPowerModeAction.ruleAction {
            next.insert(action)
        }
        if Self.isHot(thermalState()), let action = preferences.thermalAction.ruleAction {
            next.insert(action)
        }
        if let action = focus.action { next.insert(action) }
        if let action = lowBatteryAction()?.ruleAction { next.insert(action) }
        publish(next)
    }

    /// The low-battery action while the rule is engaged, nil otherwise. Chosen means observed:
    /// the power-source notification is registered for as long as an action other than keep
    /// running is saved, and the gate starts over whenever observation does.
    private func lowBatteryAction() -> SystemConditionAction? {
        let action = preferences.lowBatteryAction
        guard action != .keepRunning else {
            stopObservingBattery()
            return nil
        }
        startObservingBattery()
        let threshold = preferences.lowBatteryThreshold
        let reading = battery.reading
        let wasEngaged = lowBatteryGate.isEngaged
        let engaged = lowBatteryGate.update(reading, threshold: threshold)
        if engaged != wasEngaged {
            let charge = reading.map { "\($0.percent)%" } ?? "unknown"
            AppLog.info(engaged
                ? "battery at \(charge): low-battery rule engaged (threshold \(threshold)%, \(action.rawValue))"
                : "battery at \(charge): low-battery rule released (threshold \(threshold)%)")
        }
        return engaged ? action : nil
    }

    private func startObservingBattery() {
        guard !isObservingBattery else { return }
        isObservingBattery = true
        battery.start { [weak self] in self?.recompute() }
    }

    private func stopObservingBattery() {
        lowBatteryGate.reset()
        guard isObservingBattery else { return }
        isObservingBattery = false
        battery.stop()
    }

    private func publish(_ next: Set<AppRuleAction>) {
        guard next != actions else { return }
        actions = next
        AppLog.info("system conditions ask wallpapers to \(next.isEmpty ? "run" : next.map(\.rawValue).sorted().joined(separator: ", "))")
        onChange?()
    }
}
