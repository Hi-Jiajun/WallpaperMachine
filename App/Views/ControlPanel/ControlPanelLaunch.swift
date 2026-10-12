import Foundation

/// Decides whether the control panel opens when the app starts.
///
/// Started as a login item, the app keeps to the menu bar: wallpapers play without the panel,
/// and the status item or reopening the app brings it back. The panel still opens when the
/// user has something to finish or fix: the welcome guide they have not completed, or a
/// renderer that failed to start.
enum ControlPanelLaunch {
    /// `launchEvent` is the Apple event the app is launching under; read it synchronously in
    /// `applicationDidFinishLaunching`, since it is only current while that event is handled.
    static func opensPanel(launchEvent: NSAppleEventDescriptor?, welcomeSeen: Bool, startupFailed: Bool) -> Bool {
        !isLoginItemLaunch(launchEvent) || !welcomeSeen || startupFailed
    }

    /// `SMAppService` cannot pass launch arguments, so the only sign of a login launch is the
    /// property the system attaches to the open-application event.
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
