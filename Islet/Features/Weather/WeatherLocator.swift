import CoreLocation
import Foundation

/// Whether Islet may use this Mac's location.
enum WeatherLocationAccess: Equatable, Sendable {
    /// Never asked.
    case undetermined
    case allowed
    /// Turned off for Islet, or Location Services is off altogether.
    case denied
    /// Blocked by a device profile; only an administrator can change it.
    case restricted
}

/// Finds where this Mac is, once each time it is asked. Only a test replaces it.
@MainActor
protocol WeatherLocating: AnyObject {
    var access: WeatherLocationAccess { get }
    /// Asks macOS whether Islet may use the Mac's location, and waits for the answer.
    /// Only ever called when the person turns on "Use this Mac's location", or clicks
    /// to allow it: the prompt should answer something they just did.
    func requestAccess() async -> WeatherLocationAccess
    /// One reading, no finer than macOS's approximate location.
    func locate() async throws -> (latitude: Double, longitude: Double)
}

/// Core Location, asked for one approximate reading at a time: a town's worth of
/// accuracy is all a forecast needs, and it is rounded further before it is kept.
///
/// Nothing here runs, and no location manager exists, until the person turns on "Use
/// this Mac's location". Islet's own look-ups light macOS's location arrow for a
/// moment, and are left out of Islet's own wherever macOS says whose they are (see
/// `PrivacyPrefs.isIgnoredForLocation`).
@MainActor
final class WeatherLocator: NSObject, WeatherLocating {
    /// How long a reading may take before the feature makes do without one: a backstop
    /// for a request that never answers, since one that fails says so.
    static let timeout: TimeInterval = 30

    private var manager: CLLocationManager?
    private var accessWaiters: [CheckedContinuation<WeatherLocationAccess, Never>] = []
    private var fixWaiters: [CheckedContinuation<(latitude: Double, longitude: Double), Error>] = []
    private var timeoutTask: Task<Void, Never>?

    private var locationManager: CLLocationManager {
        if let manager { return manager }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        self.manager = manager
        return manager
    }

    var access: WeatherLocationAccess {
        Self.access(locationManager.authorizationStatus)
    }

    func requestAccess() async -> WeatherLocationAccess {
        let current = access
        guard current == .undetermined else { return current }
        return await withCheckedContinuation { continuation in
            accessWaiters.append(continuation)
            if accessWaiters.count == 1 { locationManager.requestWhenInUseAuthorization() }
        }
    }

    func locate() async throws -> (latitude: Double, longitude: Double) {
        guard access == .allowed else { throw WeatherFailure.noLocation }
        return try await withCheckedThrowingContinuation { continuation in
            fixWaiters.append(continuation)
            guard fixWaiters.count == 1 else { return }
            locationManager.requestLocation()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeout))
                guard !Task.isCancelled else { return }
                self?.finishFix(.failure(WeatherFailure.noLocation))
            }
        }
    }

    private func finishFix(_ result: Result<(latitude: Double, longitude: Double), Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let waiters = fixWaiters
        fixWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private static func access(_ status: CLAuthorizationStatus) -> WeatherLocationAccess {
        switch status {
        case .notDetermined: .undetermined
        case .restricted: .restricted
        case .denied: .denied
        default: .allowed
        }
    }
}

extension WeatherLocator: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let access = Self.access(manager.authorizationStatus)
            guard access != .undetermined else { return }
            let waiters = accessWaiters
            accessWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: access) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return }
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        MainActor.assumeIsolated { finishFix(.success((latitude, longitude))) }
    }

    /// A one-off request ends in a reading or in this, once. `.locationUnknown` is how
    /// it says it gave up: unlike continuous updates, which report it and keep trying,
    /// a one-off request tries no more, so it ends the wait like any other error rather
    /// than leave it to the timeout.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finishFix(.failure(WeatherFailure.noLocation)) }
    }
}
