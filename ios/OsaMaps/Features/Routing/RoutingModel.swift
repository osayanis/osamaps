import Foundation
import CoreLocation
import Observation

/// État et logique du module (port de `state.ts` + `controller.ts` de la version web).
///
/// Contrat :
///  écoute  `.placeGo` → aperçu ; `.routeRecompute(from:)` → recalcul en conduite ; `.driveStop` → nettoyage ;
///          `.routeAddStop` → ajoute une étape (insérée là où elle rallonge le moins).
///  émet    `.driveStart` (« C'est parti ») ; `.driveRerouted` ; `.toast`.
///  Core    destination, routes (speedLimits remplies en tâche de fond, même id), activeRoute,
///          mode preview/drive/browse, follow. Arrivée à une étape : `Maneuver.typeName == "waypoint"`.
@MainActor
@Observable
final class RoutingModel {
    static let shared = RoutingModel()

    enum Status: Equatable { case idle, loading, ready, error }
    enum Section: Equatable { case depart, stops }

    var status: Status = .idle
    var error: String?
    var retryable = false
    /// Étapes intermédiaires, dans l'ordre de passage.
    var stops: [Place] = []
    var depart: RoutingDepart?
    /// Informations propres au module, par id d'itinéraire.
    var meta: [String: RoutingMeta] = [:]
    /// Recalcul en cours pendant la conduite.
    var rerouting = false
    /// Sous-panneau ouvert dans l'aperçu.
    var section: Section?
    /// En attente d'un toucher sur la carte pour poser une étape.
    var pickOnMap = false
    /// Proposer des alternatives (réglage du module).
    var alternates: Bool { didSet { Store.save("routing.alternates", alternates) } }

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var rerouteTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var prefsTask: Task<Void, Never>?
    @ObservationIgnored private var speedJobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastReroute = Date.distantPast
    @ObservationIgnored private var pendingFrom: CLLocationCoordinate2D?
    @ObservationIgnored private var tokens: [BusToken] = []
    @ObservationIgnored private var started = false

    private var core: Core { Core.shared }

    private init() {
        alternates = Store.load("routing.alternates", default: true)
    }

    // MARK: - Branchements

