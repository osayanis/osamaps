#if DEBUG
import SwiftUI
import CoreLocation
import MapKit
import Observation

/// Outils de test (DEBUG uniquement), pour vérifier le module sans le module routing :
///
///   osamaps://safety-test?to=46.1278,3.4258[&from=46.5646,3.3332][&mode=drive|preview]
///       calcule l'itinéraire (POST routing/route), le met dans Core.routes et passe en conduite (ou aperçu)
///   osamaps://safety-test?night=1        simule 31 min de conduite à 2 h → rappel de fatigue
///   osamaps://safety-test?passenger=1    demande « Tu es passager ? » par le Bus (contrat public)
///   osamaps://safety-test?critair=V4     règle la vignette
///   osamaps://safety-test?settings=1     ouvre les Réglages
///   osamaps://safety-test?center=46.43,3.36[&km=9]   centre la carte (zones de danger en exploration), vue de km de côté
///
/// Même chose sans lien (le Simulateur demande « Ouvrir dans OsaMaps ? ») : argument de lancement
/// `-safetyTest "to=46.1278,3.4258&from=…"` (exécuté 2 s après le démarrage).
/// Argument de lancement `-safetyDebug YES` : petit panneau avec l'état du moteur et les dernières alertes.
@MainActor
@Observable
final class SafetyDebug {
    static let shared = SafetyDebug()
    var alerts: [String] = []
    var lastAnswer: String?
    var message: String?
    @ObservationIgnored private var token: BusToken?

    static func start() {
        guard shared.token == nil else { return }
        shared.token = Bus.shared.on { e in
            switch e {
            case .driveAlert(let a):
                shared.alerts.insert("\(a.kind) · \(a.text) · \(Int(a.distance)) m", at: 0)
                shared.alerts = Array(shared.alerts.prefix(5))
            case .custom(name: "safety:passenger-answer", let p):
                shared.lastAnswer = p["answer"]
            case .custom(name: "url", let p):
                if let s = p["url"], let u = URL(string: s), u.host() == "safety-test" { shared.handle(u) }
            default: break
            }
        }
        if let q = UserDefaults.standard.string(forKey: "safetyTest"), let u = URL(string: "osamaps://safety-test?" + q) {
            Task {
                try? await Task.sleep(for: .seconds(2))
                shared.handle(u)
            }
        }
    }

    private func handle(_ url: URL) {
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                           uniquingKeysWith: { a, _ in a })
        if let c = q["critair"], let v = SafetyCritAir(rawValue: c) { SafetySettings.shared.critair = v }
        if q["night"] != nil { SafetyEngine.shared.debugNight() }
        if q["settings"] != nil { Core.shared.settingsOpen = true }
        if let c = Self.coord(q["center"]), let map = Core.shared.map {
            Core.shared.follow = false
            let m = (Double(q["km"] ?? "") ?? 9) * 1000
            map.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: m, longitudinalMeters: m), animated: false)
        }
        let to = Self.coord(q["to"])
        let from = Self.coord(q["from"]) ?? Core.shared.position?.coordinate ?? Location.defaultCenter
        let mode = q["mode"] == "preview" ? Mode.preview : .drive
        Task {
            if let to { await route(from: from, to: to, mode: mode) }
            // « Tu es passager ? » par le contrat public du Bus (il faut rouler : on laisse le simulateur accélérer)
            if q["passenger"] != nil {
                if to != nil { try? await Task.sleep(for: .seconds(3)) }
                emit(.custom(name: "safety:passenger-check", payload: ["token": "debug"]))
            }
        }
    }

    private static func coord(_ s: String?) -> CLLocationCoordinate2D? {
        let p = (s ?? "").split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? .init(latitude: p[0], longitude: p[1]) : nil
    }

    private func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, mode: Mode) async {
        message = "itinéraire…"
        do {
            let body: [String: Any] = ["locations": [["lat": from.latitude, "lon": from.longitude], ["lat": to.latitude, "lon": to.longitude]],
                                       "costing": "auto"]
            let json = try await API.json("routing/route", method: "POST", body: body)
            guard let trip = (json as? [String: Any])?["trip"] as? [String: Any],
                  let legs = trip["legs"] as? [[String: Any]] else { message = "réponse inattendue"; return }
            var coords: [Coord] = []
            var maneuvers: [Maneuver] = []
            for leg in legs {
                let offset = max(0, coords.count - 1)
                let pts = Geo.decodePolyline(leg["shape"] as? String ?? "")
                coords += (coords.isEmpty ? pts : Array(pts.dropFirst())).map(Coord.init)
                for m in leg["maneuvers"] as? [[String: Any]] ?? [] {
                    maneuvers.append(Maneuver(instruction: m["instruction"] as? String ?? "", verbal: nil,
                                              type: m["type"] as? Int ?? 0, typeName: nil,
                                              shapeIndex: offset + (m["begin_shape_index"] as? Int ?? 0),
                                              length: (m["length"] as? Double ?? 0) * 1000, time: m["time"] as? Double ?? 0,
                                              street: (m["street_names"] as? [String])?.first))
                }
            }
            let summary = trip["summary"] as? [String: Any] ?? [:]
            let r = Route(id: "safety-test-\(Int(Date().timeIntervalSince1970))", coords: coords,
                          distance: (summary["length"] as? Double ?? 0) * 1000, duration: summary["time"] as? Double ?? 0,
                          maneuvers: maneuvers)
            let core = Core.shared
            core.destination = Place(name: "Test sécurité", coordinate: to)
            core.routes = [r]
            core.activeRoute = 0
            core.mode = mode
            if mode == .drive {
                core.follow = true
                emit(.driveStart(routeId: r.id))
            } else {
                MapHub.fit(r.coordinates)
            }
            message = "\(coords.count) points, \(Geo.formatDistance(r.distance))"
        } catch {
            message = "erreur : \(error.localizedDescription)"
        }
    }
}

/// Panneau d'état (seulement avec `-safetyDebug YES`).
struct SafetyDebugOverlay: View {
    @State private var dbg = SafetyDebug.shared
    @State private var engine = SafetyEngine.shared
    private let enabled = UserDefaults.standard.bool(forKey: "safetyDebug")

    var body: some View {
        if enabled {
            VStack(alignment: .leading, spacing: 2) {
                Text("safety · \(engine.dangers.count) zones · \(engine.curves.count) virages · \(engine.pois.count) poi · \(engine.zfe.count) zfe")
                Text("parcouru \(Int(engine.along)) m · dans zone : \(engine.inside == nil ? "non" : "oui")")
                if let next = engine.dangers.first(where: { $0.end > engine.along }) {
                    Text("prochaine zone \(Int(next.start))–\(Int(next.end)) m (\(next.kind))")
                }
                if let e = engine.zonesError { Text("zones : \(e)") }
                if let e = engine.zfeError { Text("zfe : \(e)") }
                if let m = dbg.message { Text(m) }
                if let a = dbg.lastAnswer { Text("passager → \(a)") }
                ForEach(dbg.alerts, id: \.self) { Text("• \($0)") }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 8).padding(.bottom, 120)
            .allowsHitTesting(false)
        }
    }
}
#endif
