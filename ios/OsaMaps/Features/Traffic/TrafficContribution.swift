import Foundation
import CoreLocation

/// Contribution anonyme au trafic (si `Prefs.contributeTraffic`) — mêmes règles que `contribute.ts`.
///
/// Pendant un trajet, toutes les ~5 s : un segment « position précédente → actuelle », la vitesse
/// et le cap, avec un JETON ALÉATOIRE PROPRE AU TRAJET (pas d'identifiant d'appareil).
/// Vie privée du domicile : un segment ne part que s'il est à plus de 300 m du point de départ
/// ET à plus de 300 m de la position actuelle (on attend de s'être éloigné). À la fin du trajet,
/// ce qui reste en attente (les 300 derniers mètres) est jeté. En conduite, rien non plus à moins
/// de 300 m de la destination.
///
/// Un trajet commence en conduite, ou en exploration au-delà de 5 km/h. En exploration, rien ne
/// part tant qu'on n'a pas dépassé 30 km/h une fois (sinon piétons et vélos passeraient pour des
/// bouchons). Il se termine à l'arrivée ou après 5 min à l'arrêt hors conduite.
/// Position simulée : aucune contribution, sauf argument de lancement `-trafficsim YES` (build DEBUG uniquement).
@MainActor
final class TrafficContribution {
    static let shared = TrafficContribution()

    static let pingEvery: TimeInterval = 5
    /// Le serveur accepte 1 ping / 3 s par connexion.
    static let sendGap: TimeInterval = 3.3
    static let privacyM = 300.0
    static let movingMs = 5 / 3.6
    static let vehicleMs = 30 / 3.6
    static let stopEnd: TimeInterval = 5 * 60

    private static let allowSim: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "trafficsim")
        #else
        return false
        #endif
    }()

    private struct Ping {
        var t: String
        var a: CLLocationCoordinate2D
        var b: CLLocationCoordinate2D
        var s: Double
        var h: Double
        var dt: Double
        var at: Date
    }

    private struct Trip {
        var token: String
        var start: CLLocationCoordinate2D
        var last: CLLocationCoordinate2D
        var traveled = 0.0
        var vehicle: Bool
        var lastMove: Date
        var pingFrom: CLLocationCoordinate2D
        var pingAt: Date
        var heading: Double?
        var queue: [Ping] = []
    }

    private var trip: Trip?
    private var lastSend = Date.distantPast
    private var token: BusToken?

    func start() {
        guard token == nil else { return }
        token = Bus.shared.on { [weak self] e in
            guard let self else { return }
            switch e {
            case .geoTick(let p): self.tick(p)
            case .driveStop(let arrived): if arrived { self.end() }
            case .driveArrived: self.end()
            default: break
            }
        }
        observePref()
    }

    private func observePref() {
        withObservationTracking {
            _ = Prefs.shared.contributeTraffic
        } onChange: {
            Task { @MainActor [weak self] in
                if !Prefs.shared.contributeTraffic { self?.end() }
                self?.observePref()
            }
        }
    }

    /// 20 caractères [0-9a-z] tirés au hasard (générateur système, cryptographique).
    static func newToken() -> String {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var rng = SystemRandomNumberGenerator()
        return String((0..<20).map { _ in chars[Int(rng.next(upperBound: UInt(chars.count)))] })
    }

    private func end() {
        trip = nil // les segments en attente (300 derniers mètres) sont jetés
        TrafficStore.shared.tripActive = false
        TrafficStore.shared.sent = 0
    }

    private func tick(_ pos: Position) {
        if !Prefs.shared.contributeTraffic || (pos.simulated && !Self.allowSim) {
            if trip != nil { end() }
            return
        }
        if let acc = pos.accuracy, acc > 60 { return } // GPS trop imprécis
        let now = Date()
        let mode = Core.shared.mode
        let speed = pos.speed ?? 0

        guard var t = trip else {
            if mode != .drive && speed < Self.movingMs { return }
            trip = Trip(token: Self.newToken(), start: pos.coordinate, last: pos.coordinate,
                        vehicle: mode == .drive || speed >= Self.vehicleMs, lastMove: now,
                        pingFrom: pos.coordinate, pingAt: now, heading: pos.heading)
            TrafficStore.shared.tripActive = true
            TrafficStore.shared.sent = 0
            return
        }

        t.traveled += Geo.distance(t.last, pos.coordinate)
        t.last = pos.coordinate
        if speed >= Self.movingMs { t.lastMove = now }
        if speed >= Self.vehicleMs || mode == .drive { t.vehicle = true }
        if let h = pos.heading { t.heading = h }
        if mode != .drive && now.timeIntervalSince(t.lastMove) > Self.stopEnd { end(); return }

        if now.timeIntervalSince(t.pingAt) >= Self.pingEvery {
            let dt = now.timeIntervalSince(t.pingAt)
            if dt <= 30 {
                let d = Geo.distance(t.pingFrom, pos.coordinate)
                let h = d > 5 ? Geo.bearing(t.pingFrom, pos.coordinate) : t.heading
                let s = pos.speed.flatMap { $0 >= 0 ? $0 : nil } ?? d / dt
                if let h, s <= 70 {
                    t.queue.append(Ping(t: t.token, a: t.pingFrom, b: pos.coordinate, s: (s * 10).rounded() / 10,
                                        h: min(359.9, (h * 10).rounded() / 10), dt: (dt * 10).rounded() / 10, at: now))
                    if t.queue.count > 240 { t.queue.removeFirst() }
                }
            }
            t.pingFrom = pos.coordinate
            t.pingAt = now
        }
        trip = t
        flush(pos.coordinate, now)
    }

    private func flush(_ pos: CLLocationCoordinate2D, _ now: Date) {
        guard var t = trip else { return }
        let core = Core.shared
        t.queue.removeAll { p in
            // trop près du départ : jeté définitivement
            if Geo.distance(p.a, t.start) < Self.privacyM || Geo.distance(p.b, t.start) < Self.privacyM { return true }
            // trop près de la destination annoncée : jeté
            if core.mode == .drive, let dest = core.destination, Geo.distance(p.b, dest.coordinate) < Self.privacyM { return true }
            // trop vieux pour servir (fenêtre serveur de 15 min)
            return now.timeIntervalSince(p.at) > 14 * 60
        }
        trip = t
        guard t.vehicle, t.traveled >= Self.privacyM, now.timeIntervalSince(lastSend) >= Self.sendGap,
              let next = t.queue.first else { return }
        // on attend d'être à plus de 300 m du segment (au cas où le trajet s'arrêterait ici)
        if Geo.distance(next.a, pos) < Self.privacyM || Geo.distance(next.b, pos) < Self.privacyM { return }
        trip?.queue.removeFirst()
        let round6 = { (x: Double) in (x * 1e6).rounded() / 1e6 }
        Socket.shared.emit("traffic:ping", [
            "t": next.t,
            "a": [round6(next.a.longitude), round6(next.a.latitude)],
            "b": [round6(next.b.longitude), round6(next.b.latitude)],
            "s": next.s, "h": next.h, "dt": next.dt,
            "ago": Int(now.timeIntervalSince(next.at).rounded()),
        ])
        lastSend = now
        TrafficStore.shared.sent += 1
        #if DEBUG
        NSLog("OsaMaps traffic: segment envoyé (%d)", TrafficStore.shared.sent)
        #endif
    }
}
