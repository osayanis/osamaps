import Foundation
import CoreLocation
import MapKit
import UIKit

/// Le moteur du guidage (port de `engine.ts`) : à chaque position, accroche au tracé dans une fenêtre devant,
/// calcule la progression (`Core.progress`), déclenche les annonces vocales, détecte la sortie de route,
/// l'arrivée, les excès de vitesse, et tient les alertes et la Live Activity à jour.
/// Aucun rendu ici : le HUD et la barre du bas lisent `GuidanceState` et `Core.progress`.
@MainActor
final class GuidanceEngine {
    static let shared = GuidanceEngine()

    private struct Ctx { var route: Route; var cum: [Double]; var total: Double }

    private let state = GuidanceState.shared
    private var core: Core { .shared }
    private var ctx: Ctx?
    private var lastSeg = 0
    private var lastPos: Position?
    private var speedMs = 0.0
    private var odometer = 0.0
    private var tripStart = (time: Date(), odo: 0.0)
    /// Annonces déjà faites : index de manœuvre → étape la plus proche annoncée.
    private var announced: [Int: Int] = [:]
    /// Manœuvres pour lesquelles « Continuez pendant… » a déjà été dit.
    private var continued: Set<Int> = []
    private var offCount = 0
    private var offSince = Date.distantPast
    private var lastRecompute = Date.distantPast
    private var recomputeTask: Task<Void, Never>?
    private var arriveTask: Task<Void, Never>?
    private var overviewTask: Task<Void, Never>?
    private var lastLimit: Int?
    private var spokenAlerts: Set<String> = []
    private var token: BusToken?
    private var started = false

    private init() {}

    // MARK: - branchement

    func start() {
        guard !started else { return }
        started = true
        token = Bus.shared.on { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
        observeCore()
        if core.mode == .drive { startDrive() }
    }

    private func handle(_ e: BusEvent) {
        switch e {
        case .driveStart: startDrive()
        case .driveStop(let arrived): stopDrive(arrived: arrived)
        case .driveAlert(let a): onAlert(a)
        case .driveRerouted: state.recalculating = false; recomputeTask?.cancel()
        case .geoTick(let p): onPosition(p)
        default: break
        }
    }

    /// Suit `mode` (conduite démarrée/arrêtée sans évènement) et `follow` (fin de la vue d'ensemble).
    private func observeCore() {
        withObservationTracking {
            _ = core.mode; _ = core.follow
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.core.mode == .drive, !self.state.active { self.startDrive() }
                else if self.core.mode != .drive, self.state.active, self.state.arrived == nil { self.resetDrive() }
                if self.core.follow, self.state.overview { self.overviewTask?.cancel(); self.state.overview = false }
                self.observeCore()
            }
        }
    }

    // MARK: - voix

    private func say(_ text: String, priority: Bool = false) {
        guard Prefs.shared.voice else { return }
        Voice.shared.speak(text, priority: priority)
    }

    /// Étapes (m) avant la manœuvre ; la dernière, « maintenant », dépend de la vitesse.
    private func stages(for speed: Double) -> [Double] {
        let kmh = speed * 3.6
        let now = max(25, min(120, speed * 3))
        if kmh > 75 { return [2000, 800, 250, now] }
        if kmh > 45 { return [800, 300, now] }
        return [400, 100, now]
    }

    // MARK: - itinéraire courant

    private func loadRoute(_ route: Route) {
        let cum = Geo.cumulative(route.coordinates)
        ctx = Ctx(route: route, cum: cum, total: cum.last ?? 0)
        lastSeg = 0
        announced = [:]
        continued = []
        offCount = 0
        lastLimit = nil
        recomputeTask?.cancel()
        state.routeId = route.id
        state.recalculating = false
        state.along = 0
        state.nextIndex = min(1, max(0, route.maneuvers.count - 1))
        state.distToNext = 0
    }

    /// Accrochage limité à une fenêtre devant (≈ 2 km + 30 s de route) : évite de sauter
    /// sur une portion parallèle plus loin dans l'itinéraire à cause du bruit GPS.
    private func snapWindow(_ p: CLLocationCoordinate2D, _ c: Ctx, from: Int) -> Geo.Snap? {
        let n = c.cum.count
        guard n >= 2 else { return nil }
        let start = min(from, n - 2)
        let limit = c.cum[start] + 2000 + speedMs * 30
        var end = start + 2
        while end < n && c.cum[end - 1] <= limit { end += 1 }
        return Geo.snap(p, to: c.route.coordinates, cum: c.cum, from: start, to: end - 1)
    }

