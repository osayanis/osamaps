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
        // Arguments de lancement (le simulateur iOS 27 bloque `simctl openurl` derrière une alerte) :
        //   -alongTest YES            itinéraire de test vers Vichy, en aperçu
        //   -alongOpen fuel|weather|station|settings   panneau ouvert ensuite
        //   -alongDrive YES           démarre ensuite la conduite
        let d = UserDefaults.standard
        //   -alongView 45.76,4.87,0.05   carte centrée (lat, lng, largeur en degrés), sans suivi : captures en exploration
        if let v = d.string(forKey: "alongView")?.split(separator: ",").compactMap({ Double($0) }), v.count == 3 {
            Task {
                try? await Task.sleep(for: .seconds(4))
                Core.shared.follow = false
                Core.shared.map?.setRegion(MKCoordinateRegion(center: .init(latitude: v[0], longitude: v[1]),
                                                              span: .init(latitudeDelta: v[2], longitudeDelta: v[2])), animated: false)
            }
        }
        if d.bool(forKey: "alongTest") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                await injectRoute([:])
                try? await Task.sleep(for: .seconds(4))
                switch d.string(forKey: "alongOpen") ?? "" {
                case "fuel": Core.shared.openPanel("along.fuel")
                case "weather": Core.shared.openPanel("along.weather")
                case "station": openCheapest()
                case "settings": Core.shared.settingsOpen = true
                default: break
                }
                if d.bool(forKey: "alongDrive"), let r = Core.shared.route {
                    Core.shared.mode = .drive
                    Core.shared.follow = true
                    emit(.driveStart(routeId: r.id))
                }
            }
        } else if d.string(forKey: "alongOpen") == "settings" {
            Task { try? await Task.sleep(for: .seconds(3)); Core.shared.settingsOpen = true }
        } else if d.string(forKey: "alongOpen") == "station" {
            Task { try? await Task.sleep(for: .seconds(6)); openCheapest() }
        }
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
