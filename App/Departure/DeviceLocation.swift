import CoreLocation

/// `LocationProviding` on the iPhone, for 「該出發了」 (docs/SETTINGS.md §7.11): Core Location with When In Use
/// permission only, asked the first time the user asks for a departure or a travel time, in the app in the foreground.
/// One fix per request (`requestLocation`), never continuous updates, never in the background (no Always permission,
/// no location background mode: scripts/validate_schema.py check 14). The location is handed to the caller and not
/// kept here.
@MainActor
final class DeviceLocation: NSObject, LocationProviding {
    static let shared = DeviceLocation()

    private let manager = CLLocationManager()
    private var permissionWaiters: [CheckedContinuation<Void, Never>] = []
    private var locationWaiters: [CheckedContinuation<GeoPoint, Error>] = []
    /// Counts fix requests, so a timeout only ends the request it was set for.
    private var fixRequest = 0

    private override init() {
        super.init()
        // Created on the main thread, so Core Location calls the delegate there.
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> GeoPoint {
        try await ensurePermission()
        if let known = manager.location,
           TravelRules.isRecent(ageSeconds: -known.timestamp.timeIntervalSinceNow,
                                accuracyMeters: known.horizontalAccuracy) {
            return GeoPoint(known.coordinate)
        }
        return try await withCheckedThrowingContinuation { continuation in
            waitForFix(continuation)
        }
    }

    /// Asks for When In Use permission when the user hasn't been asked yet, and waits for the answer.
    private func ensurePermission() async throws {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                permissionWaiters.append(continuation)
                if permissionWaiters.count == 1 { manager.requestWhenInUseAuthorization() }
            }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return
        default: throw TravelTimeError.noPermission  // denied, restricted, or location turned off
        }
    }

    private func waitForFix(_ continuation: CheckedContinuation<GeoPoint, Error>) {
        locationWaiters.append(continuation)
        guard locationWaiters.count == 1 else { return }  // one fix answers everyone waiting
        fixRequest += 1
        let request = fixRequest
        manager.requestLocation()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TravelRules.locationTimeoutSeconds * 1_000_000_000))
            guard let self, self.fixRequest == request, !self.locationWaiters.isEmpty else { return }
            self.finishFix(.failure(TravelTimeError.temporarilyUnavailable))
        }
    }

    private func finishFix(_ result: Result<GeoPoint, Error>) {
        let waiters = locationWaiters
        locationWaiters = []
        fixRequest += 1  // a late timeout or callback for this request does nothing
        waiters.forEach { $0.resume(with: result) }
    }

    private func permissionAnswered() {
        let waiters = permissionWaiters
        permissionWaiters = []
        waiters.forEach { $0.resume() }
    }
}

extension DeviceLocation: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Also called once when the manager is created, before the user has answered.
        guard manager.authorizationStatus != .notDetermined else { return }
        Task { @MainActor in self.permissionAnswered() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let point = GeoPoint(latest.coordinate)
        Task { @MainActor in
            guard !self.locationWaiters.isEmpty else { return }
            self.finishFix(.success(point))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let failure = TravelRules.locationError(coreLocationCode: (error as? CLError)?.code.rawValue)
        Task { @MainActor in
            guard !self.locationWaiters.isEmpty else { return }
            self.finishFix(.failure(failure))
        }
    }
}

extension GeoPoint {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
