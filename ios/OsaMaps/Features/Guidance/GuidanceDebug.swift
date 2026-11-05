#if DEBUG
import Foundation
import CoreLocation

/// Banc d'essai du guidage SANS le module routing (DEBUG uniquement) :
///   osamaps://guidance-test                         Moulins → Vichy, conduite démarrée
///   osamaps://guidance-test?to=46.13,3.43&via=46.34,3.41&name=Vichy   destination / étape
///   …&limits=8      limites de vitesse ajoutées 8 s après (même id de route : la progression doit rester)
///   …&off=20        20 s après le départ, la position est décalée de 250 m (sortie de route → recalcul)
///   …&alert=12      12 s après, une alerte police à 800 m (« Police signalée dans 800 m »)
///   …&settings=5    ouvre les Réglages 5 s après
/// Pendant un test, `.routeRecompute` est traité ici (nouveau calcul depuis la position) comme le ferait routing.
/// Sans lien (iOS 27 : `simctl openurl` demande une confirmation), argument de lancement :
///   -guidanceTest YES   ou   -guidanceTest "to=46.13,3.43&limits=8&alert=12"
@MainActor
enum GuidanceDebug {
    /// Décalage (m) appliqué aux positions par le moteur : simule une sortie de route.
    static var offset = 0.0
    private static var token: BusToken?
    private static var testing = false
    private static var dest: Place?
    private static var via: CLLocationCoordinate2D?

