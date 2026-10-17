import CoreLocation
import Foundation

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
        if source == .automatic {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard !running else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            running = true
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            running = true
            manager.startUpdatingLocation()
        default:
            running = false
        }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
    }

    /// Asks for access when it has not been decided, and starts updates once it is granted.
    func requestAuthorization() {
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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
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
    }
}
