import Foundation
import CoreLocation

/// Trafic sur l'itinéraire actif (port de `drive.ts`) : le serveur renvoie les portions ralenties
/// devant (contributions + mesures officielles), on en déduit le retard restant, on annonce les
/// bouchons devant (`driveAlert`) et on publie `trafficDelay`. Interroge en conduite (toutes les 45 s,
/// + quand le trafic de la zone change) et une fois en aperçu.
@MainActor
final class TrafficDriveController {
    static let shared = TrafficDriveController()

    static let refresh: TimeInterval = 45
    static let alertRange = 15_000.0
    static let near = 1000.0

    private var cumFor: (id: String, cum: [Double])?
    private var inflight = false
    private var lastQuery = Date.distantPast
    private var alerted = Set<String>()
    private var timer: Task<Void, Never>?
    private var lastTick = Date.distantPast
    private var observedKey = ""
    private var observedMode: Mode = .browse
    private var token: BusToken?

    func start() {
        guard token == nil else { return }
        token = Bus.shared.on { [weak self] e in
            guard let self else { return }
            switch e {
            case .driveStart:
                self.alerted.removeAll()
                self.query(); self.schedule()
            case .driveRerouted:
                self.query()
            case .driveStop:
                self.timer?.cancel(); self.timer = nil
                self.clear()
            case .geoTick:
                let now = Date()
                guard now.timeIntervalSince(self.lastTick) >= 2 else { return }
                self.lastTick = now
                if Core.shared.mode == .drive { self.update() }
            default: break
            }
        }
        observeCore()
    }

