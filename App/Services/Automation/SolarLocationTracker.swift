import CoreLocation
import Foundation
import AppKit

/// Keeps the position the automatic sun source plans with up to date.
///
/// The app is not sandboxed, so location access only needs
/// `NSLocationUsageDescription` in Info.plist. Updates run while the source is
/// `automatic` and stop when it is anything else; the coordinate filter keeps a
/// desk-bound Mac from waking the radio for nothing.
final class SolarLocationTracker: NSObject, CLLocationManagerDelegate {
    static let shared = SolarLocationTracker()

    private let manager = CLLocationManager()
    private var running = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 5_000
    }

    /// Starts or stops updates so they match the chosen source.
    func sync(with source: WallpaperSolarSource) {
        AppLog.info("solar location: sync source=\(source.rawValue) status=\(authorizationName)")
        if source == .automatic {
            // Only continue an access that already exists: asking during launch, before the
            // app is active, is answered with a denial instead of a prompt.
            startIfAuthorized()
        } else {
            stop()
        }
    }

    func start() {
        AppLog.info("solar location: start requested, status=\(authorizationName)")
        startIfAuthorized()
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
    }

    /// Asks for access when it has not been decided, and starts updates once it is granted.
    func requestAuthorization() {
        AppLog.info("solar location: authorization requested, status=\(authorizationName)")
        NSApp.activate(ignoringOtherApps: true)
        switch manager.authorizationStatus {
        case .notDetermined:
            running = true
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            start()
        default:
            break
        }
    }

    /// Whether the user refused, so the app must send them to System Settings instead of asking.
    var isDenied: Bool {
        guard servicesEnabled else { return true }
        switch manager.authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// Whether Location Services is on for the whole Mac. When it is off, no app is asked
    /// and every request is answered with a denial.
    var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }

    /// Opens the Location Services pane, where a refused app can be turned back on.
    func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func startIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            running = true
            manager.startUpdatingLocation()
        default:
            running = false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        AppLog.info("solar location: authorization changed to \(authorizationName)")
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            if running { manager.startUpdatingLocation() }
        case .denied, .restricted:
            running = false
            manager.stopUpdatingLocation()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate,
              coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return }
        let location = WallpaperSolarLocation(
            latitude: coordinate.latitude, longitude: coordinate.longitude)
        Task { @MainActor in
            try? WallpaperAutomationStore.shared.setLocation(location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // The last known position stays in place; the next update replaces it.
        AppLog.warn("solar location: update failed: \(error.localizedDescription)")
    }

    private var authorizationName: String {
        switch manager.authorizationStatus {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }
}
