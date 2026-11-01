import Combine
import CoreLocation
import Foundation

@MainActor
final class LocationRelay: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var backgroundEnabled = false
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var latest: CLLocation?
    @Published private(set) var status = "GPS sharing is off"
    @Published private(set) var isTracking = false

    var onLocation: ((CLLocation) -> Void)?
    var onLog: ((String) -> Void)?
    private let manager = CLLocationManager()
    private var updates: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?
    private var connected = false
    private var foreground = true

    override init() {
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value, manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        reconcile()
    }

    func setBackgroundEnabled(_ value: Bool) {
        backgroundEnabled = value
        reconcile()
    }

    func setConnected(_ value: Bool) {
        connected = value
        if !value { latest = nil }
        reconcile()
    }

    func setForeground(_ value: Bool) {
        foreground = value
        authorization = manager.authorizationStatus
        reconcile()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        reconcile()
    }

    private func reconcile() {
        let authorized = authorization == .authorizedWhenInUse || authorization == .authorizedAlways
        guard enabled, connected, authorized, foreground || backgroundEnabled else {
            stopUpdates()
            if !enabled { status = "GPS sharing is off" }
            else if !authorized {
                status = authorization == .notDetermined ? "Waiting for location permission" : "Allow location access in Settings"
            } else if !connected { status = "Ready to share when Glass connects" }
            else { status = "Paused while the app is in the background" }
            return
        }

        if backgroundEnabled, backgroundSession == nil, foreground {
            // A real, user-enabled location feature; no fabricated audio/background work.
            backgroundSession = CLBackgroundActivitySession()
        } else if !backgroundEnabled {
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
        guard updates == nil else { return }
        status = "Finding your location…"
        isTracking = true
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard !Task.isCancelled, let self else { return }
                    guard let location = update.location,
                          location.horizontalAccuracy >= 0,
                          abs(location.timestamp.timeIntervalSinceNow) < 15,
                          CLLocationCoordinate2DIsValid(location.coordinate) else { continue }
                    self.latest = location
                    self.status = "Sharing location · ±\(Int(location.horizontalAccuracy)) m"
                    self.onLocation?(location)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.status = error.localizedDescription
                self.onLog?("Location: \(error.localizedDescription)")
            }
            guard !Task.isCancelled, let self else { return }
            self.updates = nil
            self.isTracking = false
            self.backgroundSession?.invalidate()
            self.backgroundSession = nil
        }
    }

    private func stopUpdates() {
        updates?.cancel()
        updates = nil
        isTracking = false
        backgroundSession?.invalidate()
        backgroundSession = nil
    }
}