    /// Itinéraire changé (aperçu, alternative choisie, recalcul) ou changement de mode.
    private func observeCore() {
        withObservationTracking {
            let c = Core.shared
            _ = c.routes; _ = c.activeRoute; _ = c.mode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.coreChanged()
                self?.observeCore()
            }
        }
    }

    private func coreChanged() {
        let c = Core.shared
        let key = "\(c.route?.id ?? "-")|\(c.activeRoute)|\(c.routes.count)|\(c.mode.rawValue)"
        guard key != observedKey else { return }
        observedKey = key
        if c.mode != observedMode { observedMode = c.mode; schedule() }
        if c.mode == .browse || c.routes.isEmpty { clear(); return }
        query()
    }

    private func clear() {
        TrafficStore.shared.routeRuns = nil
        TrafficStore.shared.ahead = nil
    }

    private func schedule() {
        timer?.cancel(); timer = nil
        guard Core.shared.mode == .drive else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refresh))
                if Task.isCancelled { return }
                self?.query()
            }
        }
    }

    /// Le trafic de la zone a changé (diffusion socket) → on réinterroge, sans s'emballer.
    func trafficChanged() {
        if Core.shared.mode == .drive, Date().timeIntervalSince(lastQuery) > 15 { query() }
    }

    private func cum(_ r: Route) -> [Double] {
        if cumFor?.id != r.id { cumFor = (r.id, Geo.cumulative(r.coordinates)) }
        return cumFor!.cum
    }

    /// Sous-échantillonne le tracé à partir de l'index `from` (≤ 1900 points, pas ≥ 40 m).
    private func slice(_ route: Route, _ cum: [Double], from: Int) -> (coords: [[Double]], offset: Double) {
        let n = route.coords.count
        let start = max(0, min(from, n - 2))
        let remaining = cum[n - 1] - cum[start]
        let step = max(40, remaining / 1900)
        let round6 = { (x: Double) in (x * 1e6).rounded() / 1e6 }
        var out: [[Double]] = [[round6(route.coords[start].lng), round6(route.coords[start].lat)]]
        var lastD = cum[start]
        for i in (start + 1)..<n where cum[i] - lastD >= step || i == n - 1 {
            out.append([round6(route.coords[i].lng), round6(route.coords[i].lat)])
            lastD = cum[i]
        }
        return (out, cum[start])
    }

    private struct AlongBody: Encodable { var coords: [[Double]] }

    func query() {
        let c = Core.shared
        guard let route = c.route, route.coords.count >= 2, c.mode == .drive || c.mode == .preview, !inflight else { return }
        inflight = true
        lastQuery = Date()
        let cu = cum(route)
        let from = c.mode == .drive ? max(0, (c.progress?.shapeIndex ?? 0) - 1) : 0
        let (coords, offset) = slice(route, cu, from: from)
        Task { @MainActor [weak self] in
            defer { self?.inflight = false }
            do {
                let res = try await API.post("traffic/along", body: AlongBody(coords: coords), as: TrafficAlongResult.self)
                guard let self, Core.shared.route?.id == route.id else { return }
                let line = route.coordinates
                let runs = res.runs.map { r in
                    TrafficRouteRun(from: offset + r.from, to: offset + r.to, level: TrafficLevel(raw: r.level), delay: r.delay,
                                    speed: r.speed, sources: r.sources, start: Geo.along(line, cu, offset + r.from))
                }
                TrafficStore.shared.routeRuns = (route.id, runs, Date())
                #if DEBUG
                NSLog("OsaMaps traffic: %d portions ralenties sur l'itinéraire, retard total %.0f s", runs.count, res.totalDelay)
                #endif
                self.update()
            } catch {
                // serveur injoignable : on garde l'ancienne estimation si elle est récente
                if let r = TrafficStore.shared.routeRuns, Date().timeIntervalSince(r.at) > 180 { self?.clear() }
            }
        }
    }

    /// Recalcule « devant moi » à chaque position (sans réinterroger le serveur).
    func update() {
        let c = Core.shared
        let store = TrafficStore.shared
        guard let route = c.route, let info = store.routeRuns, info.routeId == route.id else { store.ahead = nil; return }
        let cu = cum(route)
        var here = 0.0
        if c.mode == .drive, let p = c.position {
            here = Geo.snap(p.coordinate, to: route.coordinates, cum: cu, from: max(0, (c.progress?.shapeIndex ?? 0) - 3))?.along ?? 0
        }
        var delay = 0.0
        var next: TrafficRouteRun?
        var nextDistance: Double?
        for r in info.runs where r.to > here {
            let part = r.from >= here ? 1 : (r.to - here) / max(1, r.to - r.from)
            delay += r.delay * part
            if next == nil, r.level == .jam || r.delay >= 90 {
                next = r
                nextDistance = max(0, r.from - here)
            }
        }
        let ahead = TrafficAhead(delay: delay.rounded(), next: next, nextDistance: nextDistance)
        if store.ahead != ahead { store.ahead = ahead }
        emit(.trafficDelay(routeId: route.id, delay: delay.rounded(), nextJamDistance: nextDistance))

        guard c.mode == .drive, let next, let dist = nextDistance, dist <= Self.alertRange else { return }
        let key = String(format: "traffic-%.3f-%.3f", next.start.longitude, next.start.latitude)
        let words = next.level == .jam ? "Bouchon" : "Ralentissement"
        let min = max(1, Int((next.delay / 60).rounded()))
        let say = { (id: String) in
            let text = dist < 150 ? "\(words) ici, ~\(min) min de retard" : "\(words) dans \(Geo.formatDistance(dist)), ~\(min) min de retard"
            emit(.driveAlert(DriveAlert(id: id, kind: "traffic", text: text, distance: dist.rounded(), tone: .warn)))
            #if DEBUG
            NSLog("OsaMaps traffic: alerte « %@ »", text)
            #endif
        }
        if !alerted.contains(key) {
            alerted.insert(key)
            say(key)
            if dist <= Self.near { alerted.insert("\(key)-near") }
        } else if dist <= Self.near, !alerted.contains("\(key)-near") {
            alerted.insert("\(key)-near")
            say("\(key)-near")
        }
    }
}
