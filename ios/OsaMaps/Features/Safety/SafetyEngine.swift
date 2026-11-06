import Foundation
import CoreLocation
import Observation

/// Le « moteur » sécurité (port de `engine.ts`) : analyse l'itinéraire actif (zones de danger, ZFE, virages,
/// passages à niveau, écoles), puis à chaque position en conduite émet des `.driveAlert` (une seule fois par
/// élément et par trajet ; ids préfixés « safety- ») et tient à jour l'état affiché par le HUD.
@MainActor
@Observable
final class SafetyEngine {
    static let shared = SafetyEngine()

    private(set) var routeId: String?
    private(set) var coords: [CLLocationCoordinate2D] = []
    private(set) var cum: [Double] = []
    private(set) var dangers: [SafetyDanger] = []
    private(set) var curves: [SafetyCurve] = []
    private(set) var pois: [SafetyRoutePoi] = []
    private(set) var zfe: [SafetyZfeCrossing] = []
    /// Zone de danger dans laquelle on roule (nil sinon).
    private(set) var inside: SafetyDanger?
    private(set) var along: Double = 0
    private(set) var zonesError: String?
    private(set) var zfeError: String?

    @ObservationIgnored private var ix: SafetySegIndex?
    /// Change à chaque nouvel itinéraire : les réponses tardives d'un ancien tracé sont ignorées.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hint = 0
    @ObservationIgnored private var alerted = Set<String>()
    @ObservationIgnored private var poiTimer = Date.distantPast
    @ObservationIgnored private var lastMode: Mode = .browse
    @ObservationIgnored private var tokens: [BusToken] = []
    @ObservationIgnored private var nightTimer: Timer?
    @ObservationIgnored private var nightDrive: TimeInterval = 0
    @ObservationIgnored private var nightReminders = 0
    @ObservationIgnored private var lastNightCheck: Date?

    private init() {}

