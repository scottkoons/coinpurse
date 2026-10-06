import CoreLocation

/// Finds where you are right now, once, for a map pin. It asks for location
/// only when you tap Add Pin and stops as soon as it has a good fix.
final class LocationFinder: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum Failure: LocalizedError {
        case denied, unavailable

        var errorDescription: String? {
            switch self {
            case .denied: return "Turn on Location for Coin Purse in Settings to drop a pin."
            case .unavailable: return "Could not find your location. Try again in a moment."
            }
        }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Pin, Error>?
    private var best: CLLocation?
    private var deadline: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var isDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    /// Your current spot. Waits up to about six seconds for a precise fix,
    /// then settles for the best one it has.
    func currentPin() async throws -> Pin {
        #if DEBUG
        // UI tests pass a spot in ("lat,lng") instead of using GPS.
        if let fake = UserDefaults.standard.string(forKey: "uiTestPin") {
            let parts = fake.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                return Pin(lat: parts[0], lng: parts[1], acc: 8, at: Date().timeIntervalSince1970 * 1000)
            }
        }
        #endif
        if isDenied { throw Failure.denied }
        // A second tap while one is running replaces the first.
        continuation?.resume(throwing: CancellationError())
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            best = nil
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                begin()
            }
        }
    }

    private func begin() {
        manager.startUpdatingLocation()
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.finish() }
        }
    }

    private func finish() {
        manager.stopUpdatingLocation()
        deadline?.cancel()
        guard let cont = continuation else { return }
        continuation = nil
        if let fix = best {
            cont.resume(returning: Pin(
                lat: fix.coordinate.latitude,
                lng: fix.coordinate.longitude,
                acc: fix.horizontalAccuracy,
                at: Date().timeIntervalSince1970 * 1000
            ))
        } else {
            cont.resume(throwing: Failure.unavailable)
        }
    }

    // MARK: CLLocationManagerDelegate (called on the main thread, where the manager was made)

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        case .denied, .restricted:
            let cont = continuation
            continuation = nil
            cont?.resume(throwing: Failure.denied)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for fix in locations where fix.horizontalAccuracy >= 0 {
            if best == nil || fix.horizontalAccuracy < best!.horizontalAccuracy { best = fix }
        }
        // Good enough to find a car: stop early.
        if let best, best.horizontalAccuracy <= 15 { finish() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // "Unknown for now" means it is still trying.
        if (error as? CLError)?.code == .locationUnknown { return }
        finish()
    }
}