    static func start() {
        if let arg = UserDefaults.standard.string(forKey: "guidanceTest"), let url = URL(string: "osamaps://guidance-test?" + (arg == "YES" ? "" : arg)) {
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                run(url)
            }
        }
        token = Bus.shared.on { e in
            MainActor.assumeIsolated {
                switch e {
                case .custom(name: "url", let payload):
                    guard let s = payload["url"], let url = URL(string: s), url.host() == "guidance-test" else { return }
                    run(url)
                case .routeRecompute(let from):
                    guard testing, let dest else { return }
                    offset = 0
                    Task { await reroute(from: from, to: dest) }
                case .driveStop:
                    testing = false
                default: break
                }
            }
        }
    }

    private static func coord(_ s: String?) -> CLLocationCoordinate2D? {
        guard let p = s?.split(separator: ","), p.count == 2, let a = Double(p[0]), let b = Double(p[1]) else { return nil }
        return .init(latitude: a, longitude: b)
    }

    private static func run(_ url: URL) {
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let to = coord(q["to"]) ?? .init(latitude: 46.1278, longitude: 3.4258)
        let place = Place(name: q["name"] ?? "Vichy", coordinate: to)
        dest = place
        via = coord(q["via"])
        let from = Core.shared.position?.coordinate ?? Location.defaultCenter
        Task {
            do {
                var pts = [from]
                if let via { pts.append(via) }
                pts.append(to)
                let route = try await fetchRoute(pts, id: "test-\(Int(Date().timeIntervalSince1970))")
                let core = Core.shared
                core.destination = place
                core.routes = [route]
                core.activeRoute = 0
                core.openPanel(nil)
                core.mode = .drive
                core.follow = true
                testing = true
                emit(.driveStart(routeId: route.id))
                after(q["limits"]) {
                    if let limits = try? await fetchLimits(route.coords), core.route?.id == route.id {
                        core.routes[core.activeRoute].speedLimits = limits
                    }
                }
                after(q["off"]) { if testing { offset = 250 } }
                after(q["alert"]) {
                    emit(.driveAlert(DriveAlert(id: "test-police", kind: "police", text: "Police signalée dans 800 m", distance: 800, tone: .police)))
                }
                after(q["settings"]) { core.settingsOpen = true }
            } catch {
                emit(.toast(Toast(text: "Test guidage : \(error.localizedDescription)", tone: .warn)))
            }
        }
    }

    /// Lance `work` après `seconds` secondes (paramètre du lien), si le paramètre est présent.
    private static func after(_ seconds: String?, _ work: @escaping @MainActor () async -> Void) {
        guard let s = Double(seconds ?? "") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(s))
            await work()
        }
    }

    private static func reroute(from: CLLocationCoordinate2D, to: Place) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let route = try? await fetchRoute([from, to.coordinate], id: "test-\(Int(Date().timeIntervalSince1970))") else { return }
        Core.shared.routes = [route]
        Core.shared.activeRoute = 0
        emit(.driveRerouted(routeId: route.id))
    }

    // MARK: - Valhalla (via le proxy du serveur), même conversion que le module routing du web

    private static let laneBits: [(Int, String)] = [(1, "straight"), (2, "slight_right"), (4, "right"), (8, "sharp_right"),
                                                     (16, "uturn"), (32, "sharp_left"), (64, "left"), (128, "slight_left")]

    static func fetchRoute(_ pts: [CLLocationCoordinate2D], id: String) async throws -> Route {
        let body: [String: Any] = ["locations": pts.map { ["lat": $0.latitude, "lon": $0.longitude] }, "alternates": 0]
        let json = try await API.json("routing/route", method: "POST", body: body)
        guard let root = json as? [String: Any], let trip = root["trip"] as? [String: Any],
              let legs = trip["legs"] as? [[String: Any]], let summary = trip["summary"] as? [String: Any] else {
            throw API.HTTPError(status: 0, message: "réponse inattendue")
        }
        var coords: [Coord] = []
        var maneuvers: [Maneuver] = []
        for (li, leg) in legs.enumerated() {
            let shape = Geo.decodePolyline(leg["shape"] as? String ?? "").map(Coord.init)
            let offset = li == 0 ? 0 : coords.count - 1
            coords += li == 0 ? shape : Array(shape.dropFirst())
            let ms = leg["maneuvers"] as? [[String: Any]] ?? []
            for (mi, m) in ms.enumerated() {
                let streets = (m["street_names"] as? [String]) ?? (m["begin_street_names"] as? [String]) ?? []
                var man = Maneuver(instruction: m["instruction"] as? String ?? "",
                                   verbal: m["verbal_pre_transition_instruction"] as? String,
                                   type: m["type"] as? Int ?? 0, typeName: nil,
                                   shapeIndex: (m["begin_shape_index"] as? Int ?? 0) + offset,
                                   length: ((m["length"] as? Double) ?? 0) * 1000, time: (m["time"] as? Double) ?? 0,
                                   street: streets.first, roundaboutExit: m["roundabout_exit_count"] as? Int, lanes: nil)
                if let lanes = m["lanes"] as? [[String: Any]], !lanes.isEmpty {
                    man.lanes = lanes.map { l in
                        let bits = l["directions"] as? Int ?? 0
                        let dirs = laneBits.filter { bits & $0.0 != 0 }.map(\.1)
                        return .init(directions: dirs.isEmpty ? ["straight"] : dirs, valid: (l["valid"] as? Int ?? 0) != 0 || (l["active"] as? Int ?? 0) != 0)
                    }
                }
                if mi == ms.count - 1 && li < legs.count - 1 {
                    man.typeName = "waypoint"
                    man.instruction = "Étape atteinte : étape \(li + 1)"
                }
                maneuvers.append(man)
            }
        }
        return Route(id: id, coords: coords, distance: ((summary["length"] as? Double) ?? 0) * 1000,
                     duration: (summary["time"] as? Double) ?? 0, maneuvers: maneuvers, speedLimits: nil, summary: nil)
    }

    static func fetchLimits(_ coords: [Coord]) async throws -> [Route.SpeedLimit] {
        let slice = Array(coords.prefix(6000))
        let json = try await API.json("routing/trace", method: "POST", body: ["encoded_polyline": encode(slice)])
        let edges = (json as? [String: Any])?["edges"] as? [[String: Any]] ?? []
        var out: [Route.SpeedLimit] = [.init(from: 0, kmh: nil)]
        for e in edges {
            let from = e["b"] as? Int ?? 0
            let kmh = e["kmh"] as? Int
            if out.last?.kmh == kmh { continue }
            if out.last?.from == from { out[out.count - 1].kmh = kmh } else { out.append(.init(from: from, kmh: kmh)) }
        }
        return out
    }

    /// Polyline encodée, précision 6 (Valhalla).
    private static func encode(_ pts: [Coord]) -> String {
        var out = "", lat = 0, lng = 0
        func put(_ v: Int) {
            var x = v < 0 ? ~(v << 1) : v << 1
            while x >= 0x20 { out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (x & 0x1f)) + 63))); x >>= 5 }
            out.unicodeScalars.append(UnicodeScalar(UInt8(x + 63)))
        }
        for p in pts {
            let a = Int((p.lat * 1e6).rounded()), b = Int((p.lng * 1e6).rounded())
            put(a - lat); put(b - lng); lat = a; lng = b
        }
        return out
    }
}
#endif