    func start() {
        guard tokens.isEmpty else { return }
        lastMode = Core.shared.mode
        observeCore()
        analyze(Core.shared.route)
        tokens.append(Bus.shared.on { [weak self] e in
            guard let self else { return }
            switch e {
            case .geoTick(let p): self.onTick(p)
            case .driveRerouted: self.analyze(Core.shared.route, force: true)
            default: break
            }
        })
        nightTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in SafetyEngine.shared.nightCheck() }
        }
    }

    /// Suit `routes` / `activeRoute` / `mode` du Core (Observation, sans Combine).
    private func observeCore() {
        withObservationTracking {
            let c = Core.shared
            _ = c.routes; _ = c.activeRoute; _ = c.mode
        } onChange: {
            Task { @MainActor in
                let me = SafetyEngine.shared
                me.coreChanged()
                me.observeCore()
            }
        }
    }

    private func coreChanged() {
        let c = Core.shared
        if c.mode == .drive && lastMode != .drive {
            // nouveau trajet : on peut ré-alerter les mêmes éléments
            alerted.removeAll()
            nightDrive = 0
            nightReminders = 0
            lastNightCheck = Date()
        }
        if c.mode != .drive, inside != nil { inside = nil }
        lastMode = c.mode
        analyze(c.route)
    }

    private func alert(_ id: String, kind: String, text: String, distance: Double, tone: DriveAlert.Tone) {
        guard !alerted.contains(id) else { return }
        alerted.insert(id)
        emit(.driveAlert(DriveAlert(id: id, kind: kind, text: text, distance: max(0, distance.rounded()), tone: tone)))
    }

    // MARK: - Analyse de l'itinéraire

    /// Tuiles de zones (zoom 8) traversées par le tracé, avec une marge de ~3 km (un tronçon dont le
    /// milieu est dans la tuile voisine peut déborder jusqu'à 2 km).
    private static func zoneTiles(_ ix: SafetySegIndex) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        var d = 0.0
        let total = ix.total
        while true {
            let p = Geo.along(ix.coords, ix.cum, min(d, total))
            let dLat = 0.03, dLng = 0.03 / max(0.2, cos(p.latitude * .pi / 180))
            for k in SafetyGeo.zoneTiles(w: p.longitude - dLng, s: p.latitude - dLat, e: p.longitude + dLng, n: p.latitude + dLat)
            where seen.insert(k).inserted { keys.append(k) }
            if d >= total { break }
            d += 1500
        }
        return keys
    }

    func analyze(_ route: Route?, force: Bool = false) {
        guard let route, route.coords.count >= 2 else {
            if routeId != nil {
                generation += 1
                ix = nil
                routeId = nil; coords = []; cum = []; dangers = []; curves = []; pois = []; zfe = []; inside = nil
            }
            return
        }
        if routeId == route.id && !force { return }
        generation += 1
        let gen = generation
        let line = route.coordinates
        let cum = Geo.cumulative(line)
        let index = SafetySegIndex(coords: line, cum: cum)
        ix = index
        hint = 0
        routeId = route.id; coords = line; self.cum = cum
        dangers = []; pois = []; zfe = []; curves = []; inside = nil; along = 0

        Task.detached(priority: .utility) {
            let found = SafetyAnalysis.findCurves(route, cum)
            await MainActor.run {
                let me = SafetyEngine.shared
                if me.generation == gen { me.curves = found }
            }
        }
        loadZones(route: route, index: index, gen: gen, attempt: 0)
        loadZfe(line: line, cum: cum, gen: gen, attempt: 0)
        refreshPois(from: 0)
    }

    /// Données serveur, avec nouvelles tentatives (serveur qui démarre ou injoignable) : 5 × 30 s.
    private func loadZones(route: Route, index: SafetySegIndex, gen: Int, attempt: Int) {
        Task {
            let keys = Self.zoneTiles(index)
            let got = await SafetyData.zoneTiles(keys)
            guard generation == gen else { return }
            var byId: [String: SafetyZone] = [:]
            for list in got.values { for z in list { byId[z.id] = z } }
            let zones = Array(byId.values)
            let found = await Task.detached(priority: .utility) { SafetyAnalysis.dangerIntervals(index, zones) }.value
            guard generation == gen else { return }
            dangers = found
            let missing = got.count < keys.count
            zonesError = missing ? (SafetyData.zonesError ?? "zones de danger indisponibles") : nil
            if missing { retry(attempt) { $0.loadZones(route: route, index: index, gen: gen, attempt: attempt + 1) } }
        }
    }

    private func loadZfe(line: [CLLocationCoordinate2D], cum: [Double], gen: Int, attempt: Int) {
        Task {
            do {
                let r = try await SafetyData.zfe()
                let features = r.features
                let found = await Task.detached(priority: .utility) { SafetyAnalysis.zfeCrossings(line, cum, features) }.value
                guard generation == gen else { return }
                zfe = found
                zfeError = r.available ? nil : (r.error ?? "indisponible")
                if !r.available { retry(attempt) { $0.loadZfe(line: line, cum: cum, gen: gen, attempt: attempt + 1) } }
            } catch {
                guard generation == gen else { return }
                zfeError = error.localizedDescription
                retry(attempt) { $0.loadZfe(line: line, cum: cum, gen: gen, attempt: attempt + 1) }
            }
        }
    }

    private func retry(_ attempt: Int, _ again: @escaping @MainActor (SafetyEngine) -> Void) {
        guard attempt < 5 else { return }
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(30))
            if SafetyEngine.shared.generation == gen { again(SafetyEngine.shared) }
        }
    }

    /// Tuiles (zoom 12) couvrant les `ahead` prochains mètres du tracé.
    private func refreshPois(from start: Double, ahead: Double = 15_000) {
        let st = SafetySettings.shared
        guard st.levelCrossings || st.schools, let index = ix else { return }
        let gen = generation
        var keys: [String] = []
        var d = start
        let end = min(index.total, start + ahead)
        while d <= end {
            let k = SafetyGeo.tileKey(Geo.along(index.coords, index.cum, d))
            if !keys.contains(k) { keys.append(k) }
            d += 400
        }
        Task {
            let tiles = await SafetyData.poiTiles(keys)
            guard generation == gen else { return }
            var lc: [[Double]] = [], sc: [[Double]] = []
            for t in tiles.values { lc += t.lc; sc += t.sc }
            let found = await Task.detached(priority: .utility) { SafetyAnalysis.poisAlong(index, lc: lc, sc: sc) }.value
            guard generation == gen else { return }
            // fusionne avec ce qu'on connaît déjà (tuiles précédentes)
            var known = Dictionary(pois.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for p in found { known[p.id] = p }
            pois = known.values.sorted { $0.along < $1.along }
        }
    }

    // MARK: - Alertes en conduite

    private func onTick(_ position: Position) {
        let core = Core.shared
        guard core.mode == .drive, routeId != nil, coords.count >= 2 else {
            if inside != nil { inside = nil }
            return
        }
        let snap = SafetyAnalysis.snapWindow(position.coordinate, coords, cum, hint: hint)
        hint = snap.index
        let here = snap.along
        let onRoute = snap.offset < 60
        let set = SafetySettings.shared
        let speed = position.speed ?? 0

        // 1. zones de danger : alerte à l'approche (250 m) / à l'entrée, bandeau tant qu'on y est
        var now: SafetyDanger?
        if set.dangerZones && onRoute {
            for z in dangers {
                if here >= z.start - 250 && here < z.end {
                    alert("safety-dz-\(z.id)-\(Int(z.start.rounded()))", kind: "danger-zone", text: "Zone de danger",
                          distance: z.start - here, tone: .warn)
                }
                if here >= z.start && here < z.end { now = z }
            }
        }
        if now != inside { inside = now }
        along = here
        guard onRoute else { return }

        // 2. virages serrés : seulement si l'on roule vite pour ce rayon (accélération latérale > 3,5 m/s²)
        if set.curves && speed >= 55 / 3.6 {
            for c in curves {
                let d = c.start - here
                if d >= 0 && d <= 320 && speed * speed / max(1, c.radius) > 3.5 {
                    let label = c.count > 1 ? "Virages serrés" : "Virage serré"
                    alert("safety-curve-\(c.id)", kind: "sharp-curve", text: "\(label) dans \(Self.rounded50(d))", distance: d, tone: .info)
                }
            }
        }

        // 3. passages à niveau et écoles (écoles : en semaine de 7 h à 19 h)
        let cal = Calendar(identifier: .gregorian)
        let wd = cal.component(.weekday, from: Date()), h = cal.component(.hour, from: Date())
        let schoolTime = (2...6).contains(wd) && h >= 7 && h < 19
        for p in pois {
            let d = p.along - here
            if p.kind == .levelCrossing && set.levelCrossings && d >= 0 && d <= 300 {
                alert("safety-\(p.id)", kind: "level-crossing", text: "Passage à niveau dans \(Self.rounded50(d))", distance: d, tone: .info)
            }
            if p.kind == .school && set.schools && schoolTime && d >= 0 && d <= 200 {
                alert("safety-\(p.id)", kind: "school-zone", text: "Zone école : ralentis", distance: d, tone: .info)
            }
        }

        // 4. ZFE : prévenir 1 km avant l'entrée (rien si la vignette réglée est autorisée)
        if set.zfe {
            for z in zfe {
                let d = z.entry - here
                guard d >= 0, d <= 1000, let vp = z.props.vp else { continue }
                let forbidden = set.critair.forbidden(firstForbidden: vp)
                if forbidden == false { continue }
                let text = forbidden == true
                    ? "ZFE dans \(Geo.formatDistance(d)) : \(set.critair.label) non autorisée"
                    : "Tu entres dans une ZFE dans \(Geo.formatDistance(d))"
                alert("safety-zfe-\(z.props.id)-\(Int(z.entry.rounded()))", kind: "zfe", text: text, distance: d,
                      tone: forbidden == true ? .warn : .info)
            }
        }

        // 5. tuiles de passages à niveau / écoles devant soi (au plus toutes les 20 s)
        if Date().timeIntervalSince(poiTimer) > 20 {
            poiTimer = Date()
            refreshPois(from: here)
        }
    }

    private static func rounded50(_ d: Double) -> String {
        Geo.formatDistance(max(50, (d / 50).rounded() * 50))
    }

    // MARK: - Fatigue de nuit

    /// Rappel doux si l'on conduit de nuit (entre 1 h et 5 h) depuis 30 min, puis toutes les heures.
    /// Ids propres (« safety-night-… ») et seuils distincts des pauses classiques (module along).
    func nightCheck(now: Date = Date()) {
        let dt = lastNightCheck.map { max(0, min(now.timeIntervalSince($0), 300)) } ?? 0
        lastNightCheck = now
        let core = Core.shared
        let h = Calendar.current.component(.hour, from: now)
        let moving = (core.position?.speed ?? 0) > 2
        guard core.mode == .drive, h >= 1, h < 5 else {
            if core.mode != .drive { nightDrive = 0 }
            return
        }
        if moving { nightDrive += dt }
        let due = 30 * 60 + Double(nightReminders) * 3600
        if SafetySettings.shared.night && nightDrive >= due {
            nightReminders += 1
            let day = Calendar.current.startOfDay(for: now).timeIntervalSince1970
            alert("safety-night-\(nightReminders)-\(Int(day))", kind: "night-fatigue",
                  text: "Il est tard : si la fatigue arrive, offre-toi une pause", distance: 0, tone: .info)
        }
    }

    #if DEBUG
    /// Tests : simule 31 min de conduite à 2 h du matin (lien osamaps://safety-test?night=1).
    func debugNight() {
        nightDrive = 31 * 60
        let night = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
        lastNightCheck = night
        nightCheck(now: night)
    }
    #endif
}
