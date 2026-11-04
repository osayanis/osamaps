#if DEBUG
import MapKit

/// Tracé de test dessiné par le module (seulement en DEBUG, quand routing n'est pas là).
final class AlongDebugRoute: MKPolyline {}

/// Outils de test sans le module routing :
///   osamaps://along-test[?name=Vichy&lat=46.1278&lng=3.4258]  → calcule un vrai itinéraire (serveur) et passe en aperçu
///   osamaps://along-station[?kind=cheapest]                   → ouvre la fiche de la station la moins chère du trajet
@MainActor
enum AlongDebug {
    private static var token: BusToken?

    static func start() {
        token = Bus.shared.on { e in
            guard case let .custom(name, payload) = e, name == "url",
                  let s = payload["url"], let url = URL(string: s) else { return }
            let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
            switch url.host() {
            case "along-test": Task { await injectRoute(q) }
            case "along-station": openCheapest()
            default: break
            }
        }
    }

    private struct ValhallaResponse: Decodable {
        struct Trip: Decodable {
            struct Leg: Decodable { var shape: String }
            struct Summary: Decodable { var length: Double; var time: Double }
            var legs: [Leg]
            var summary: Summary
        }
        var trip: Trip
    }

    private struct Loc: Encodable { var lat: Double; var lon: Double }
    private struct Body: Encodable { var locations: [Loc] }

    private static func injectRoute(_ q: [String: String]) async {
        let core = Core.shared
        let to = CLLocationCoordinate2D(latitude: Double(q["lat"] ?? "") ?? 46.1278, longitude: Double(q["lng"] ?? "") ?? 3.4258)
        let from = core.position?.coordinate ?? Location.defaultCenter
        do {
            let v: ValhallaResponse = try await API.post("routing/route", body: Body(locations: [.init(lat: from.latitude, lon: from.longitude), .init(lat: to.latitude, lon: to.longitude)]))
            let coords = v.trip.legs.flatMap { Geo.decodePolyline($0.shape) }
            let route = Route(id: "along-test-\(Int(Date.now.timeIntervalSince1970))", coords: coords.map(Coord.init),
                              distance: v.trip.summary.length * 1000, duration: v.trip.summary.time, maneuvers: [])
            core.destination = Place(name: q["name"] ?? "Vichy", coordinate: to)
            core.routes = [route]
            core.activeRoute = 0
            core.openPanel(nil)
            core.mode = .preview
            if let map = core.map {
                map.removeOverlays(map.overlays.filter { $0 is AlongDebugRoute })
                map.addOverlay(AlongDebugRoute(coordinates: coords, count: coords.count), level: .aboveRoads)
            }
            try? await Task.sleep(for: .milliseconds(400))
            MapHub.fit(coords)
            NSLog("OsaMaps along : itinéraire de test %.0f km, %d points", route.distance / 1000, coords.count)
        } catch {
            NSLog("OsaMaps along : itinéraire de test impossible (%@)", error.localizedDescription)
        }
    }

    private static func openCheapest() {
        let m = AlongModel.shared, e = AlongPrefs.shared.energy
        if e.isEV {
            let list = m.route?.ev ?? m.nearbyEv
            if let s = list.max(by: { $0.kw < $1.kw }) { Core.shared.openPanel("along.station", data: AlongStationRef.ev(s)) }
        } else {
            let list = m.route?.fuel ?? m.nearbyFuel
            let s = AlongFormat.rankOnRoute(list, e).first?.station
                ?? list.compactMap { st in AlongFormat.usablePrice(st, e).map { (st, $0) } }.min(by: { $0.1 < $1.1 })?.0
            if let s { Core.shared.openPanel("along.station", data: AlongStationRef.fuel(s)) }
        }
    }
}
#endif