    func start() {
        guard !started else { return }
        started = true
        tokens.append(Bus.shared.on { [weak self] event in
            guard let self else { return }
            switch event {
            case .placeGo(let place):
                guard place.lat.isFinite, place.lng.isFinite else { return }
                self.startPreview(place)
            case .routeRecompute(let from):
                self.reroute(from: from)
            case .driveStop:
                self.stopDrive()
            case .routeAddStop(let place):
                self.addStop(place)
            default:
                break
            }
        })

        // options d'évitement changées pendant l'aperçu → nouveau calcul (petit délai : plusieurs touchers)
        RoutingObserve.watch({ let p = Prefs.shared; return [p.avoidTolls, p.avoidHighways, p.avoidFerries] }) { [weak self] _ in
            guard let self, self.core.mode == .preview else { return }
            self.prefsTask?.cancel()
            self.prefsTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.computePreview()
            }
        }
        RoutingObserve.watch({ [weak self] in self?.alternates ?? true }) { [weak self] _ in
            guard let self, self.core.mode == .preview else { return }
            self.computePreview()
        }
        // la position arrive après le choix de destination (GPS lent) : on relance l'aperçu
        RoutingObserve.watch({ Core.shared.position != nil }) { [weak self] has in
            guard let self, has, self.core.mode == .preview, self.status == .error, self.retryable else { return }
            self.computePreview()
        }
    }

    private func options(alternates alt: Int? = nil, heading: Double? = nil, depart: RoutingDepart? = nil) -> RoutingOptions {
        let p = Prefs.shared
        return RoutingOptions(avoidTolls: p.avoidTolls, avoidHighways: p.avoidHighways, avoidFerries: p.avoidFerries,
                              alternates: alt ?? (alternates ? 2 : 0), heading: heading, depart: depart)
    }

    private func storeMeta(_ list: [RoutingComputed]) {
        var m = meta
        for c in list { m[c.route.id] = c.meta }
        // on ne garde que les itinéraires encore affichés + les nouveaux
        let keep = Set(core.routes.map(\.id) + list.map(\.route.id))
        for id in m.keys where !keep.contains(id) { m[id] = nil }
        meta = m
    }

    // MARK: - Limites de vitesse (tâche de fond, ne bloque jamais l'aperçu)

    func ensureSpeedLimits(_ route: Route?) {
        guard let route, route.speedLimits == nil, speedJobs[route.id] == nil else { return }
        let id = route.id, coords = route.coords
        speedJobs[id] = Task { @MainActor [weak self] in
            defer { self?.speedJobs[id] = nil }
            guard let limits = try? await RoutingEngine.speedLimits(coords), !Task.isCancelled else { return }
            let core = Core.shared
            // on remplace l'itinéraire en GARDANT le même id
            guard let i = core.routes.firstIndex(where: { $0.id == id }) else { return }
            core.routes[i].speedLimits = limits
        }
    }

    private func abortSpeeds() {
        speedJobs.values.forEach { $0.cancel() }
        speedJobs.removeAll()
    }

    // MARK: - Aperçu

    func startPreview(_ dest: Place) {
        if core.mode == .drive { emit(.driveStop(arrived: false)) }
        abortAll()
        stops = []; depart = nil; section = nil; pickOnMap = false; meta = [:]
        core.destination = dest
        core.routes = []
        core.activeRoute = 0
        core.mode = .preview
        core.follow = false
        core.openPanel(nil)
        computePreview()
    }

    func computePreview() {
        guard let destination = core.destination else { return }
        previewTask?.cancel()
        abortSpeeds()
        guard let position = core.position else {
            status = .error; error = "Votre position est encore inconnue."; retryable = true
            return
        }
        status = .loading; error = nil
        let points = [RoutingWaypoint(coordinate: position.coordinate)]
            + stops.map { RoutingWaypoint(coordinate: $0.coordinate, name: $0.name) }
            + [RoutingWaypoint(coordinate: destination.coordinate, name: destination.name)]
        let opts = options(depart: depart)
        previewTask = Task { @MainActor [weak self] in
            do {
                let list = try await RoutingEngine.compute(points, options: opts)
                guard let self, !Task.isCancelled, self.core.mode == .preview else { return }
                self.storeMeta(list)
                self.core.routes = list.map(\.route)
                self.core.activeRoute = 0
                self.status = .ready
                self.ensureSpeedLimits(list.first?.route)
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                let err = error as? RoutingError ?? RoutingError(message: "Le calcul a échoué.", retryable: true)
                self.core.routes = []
                self.status = .error; self.error = err.message; self.retryable = err.retryable
            }
        }
    }

    func selectRoute(_ i: Int) {
        guard core.mode == .preview, core.routes.indices.contains(i), i != core.activeRoute else { return }
        core.activeRoute = i
        emit(.haptic("light"))
        ensureSpeedLimits(core.routes[i])
    }

    func cancelPreview() {
        abortAll()
        status = .idle; stops = []; depart = nil; section = nil; pickOnMap = false; meta = [:]
        core.mode = .browse
        core.routes = []
        core.activeRoute = 0
        core.destination = nil
    }

    func startDrive() {
        guard let route = core.route else { return }
        section = nil; pickOnMap = false
        // en conduite on ne garde que l'itinéraire choisi
        core.routes = [route]
        core.activeRoute = 0
        core.mode = .drive
        core.follow = true
        core.openPanel(nil)
        ensureSpeedLimits(route)
        emit(.haptic("medium"))
        emit(.driveStart(routeId: route.id))
    }

    func setDepart(_ d: RoutingDepart?) {
        depart = d
        if core.mode == .preview { computePreview() }
    }

    // MARK: - Étapes

    private func afterStopsChange() {
        switch core.mode {
        case .preview: computePreview()
        case .drive: if let p = core.position { reroute(from: p.coordinate, force: true) }
        case .browse: break
        }
    }

    func addStop(_ place: Place, at index: Int? = nil) {
        guard let destination = core.destination, core.mode != .browse else { return }
        if stops.count >= 8 { emit(.toast(Toast(text: "8 étapes au maximum.", tone: .warn))); return }
        var s = stops
        let origin = core.position?.coordinate ?? place.coordinate
        let at = index ?? RoutingEngine.bestInsertIndex(origin: origin, stops: s.map(\.coordinate),
                                                         destination: destination.coordinate, point: place.coordinate)
        var p = place
        if p.kind == nil { p.kind = "stop" }
        s.insert(p, at: min(max(0, at), s.count))
        stops = s
        pickOnMap = false
        afterStopsChange()
    }

    func removeStop(_ i: Int) {
        guard stops.indices.contains(i) else { return }
        stops.remove(at: i)
        afterStopsChange()
    }

    func moveStop(_ i: Int, by dir: Int) {
        let j = i + dir
        guard stops.indices.contains(i), stops.indices.contains(j) else { return }
        stops.swapAt(i, j)
        afterStopsChange()
    }

    /// Lieu d'étape à partir d'un résultat de recherche ou d'un toucher sur la carte.
    static func stopPlace(name: String, coordinate c: CLLocationCoordinate2D, detail: String? = nil) -> Place {
        Place(id: String(format: "stop-%.5f,%.5f-", c.longitude, c.latitude) + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36),
              name: name, detail: detail, coordinate: c, kind: "stop")
    }

    // MARK: - Recalcul en conduite

    /// Étapes pas encore atteintes sur l'itinéraire actif (d'après la progression du guidage).
    private func remainingStops() -> [Place] {
        guard let route = core.route, let idx = meta[route.id]?.stopShapeIndex, let progress = core.progress else { return stops }
        return stops.enumerated().filter { k, _ in k >= idx.count || idx[k] > progress.shapeIndex }.map(\.element)
    }

    func reroute(from: CLLocationCoordinate2D, force: Bool = false, attempt: Int = 0) {
        guard core.mode == .drive, let destination = core.destination else { return }
        if attempt == 0 {
            if rerouting && !force { pendingFrom = from; return }
            // anti-rebond : le guidage peut redemander pendant qu'on rejoint le nouveau tracé
            if !force && Date().timeIntervalSince(lastReroute) < 4 { return }
            retryTask?.cancel()
        }
        rerouteTask?.cancel()
        abortSpeeds()
        pendingFrom = nil
        let remaining = remainingStops()
        stops = remaining
        rerouting = true
        let pos = core.position
        let heading = (pos?.speed ?? 0) > 2 ? pos?.heading : nil
        let points = [RoutingWaypoint(coordinate: from)]
            + remaining.map { RoutingWaypoint(coordinate: $0.coordinate, name: $0.name) }
            + [RoutingWaypoint(coordinate: destination.coordinate, name: destination.name)]
        let opts = options(alternates: 0, heading: heading)
        rerouteTask = Task { @MainActor [weak self] in
            do {
                let list = try await RoutingEngine.compute(points, options: opts)
                guard let self, !Task.isCancelled, self.core.mode == .drive, let route = list.first?.route else { return }
                self.storeMeta(list)
                self.core.routes = [route]
                self.core.activeRoute = 0
                self.lastReroute = Date()
                self.rerouting = false
                if attempt > 0 { emit(.toast(Toast(text: "Itinéraire recalculé.", icon: "checkmark", tone: .good))) }
                emit(.driveRerouted(routeId: route.id))
                self.ensureSpeedLimits(route)
                // une demande arrivée pendant le calcul et encore loin du nouveau tracé : on la rejoue
                if let again = self.pendingFrom, Geo.distance(again, from) > 150 { self.reroute(from: again, force: true) }
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError), self.core.mode == .drive else { return }
                let err = error as? RoutingError ?? RoutingError(message: "Le calcul a échoué.", retryable: true)
                if !err.retryable {
                    self.rerouting = false
                    emit(.toast(Toast(text: "Recalcul impossible : \(err.message)", icon: "exclamationmark.triangle", tone: .warn)))
                    return
                }
                if attempt == 0 {
                    emit(.toast(Toast(text: "Pas de réseau pour recalculer, nouvel essai en cours…", icon: "wifi.slash", tone: .warn)))
                }
                let delay = min(30.0, 3.0 * pow(2.0, Double(attempt)))
                self.retryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, !Task.isCancelled else { return }
                    // on repart de la position la plus récente
                    let p = self.pendingFrom ?? self.core.position?.coordinate ?? from
                    self.reroute(from: p, force: true, attempt: attempt + 1)
                }
            }
        }
    }

    private func abortAll() {
        previewTask?.cancel()
        rerouteTask?.cancel()
        retryTask?.cancel()
        prefsTask?.cancel()
        abortSpeeds()
        pendingFrom = nil
        rerouting = false
    }

    func stopDrive() {
        abortAll()
        status = .idle; stops = []; depart = nil; section = nil; pickOnMap = false; meta = [:]
        core.mode = .browse
        core.routes = []
        core.activeRoute = 0
        core.destination = nil
    }
}

/// Petit utilitaire Observation : rappelle `onChange` quand la valeur lue change (sans Combine).
@MainActor
enum RoutingObserve {
    static func watch<T: Equatable>(_ read: @escaping @MainActor () -> T, _ onChange: @escaping @MainActor (T) -> Void) {
        var last = read()
        func loop() {
            withObservationTracking { _ = read() } onChange: {
                Task { @MainActor in
                    let v = read()
                    if v != last { last = v; onChange(v) }
                    loop()
                }
            }
        }
        loop()
    }
}
