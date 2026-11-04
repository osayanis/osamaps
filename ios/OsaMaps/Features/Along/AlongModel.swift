import Foundation
import MapKit
import Observation

/// Suit des propriétés @Observable (Core, AlongPrefs…) sans Combine : `change` est rappelé à chaque modification.
@MainActor
func alongObserve(_ read: @escaping @MainActor () -> Void, _ change: @escaping @MainActor () -> Void) {
    withObservationTracking { read() } onChange: {
        Task { @MainActor in
            change()
            alongObserve(read, change)
        }
    }
}

/// Le cerveau du module (port de `controller.ts`) : stations autour de la carte / le long du trajet,
/// météo du trajet, et surveillance de la conduite (alerte météo à l'approche, rappel de pause).
@MainActor
@Observable
final class AlongModel {
    static let shared = AlongModel()

    /// Stations visibles autour de la carte (exploration).
    var nearbyFuel: [AlongFuelStation] = []
    var nearbyEv: [AlongEvStation] = []
    /// Stations le long de l'itinéraire actif.
    var route: AlongRouteStations?
    var weather: AlongRouteWeather?
    enum WeatherStatus { case idle, loading, ready, error }
    var weatherStatus: WeatherStatus = .idle

    @ObservationIgnored private var tokens: [BusToken] = []
    @ObservationIgnored private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let core = Core.shared, prefs = AlongPrefs.shared
        var lastMode = core.mode
        alongObserve({ _ = core.routes; _ = core.activeRoute; _ = core.mode }) { [weak self] in
            guard let self else { return }
            self.sync()
            // retour en exploration : la carte a pu bouger pendant l'aperçu / la conduite
            if core.mode == .browse, lastMode != .browse, let m = core.map { self.loadNearby(m) }
            lastMode = core.mode
        }
        var lastEnergy = prefs.energy, lastShow = prefs.showStations
        alongObserve({ _ = prefs.energy; _ = prefs.showStations }) { [weak self] in
            guard let self else { return }
            if prefs.energy != lastEnergy || (prefs.showStations && !lastShow) {
                self.resetNearby()
                self.sync()
                if let m = core.map { self.loadNearby(m) }
            }
            lastEnergy = prefs.energy; lastShow = prefs.showStations
        }
        tokens.append(Bus.shared.on { [weak self] e in
            guard let self else { return }
            switch e {
            case .driveStart: Task { await self.startDriveWatch() }
            case .driveStop, .driveArrived: self.drive.active = false
            case .driveRerouted:
                self.drive.weatherNear = false
                if let r = core.route { Task { await self.loadWeather(r, force: true) } }
            case .geoTick(let p): self.onTick(speed: p.speed)
            default: break
            }
        })
        sync()
    }

    // MARK: - Position le long du trajet

    @ObservationIgnored private var cumCache: (id: String, cum: [Double])?
    @ObservationIgnored private var snapIndex = 0

    func cum(_ r: Route) -> [Double] {
        if cumCache?.id != r.id { cumCache = (r.id, Geo.cumulative(r.coordinates)); snapIndex = 0 }
        return cumCache!.cum
    }

    /// Mètres déjà parcourus sur l'itinéraire actif (0 hors conduite).
    func currentAlong() -> Double {
        let core = Core.shared
        guard let r = core.route, core.mode == .drive else { return 0 }
        let c = cum(r)
        guard !c.isEmpty else { return 0 }
        if let p = core.progress { return c[min(c.count - 1, max(0, p.shapeIndex))] }
        // pas encore de progression (guidance absente ou en retard) : on projette la position
        guard let pos = core.position else { return 0 }
        let line = r.coordinates
        if let s = Geo.snap(pos.coordinate, to: line, cum: c, from: max(0, snapIndex - 5)), s.distance <= 300 {
            snapIndex = s.index
            return s.along
        }
        guard let full = Geo.snap(pos.coordinate, to: line, cum: c) else { return 0 }
        snapIndex = full.index
        return full.along
    }

    // MARK: - Stations autour de la carte

    @ObservationIgnored private var lastBox: (Double, Double, Double, Double)?
    @ObservationIgnored private var lastKind = ""
    @ObservationIgnored private var nearbyTask: Task<Void, Never>?

    /// Après un déplacement de carte (le calque s'en charge) : débounce + cache de zone.
    func loadNearby(_ map: MKMapView) {
        nearbyTask?.cancel()
        let region = map.region
        nearbyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            let prefs = AlongPrefs.shared
            guard prefs.showStations, Core.shared.mode == .browse, AlongLayer.zoomedIn(region) else { return }
            let c = region.center, s = region.span
            let view = (c.longitude - s.longitudeDelta / 2, c.latitude - s.latitudeDelta / 2,
                        c.longitude + s.longitudeDelta / 2, c.latitude + s.latitudeDelta / 2)
            let kind = prefs.energy.isEV ? "ev" : "fuel"
            if let b = self.lastBox, kind == self.lastKind, b.0 <= view.0, b.1 <= view.1, b.2 >= view.2, b.3 >= view.3 { return }
            // un peu plus large que l'écran pour ne pas recharger au moindre glissement
            let hw = min(0.95, s.longitudeDelta / 2 * 1.5), hh = min(0.95, s.latitudeDelta / 2 * 1.5)
            let box = (c.longitude - hw, c.latitude - hh, c.longitude + hw, c.latitude + hh)
            do {
                if kind == "ev" {
                    let r = try await AlongAPI.ev(bbox: box)
                    guard !Task.isCancelled else { return }
                    self.nearbyEv = r.stations
                } else {
                    let r = try await AlongAPI.fuel(bbox: box)
                    guard !Task.isCancelled else { return }
                    self.nearbyFuel = r.stations
                }
                self.lastBox = box; self.lastKind = kind
            } catch {
                NSLog("OsaMaps along : stations autour indisponibles (%@)", error.localizedDescription)
            }
        }
    }

    func resetNearby() { lastBox = nil }

    // MARK: - Stations le long du trajet

    @ObservationIgnored private var routeTask: Task<Void, Never>?

    private func loadRouteStations(_ r: Route) {
        let energy = AlongPrefs.shared.energy
        if let cur = route, cur.routeId == r.id, cur.energy == energy, cur.status != .error { return }
        routeTask?.cancel()
        route = AlongRouteStations(routeId: r.id, energy: energy, status: .loading)
        let line = r.coordinates
        routeTask = Task { [weak self] in
            do {
                var res = AlongRouteStations(routeId: r.id, energy: energy, status: .ready)
                if energy.isEV { res.ev = try await AlongAPI.evOnRoute(line).stations } else { res.fuel = try await AlongAPI.fuelOnRoute(line).stations }
                guard let self, !Task.isCancelled else { return }
                self.route = res
                NSLog("OsaMaps along : %d stations sur le trajet", res.fuel.count + res.ev.count)
            } catch {
                guard let self, !Task.isCancelled else { return }
                NSLog("OsaMaps along : stations du trajet indisponibles (%@)", error.localizedDescription)
                self.route = AlongRouteStations(routeId: r.id, energy: energy, status: .error)
            }
        }
    }

    // MARK: - Météo du trajet

    @ObservationIgnored private var weatherTask: Task<AlongRouteWeather?, Never>?

    @discardableResult
    func loadWeather(_ r: Route, force: Bool = false) async -> AlongRouteWeather? {
        if !force, let w = weather, w.routeId == r.id, Date.now.timeIntervalSince(w.fetchedAt) < 30 * 60 { return w }
        weatherTask?.cancel()
        weatherStatus = .loading
        let t = Task { [weak self] () -> AlongRouteWeather? in
            do {
                let w = try await AlongWeather.fetch(route: r)
                guard let self, !Task.isCancelled else { return nil }
                self.weather = w
                self.weatherStatus = .ready
                return w
            } catch {
                guard let self, !Task.isCancelled else { return nil }
                NSLog("OsaMaps along : météo indisponible (%@)", error.localizedDescription)
                self.weatherStatus = .error
                return nil
            }
        }
        weatherTask = t
        return await t.value
    }

    @ObservationIgnored private var weatherDebounce: Task<Void, Never>?

    private func sync() {
        let core = Core.shared
        guard core.mode != .browse, let r = core.route else {
            if route != nil { route = nil }
            return
        }
        loadRouteStations(r)
        if core.mode == .preview {
            weatherDebounce?.cancel()
            weatherDebounce = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, Core.shared.route?.id == r.id else { return }
                await self.loadWeather(r)
            }
        }
    }

    // MARK: - Conduite : alertes météo et pauses

    /// Argument de lancement « -alongPause 1 » : rappel après 1 min de conduite au lieu de 2 h (tests).
    private var pauseAfter: TimeInterval {
        let m = UserDefaults.standard.double(forKey: "alongPause")
        return (m > 0 ? m : 120) * 60
    }
    /// Un arrêt de 10 min compte comme une pause.
    private let breakDuration: TimeInterval = 10 * 60

    private struct DriveWatch {
        var active = false
        /// Début de la conduite continue (remis à zéro après une vraie pause).
        var since = Date.now
        var stoppedSince: Date?
        var pauseAlerts = 0
        var restQueried = false
        var weatherNear = false
        var pausePending = false
    }
    @ObservationIgnored private var drive = DriveWatch()

    /// Le guidage affiche ET annonce les drive:alert (texte court, il ajoute la distance).
    private func alert(_ id: String, _ text: String, _ distance: Double, _ tone: DriveAlert.Tone, _ kind: String) {
        NSLog("OsaMaps along : alerte %@ « %@ » à %.0f m", kind, text, distance)
        emit(.driveAlert(DriveAlert(id: id, kind: kind, text: text, distance: max(0, distance.rounded()), tone: tone)))
    }

    private func startDriveWatch() async {
        drive = DriveWatch(active: true, since: .now)
        guard let r = Core.shared.route, AlongPrefs.shared.weatherAlerts else { return }
        let w = await loadWeather(r)
        if let hz = w?.hazard, drive.active {
            alert("along-weather-\(r.id)", hz.short, hz.point.along, hz.tone, "weather")
        }
    }

    /// Alerte de pause, avec l'aire la plus proche devant si on en connaît une.
    private func pauseAlert() async {
        drive.pauseAlerts += 1
        let n = drive.pauseAlerts
        drive.pausePending = true
        defer { drive.pausePending = false }
        let hours = (Date.now.timeIntervalSince(drive.since) / 3600 * 2).rounded() / 2
        var text = hours >= 1 ? "\(AlongFormat.decimal(hours)) h de route : pense à faire une pause" : "Un moment de route : pense à faire une pause"
        var distance = 0.0
        if let r = Core.shared.route {
            let pos = currentAlong()
            if let res = try? await AlongAPI.restAhead(r.coordinates, fromAlong: pos),
               let a = res.areas.first(where: { $0.along > pos + 1500 }) {
                distance = a.along - pos
                let label: String
                if let name = a.name {
                    label = a.kind == "rest_area" && !name.lowercased().hasPrefix("aire") ? "aire de \(name)" : name
                } else if a.kind == "services" {
                    label = a.city.map { "aire de services vers \($0)" } ?? "aire de services"
                } else { label = "aire de repos" }
                text = "Pause conseillée : \(label)"
            }
        }
        if drive.active { alert("along-pause-\(n)", text, distance, .info, "pause") }
    }

    private func onTick(speed: Double?) {
        guard drive.active else { return }
        let now = Date.now
        // arrêt prolongé = pause : on repart de zéro
        if let speed, speed < 1.5 {
            if let s = drive.stoppedSince {
                if now.timeIntervalSince(s) > breakDuration { drive.since = now; drive.pauseAlerts = 0; drive.restQueried = false }
            } else { drive.stoppedSince = now }
        } else { drive.stoppedSince = nil }

        let driving = now.timeIntervalSince(drive.since)
        let core = Core.shared, prefs = AlongPrefs.shared
        if prefs.pauseReminder {
            // un peu avant l'échéance, on fait préparer les aires au serveur (Overpass en arrière-plan)
            if !drive.restQueried, let r = core.route, driving > pauseAfter * 0.85 {
                drive.restQueried = true
                let line = r.coordinates, pos = currentAlong()
                Task { _ = try? await AlongAPI.restAhead(line, fromAlong: pos) }
            }
            let due = pauseAfter + Double(drive.pauseAlerts) * 30 * 60 // puis toutes les 30 min
            if driving >= due, drive.stoppedSince == nil, !drive.pausePending { Task { await pauseAlert() } }
        }
        // à l'approche (≤ 8 km) d'un passage à risque, on le rappelle une fois
        if let hz = weather?.hazard, let r = core.route, !drive.weatherNear, prefs.weatherAlerts,
           weather?.routeId == r.id, hz.point.at > 0 {
            let d = hz.point.along - currentAlong()
            if d > 0, d <= 8000 {
                drive.weatherNear = true
                alert("along-weather-near-\(r.id)", hz.short, d, hz.tone, "weather")
            }
        }
    }

    // MARK: - Actions de l'interface

    func go(_ ref: AlongStationRef) {
        Core.shared.openPanel(nil)
        emit(.placeGo(place(ref)))
    }

    func addStop(_ ref: AlongStationRef) {
        emit(.routeAddStop(place(ref)))
        emit(.toast(Toast(text: "Arrêt ajouté au trajet", icon: "plus.circle.fill", tone: .good)))
        Core.shared.openPanel(nil)
    }

    func place(_ ref: AlongStationRef) -> Place {
        switch ref {
        case .fuel(let s):
            Place(id: "along-fuel-\(s.id)", name: s.name, detail: [s.address, "\(s.cp) \(s.city)"].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", "),
                  coordinate: s.coordinate, kind: "fuel")
        case .ev(let s):
            Place(id: "along-ev-\(s.id)", name: s.name, detail: s.address.isEmpty ? nil : s.address, coordinate: s.coordinate, kind: "ev")
        }
    }

    /// Texte de la meilleure suggestion carburant devant (voix, toast).
    func bestFuelText() -> String? {
        let e = AlongPrefs.shared.energy
        guard let r = route, !e.isEV, r.status == .ready,
              let best = AlongFormat.rankOnRoute(r.fuel, e, fromAlong: currentAlong()).first else { return nil }
        return "Le plein le moins cher sur ton trajet : \(AlongFormat.price3(best.price)) € à \(Geo.formatDistance(best.ahead))"
    }
}