    private func nextManeuver(_ route: Route, _ seg: Int) -> Int {
        let ms = route.maneuvers
        if ms.count > 1 { for i in 1..<ms.count where ms[i].shapeIndex > seg { return i } }
        return max(0, ms.count - 1)
    }

    private func limitAt(_ route: Route, _ seg: Int) -> Int? {
        guard let list = route.speedLimits, !list.isEmpty else { return nil }
        var kmh: Int?
        for l in list { if l.from <= seg { kmh = l.kmh } else { break } }
        return kmh
    }

    // MARK: - démarrage / arrêt

    func startDrive() {
        guard let route = core.route else { return }
        if state.active, state.routeId == route.id, state.arrived == nil { return }
        resetDrive()
        state.active = true
        loadRoute(route)
        tripStart = (Date(), odometer)
        UIApplication.shared.isIdleTimerDisabled = true
        let eta = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(route.duration))
        let hh = "\(eta.hour ?? 0) h \(String(format: "%02d", eta.minute ?? 0))"
        var lead = "C'est parti."
        if let first = route.maneuvers.first, !(first.street ?? "").isEmpty { lead = "C'est parti, \(GuidancePhrases.action(first))." }
        say("\(lead) Arrivée prévue à \(hh).", priority: true)
        GuidanceLive.shared.start(destination: core.destination?.name ?? "Destination", state: liveState())
    }

    private func resetDrive() {
        let wasArrived = state.arrived != nil
        if state.active || wasArrived { GuidanceLive.shared.end(final: wasArrived ? liveState() : nil) }
        ctx = nil
        lastSeg = 0
        announced = [:]
        continued = []
        offCount = 0
        spokenAlerts = []
        lastLimit = nil
        recomputeTask?.cancel(); arriveTask?.cancel(); overviewTask?.cancel()
        state.reset()
        UIApplication.shared.isIdleTimerDisabled = false
        #if DEBUG
        GuidanceDebug.offset = 0
        #endif
    }

    private func stopDrive(arrived: Bool) {
        let wasDriving = core.mode == .drive || state.active || state.arrived != nil
        resetDrive()
        guard wasDriving || arrived else { return }
        core.mode = .browse
        core.progress = nil
        core.routes = []
        core.destination = nil
        if core.panel != nil { core.openPanel(nil) }
        core.follow = true
    }

    // MARK: - à chaque position

    private func onPosition(_ raw: Position) {
        var pos = raw
        #if DEBUG
        // test de sortie de route (osamaps://guidance-test?off=1) : position décalée vers le nord
        if GuidanceDebug.offset > 0 { pos.coordinate.latitude += GuidanceDebug.offset / 111_000 }
        #endif
        // compteur kilométrique et vitesse lissée (même hors conduite)
        if let last = lastPos {
            let d = Geo.distance(last.coordinate, pos.coordinate)
            let dt = pos.time.timeIntervalSince(last.time)
            if d < 500 { odometer += d }
            let measured = pos.speed ?? (dt > 0.4 && d < 500 ? d / dt : nil)
            if let m = measured { speedMs = speedMs > 0 ? speedMs * 0.4 + m * 0.6 : m }
        } else if let s = pos.speed { speedMs = s }
        lastPos = pos

        guard core.mode == .drive, let route = core.route, route.coords.count >= 2 else { return }
        if !state.active { startDrive() }
        if ctx == nil || ctx!.route.id != route.id {
            loadRoute(route)
        } else if ctx!.route.coords.count == route.coords.count {
            // même itinéraire enrichi (limites de vitesse arrivées après coup) : on garde la progression
            ctx!.route = route
        } else {
            let cum = Geo.cumulative(route.coordinates)
            ctx = Ctx(route: route, cum: cum, total: cum.last ?? 0)
        }
        let c = ctx!
        let kmh = Int((speedMs * 3.6).rounded())

        updateAlerts()
        updateSpeed(route, kmh)
        if state.arrived != nil { pushLive(); return }

        // accrochage : d'abord près de la dernière position, puis tout le tracé si on s'en écarte
        guard var snap = snapWindow(pos.coordinate, c, from: max(0, lastSeg - 3)) else { return }
        let tolerance = max(40, min((pos.accuracy ?? 10) * 1.5, 120))
        if snap.distance > tolerance, lastSeg > 3, let full = Geo.snap(pos.coordinate, to: route.coordinates, cum: c.cum), full.distance < snap.distance {
            snap = full
        }

        // sortie de route
        if snap.distance > tolerance {
            if offCount == 0 { offSince = pos.time }
            offCount += 1
            if offCount >= 3, pos.time.timeIntervalSince(offSince) >= 2.5 { offRoute(pos.coordinate) }
            pushLive()
            return
        }
        offCount = 0
        if state.recalculating { state.recalculating = false }

        lastSeg = snap.index
        let along = snap.along
        let remainingDistance = max(0, c.total - along)
        let ms = route.maneuvers
        let next = nextManeuver(route, snap.index)
        let prev = max(0, next - 1)
        let last = c.cum.count - 1
        let sNext = ms.indices.contains(next) ? min(ms[next].shapeIndex, last) : last
        let sPrev = ms.indices.contains(prev) ? min(ms[prev].shapeIndex, last) : 0
        let distToNext = max(0, c.cum[sNext] - along)

        // temps restant : temps Valhalla des manœuvres restantes, au prorata dans la manœuvre en cours
        let segLen = c.cum[sNext] - c.cum[sPrev]
        let frac = segLen > 0 ? min(1, max(0, distToNext / segLen)) : 0
        var remainingTime = (ms.indices.contains(prev) ? ms[prev].time : 0) * frac
        if next < ms.count { for j in next..<ms.count { remainingTime += ms[j].time } }
        if ms.reduce(0, { $0 + $1.time }) == 0 { remainingTime = c.total > 0 ? route.duration * remainingDistance / c.total : 0 }

        core.progress = Progress(shapeIndex: snap.index, maneuverIndex: next, remainingDistance: remainingDistance, remainingTime: remainingTime)
        let st = stages(for: max(speedMs, 8))
        state.along = along
        state.nextIndex = next
        state.distToNext = distToNext
        state.nowThreshold = st.last ?? 30

        // arrivée : près de la destination, ou au bout du tracé
        let dest = core.destination?.coordinate ?? route.coords[last].coordinate
        let toDest = Geo.distance(pos.coordinate, dest)
        if (toDest < 30 && remainingDistance < 150) || remainingDistance < 15 { arrive(route); return }

        announce(route, next, distToNext, st)
        pushLive()
    }

    private func announce(_ route: Route, _ next: Int, _ dist: Double, _ stages: [Double]) {
        let ms = route.maneuvers
        guard ms.indices.contains(next) else { return }
        let m = ms[next]
        let kind = GuidancePhrases.kind(m)
        var reached = -1
        for (i, s) in stages.enumerated() where dist <= s { reached = i }
        if reached < 0 {
            // juste après une manœuvre, si la suivante est loin : « Continuez sur la N 7 pendant 12 kilomètres »
            if dist > 3000, !continued.contains(next) {
                continued.insert(next)
                let road = GuidancePhrases.mainStreet(next > 0 ? ms[next - 1] : nil)
                say("Continuez\(road.isEmpty ? "" : " sur \(GuidancePhrases.withArticle(road))") pendant \(GuidancePhrases.spokenDistance(dist)).")
            }
            return
        }
        if reached <= announced[next] ?? -1 { return }

        let isNow = reached == stages.count - 1
        // la sortie d'un rond-point n'est dite qu'au dernier moment (l'entrée l'a déjà annoncée)
        if kind == .roundaboutExit && !isNow { announced[next] = reached; return }
        // l'arrivée « maintenant » est dite par arrive()
        if kind.isArrive && isNow { announced[next] = reached; return }

        var text = isNow ? GuidancePhrases.capitalize(GuidancePhrases.action(m))
            : "Dans \(GuidancePhrases.spokenDistance(dist)), \(GuidancePhrases.action(m))"
        if isNow && kind == .waypoint {
            let name = GuidancePhrases.waypointName(m)
            text = "Étape atteinte\(name.isEmpty ? "" : " : \(name)"). On continue"
        }
        // « puis » : la manœuvre suivante arrive tout de suite après
        if next + 1 < ms.count, reached >= stages.count - 2, let c = ctx {
            let after = ms[next + 1]
            let last = c.cum.count - 1
            let gap = c.cum[min(after.shapeIndex, last)] - c.cum[min(m.shapeIndex, last)]
            let afterKind = GuidancePhrases.kind(after)
            if gap < 150, afterKind != .roundaboutExit, kind != .roundabout {
                text += ", puis \(afterKind.isArrive ? "vous serez à destination" : GuidancePhrases.action(after))"
            }
        }
        say("\(text).")

        // étapes « déjà couvertes » : on ne répète pas 100 m après avoir dit 120 m
        var covered = reached
        if reached + 1 < stages.count - 1 { for i in (reached + 1)..<(stages.count - 1) where stages[i] >= dist * 0.7 { covered = i } }
        announced[next] = covered
    }

    private func offRoute(_ from: CLLocationCoordinate2D) {
        let now = Date()
        guard now.timeIntervalSince(lastRecompute) >= 12 else { return }
        lastRecompute = now
        state.recalculating = true
        say("Recalcul de l'itinéraire.", priority: true)
        emit(.routeRecompute(from: from))
        recomputeTask?.cancel()
        // sans nouvel itinéraire au bout de 15 s, on réessaiera à la prochaine position hors tracé
        recomputeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.state.recalculating = false
        }
    }

    private func arrive(_ route: Route) {
        let kind = route.maneuvers.last.map(GuidancePhrases.kind) ?? .arrive
        let side: String? = kind == .arriveRight ? "right" : kind == .arriveLeft ? "left" : nil
        let name = core.destination?.name ?? "votre destination"
        state.arrived = GuidanceArrival(name: name, side: side, tripTime: Date().timeIntervalSince(tripStart.time), tripDistance: odometer - tripStart.odo)
        state.distToNext = 0
        state.alerts = []
        core.progress = Progress(shapeIndex: route.coords.count - 1, maneuverIndex: max(0, route.maneuvers.count - 1), remainingDistance: 0, remainingTime: 0)
        say("Vous voilà à destination\(side.map { ", elle est sur votre \($0 == "right" ? "droite" : "gauche")" } ?? "").", priority: true)
        emit(.driveArrived(destinationName: name))
        pushLive(force: true)
        arriveTask?.cancel()
        arriveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.state.arrived != nil else { return }
            emit(.driveStop(arrived: true))
        }
    }

    // MARK: - vitesse

    private func updateSpeed(_ route: Route, _ kmh: Int) {
        let limit = limitAt(route, lastSeg)
        let tol = Prefs.shared.speedTolerance
        var speeding = state.speeding
        if let limit {
            if !speeding && kmh > limit + tol {
                speeding = true
                Haptic.play("warning")
                if GuidancePrefs.shared.speedBeep { GuidanceSound.beep() }
            } else if speeding && kmh <= limit + tol - 2 { speeding = false }
        } else { speeding = false }

        if limit != lastLimit {
            if let limit, lastLimit != nil, GuidancePrefs.shared.speedVoice { say("Limitation à \(limit).") }
            lastLimit = limit
        }
        if state.speedKmh != kmh { state.speedKmh = kmh }
        if state.limitKmh != limit { state.limitKmh = limit }
        if state.speeding != speeding { state.speeding = speeding }
    }

    // MARK: - alertes

    private func onAlert(_ a: DriveAlert) {
        guard core.mode == .drive, !a.id.isEmpty else { return }
        let dist = max(0, a.distance)
        let text = GuidancePhrases.stripDistance(a.text)
        let item = GuidanceAlert(id: a.id, kind: a.kind.isEmpty ? "danger" : a.kind, text: text.isEmpty ? "Attention" : text, tone: a.tone,
                                 baseDistance: dist, baseOdo: odometer, remaining: dist, receivedAt: Date())
        var list = state.alerts.filter { $0.id != a.id }
        list.append(item)
        list.sort { $0.remaining < $1.remaining }
        state.alerts = list
        if !spokenAlerts.contains(a.id) {
            spokenAlerts.insert(a.id)
            let t = GuidancePhrases.lowerFirst(GuidancePhrases.replace(#"\.$"#, in: item.text, with: ""))
            say(dist >= 60 ? "Attention, \(t), dans \(GuidancePhrases.spokenDistance(dist))." : "Attention, \(t).")
        }
        pushLive(force: true)
    }

    private func updateAlerts() {
        guard !state.alerts.isEmpty else { return }
        let now = Date()
        // dépassée (30 m derrière), ou trop vieille (5 min ; 25 s pour une alerte sans distance)
        state.alerts = state.alerts
            .map { var a = $0; a.remaining = a.baseDistance - (odometer - a.baseOdo); return a }
            .filter { $0.remaining > -30 && now.timeIntervalSince($0.receivedAt) < ($0.baseDistance > 0 ? 300 : 25) }
    }

    // MARK: - vue d'ensemble, actions de la barre

    func showOverview() {
        guard let map = core.map, let route = core.route else { return }
        let from = max(0, min(core.progress?.shapeIndex ?? 0, route.coords.count - 1))
        var pts = Array(route.coordinates[from...])
        if let p = core.position { pts.append(p.coordinate) }
        guard !pts.isEmpty else { return }
        let cam = map.camera.copy() as! MKMapCamera
        cam.pitch = 0; cam.heading = 0
        map.setCamera(cam, animated: false)
        map.layoutMargins = .zero
        MapHub.fit(pts, extraTop: 130)
        state.overview = true
        overviewTask?.cancel()
        overviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.resumeFollow()
        }
    }

    func resumeFollow() {
        overviewTask?.cancel()
        state.overview = false
        core.follow = true
        emit(.mapRecenter)
    }

    func stopGuidance() { emit(.driveStop(arrived: false)) }
    func finishArrival() { emit(.driveStop(arrived: true)) }

    func toggleVoice() {
        Prefs.shared.voice.toggle()
        if !Prefs.shared.voice { Voice.shared.stop() }
    }

    /// Pour le HUD : la manœuvre « puis » si elle suit de près la prochaine.
    func thenIndex(_ route: Route, _ next: Int, _ distToNext: Double) -> Int? {
        let ms = route.maneuvers
        guard next + 1 < ms.count, let c = ctx, c.route.id == route.id else { return nil }
        let m = ms[next], after = ms[next + 1]
        let last = c.cum.count - 1
        let gap = c.cum[min(after.shapeIndex, last)] - c.cum[min(m.shapeIndex, last)]
        if GuidancePhrases.kind(m) == .roundabout && GuidancePhrases.kind(after) == .roundaboutExit { return nil }
        return gap < 250 && distToNext < 1200 ? next + 1 : nil
    }

    // MARK: - Live Activity

    private func pushLive(force: Bool = false) {
        GuidanceLive.shared.update(liveState(), force: force)
    }

    private func liveState() -> NavActivityAttributes.ContentState {
        let route = core.route
        let ms = route?.maneuvers ?? []
        let idx = min(state.nextIndex, max(0, ms.count - 1))
        let remainingTime = core.progress?.remainingTime ?? route?.duration ?? 0
        let remaining = core.progress?.remainingDistance ?? route?.distance ?? 0
        let total = route?.distance ?? 0
        var s = NavActivityAttributes.ContentState(distance: state.distToNext, instruction: "", street: nil, symbol: "arrow.up",
                                                   eta: Date().addingTimeInterval(remainingTime), remaining: remaining)
        s.progress = total > 0 ? min(1, max(0, 1 - remaining / total)) : 0
        if let a = state.arrived {
            s.arrived = true
            s.instruction = "Vous voilà à destination"
            s.street = a.name
            s.kind = "arrive"; s.symbol = GuidanceKind.arrive.symbol
            s.distance = 0; s.progress = 1; s.eta = Date()
            return s
        }
        if state.recalculating {
            s.instruction = "Nouvel itinéraire…"
            s.street = "Recalcul depuis votre position"
            s.kind = "straight"
        } else if ms.indices.contains(idx) {
            let m = ms[idx]
            let kind = GuidancePhrases.kind(m)
            s.kind = kind.rawValue
            s.symbol = kind.symbol
            s.exit = kind == .roundabout ? GuidancePhrases.roundaboutExit(m) : nil
            s.instruction = GuidancePhrases.shortLabel(m)
            let street = kind == .roundabout ? (GuidancePhrases.roundaboutExitTarget(m)?.name ?? GuidancePhrases.mainStreet(m))
                : kind.isArrive ? (core.destination?.name ?? "") : kind == .waypoint ? "" : GuidancePhrases.mainStreet(m)
            s.street = street.isEmpty ? nil : street
            s.imminent = state.distToNext <= state.nowThreshold && !kind.isArrive
            if state.along == 0 && state.distToNext == 0 { s.distance = m.shapeIndex > 0 ? (ms.first?.length ?? 0) : 0 }
        }
        if let a = state.alerts.first {
            s.alert = a.text
            s.alertTone = a.displayTone.rawValue
            s.alertDistance = a.baseDistance > 0 ? max(0, a.remaining) : nil
        }
        return s
    }
}
