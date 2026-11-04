import Foundation
import CoreLocation

/// Position : GPS réel, ou SIMULATEUR (indispensable pour tester sans voiture, et dans le Simulateur iOS).
/// Simulateur activé par les arguments de lancement `-sim 90` (km/h) et `-speedup 4` :
/// la position part de Moulins et, en conduite, avance le long de l'itinéraire actif.
@MainActor
final class Location: NSObject, CLLocationManagerDelegate {
    static let shared = Location()

    /// Moulins (Allier).
    static let defaultCenter = CLLocationCoordinate2D(latitude: 46.5646, longitude: 3.3332)

    let simulated: Bool
    private let simKmh: Double
    private let speedup: Double
    private let manager = CLLocationManager()
    private var simTimer: Timer?
    private var distOnRoute = 0.0
    private var simRouteId = ""
    private var simCum: [Double] = []
    private var lastTick = Date()

    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private override init() {
        let d = UserDefaults.standard
        simulated = d.object(forKey: "sim") != nil
        simKmh = d.double(forKey: "sim") > 0 ? d.double(forKey: "sim") : 50
        speedup = d.double(forKey: "speedup") > 0 ? d.double(forKey: "speedup") : 1
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    /// Demande l'autorisation (à appeler APRÈS l'écran qui l'explique) et démarre.
    func requestAndStart() {
        if simulated { start(); return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { start() }
    }

    /// Démarre si déjà autorisé (ou simulé).
    func start() {
        if simulated { startSim(); return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        default:
            if Core.shared.position == nil { push(Self.defaultCenter, heading: nil, speed: nil, accuracy: nil) }
        }
    }

    /// Guidage écran verrouillé : à activer pendant la conduite (mode arrière-plan « location »).
    func setBackgroundNavigation(_ on: Bool) {
        guard !simulated else { return }
        manager.allowsBackgroundLocationUpdates = on
        manager.showsBackgroundLocationIndicator = on
    }

    private func push(_ c: CLLocationCoordinate2D, heading: Double?, speed: Double?, accuracy: Double?) {
        let p = Position(coordinate: c, heading: heading, speed: speed, accuracy: accuracy, time: .now, simulated: simulated)
        Core.shared.position = p
        Bus.shared.emit(.geoTick(p))
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            self.authorization = m.authorizationStatus
            self.start()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        Task { @MainActor in
            self.push(l.coordinate,
                      heading: l.course >= 0 ? l.course : nil,
                      speed: l.speed >= 0 ? l.speed : nil,
                      accuracy: l.horizontalAccuracy >= 0 ? l.horizontalAccuracy : nil)
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    // MARK: - Simulateur

    private func startSim() {
        guard simTimer == nil else { return }
        push(Self.defaultCenter, heading: 0, speed: 0, accuracy: 5)
        lastTick = .now
        simTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.simStep() }
        }
    }

    private func simStep() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick) * speedup
        lastTick = now
        let core = Core.shared
        guard core.mode == .drive, let route = core.route else { distOnRoute = 0; return }
        let line = route.coordinates
        if route.id != simRouteId {
            simRouteId = route.id
            simCum = Geo.cumulative(line)
            // recalcul : repartir du point du nouveau tracé le plus proche de la position
            if let p = core.position, let s = Geo.snap(p.coordinate, to: line, cum: simCum) { distOnRoute = s.along } else { distOnRoute = 0 }
        }
        guard let total = simCum.last else { return }
        distOnRoute = min(total, distOnRoute + simKmh / 3.6 * dt)
        let p = Geo.along(line, simCum, distOnRoute)
        let ahead = Geo.along(line, simCum, min(total, distOnRoute + 15))
        push(p, heading: Geo.bearing(p, ahead), speed: distOnRoute >= total ? 0 : simKmh / 3.6, accuracy: 5)
    }
}
