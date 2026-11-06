import SwiftUI
import MapKit

/// « Trafic en direct » : calque (communauté + Bison Futé), bouton du rail, retard en conduite,
/// fiches, réglages, et contribution anonyme.
@MainActor
let trafficFeature = Feature(
    id: "traffic",
    name: "Trafic en direct",
    slots: [
        SlotEntry(.rail, order: 40) { TrafficRailButton() },
        SlotEntry(.hud, order: 60) { TrafficDelayHUD() },
        SlotEntry(.sheet, order: 50) { TrafficSheet() },
        SlotEntry(.settings, order: 40) { TrafficSettingsSection() },
    ],
    mapLayers: [TrafficMapController.shared.layer],
    start: {
        TrafficContribution.shared.start()
        TrafficDriveController.shared.start()
        #if DEBUG
        TrafficDebug.start()
        #endif
    }
)

#if DEBUG
/// Lien de test (build DEBUG uniquement) : `osamaps://traffic-test` recadre la carte là où il y a des
/// données officielles (autoroutes de l'est lyonnais). Paramètres :
///   place=lyon|marseille            zone à montrer
///   settings=1                      ouvre les Réglages
///   open=event|segment              ouvre la fiche du premier évènement / du premier tronçon ralenti chargé
///   drive=1&from=lat,lng&to=lat,lng calcule un VRAI itinéraire (Valhalla) et lance la conduite dessus
///                                   (le module routing n'est pas dans cette branche) — pour tester along/HUD/alertes
@MainActor
enum TrafficDebug {
    private static var token: BusToken?

    static func start() {
        token = Bus.shared.on { e in
            guard case .custom(let name, let payload) = e, name == "url",
                  let s = payload["url"], let url = URL(string: s), url.host() == "traffic-test" else { return }
            handle(url)
        }
        // même test par argument de lancement (évite la confirmation « Ouvrir dans OsaMaps ? » du simulateur) :
        //   -trafficTest "place=lyon&open=event"
        if let args = UserDefaults.standard.string(forKey: "trafficTest"), let url = URL(string: "osamaps://traffic-test?" + args) {
            Task { @MainActor in
                while !Core.shared.mapReady { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1.5))
                handle(url)
            }
        }
    }

    private static func handle(_ url: URL) {
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                           uniquingKeysWith: { _, b in b })
        // from=here : départ de la position actuelle (le simulateur reprend là où il s'était arrêté)
        if q["drive"] == "1", let from = q["from"] == "here" ? Core.shared.position?.coordinate : coord(q["from"]), let to = coord(q["to"]) {
            Task { await drive(from: from, to: to) }
            return
        }
        let (center, span) = q["place"] == "marseille"
            ? (CLLocationCoordinate2D(latitude: 43.40, longitude: 5.38), 0.32)
            : (CLLocationCoordinate2D(latitude: 45.765, longitude: 4.90), 0.20)
        Core.shared.follow = false
        Core.shared.map?.setRegion(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)), animated: false)
        if q["settings"] == "1" { Core.shared.settingsOpen = true }
        guard let open = q["open"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let ctl = TrafficMapController.shared
            if open == "event", let e = ctl.currentEvents.first {
                Core.shared.openPanel("traffic-event", data: e.properties)
            } else if open == "segment", let s = ctl.currentSegments.first(where: { $0.properties.level != "ok" }) ?? ctl.currentSegments.first {
                Core.shared.openPanel("traffic-segment", data: s.properties)
            }
        }
    }

    private static func coord(_ s: String?) -> CLLocationCoordinate2D? {
        let p = (s ?? "").split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? .init(latitude: p[0], longitude: p[1]) : nil
    }

    private struct ValhallaResponse: Decodable {
        struct Trip: Decodable { var legs: [Leg]; var summary: Summary }
        struct Leg: Decodable { var shape: String }
        struct Summary: Decodable { var length: Double; var time: Double }
        var trip: Trip
    }

    private static func drive(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async {
        let body = """
        {"locations":[{"lat":\(from.latitude),"lon":\(from.longitude)},{"lat":\(to.latitude),"lon":\(to.longitude)}],"costing":"auto","directions_options":{"units":"kilometers","language":"fr-FR"}}
        """
        var c = URLComponents(url: External.valhalla.appendingPathComponent("route"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "json", value: body)]
        do {
            let r = try await API.external(c.url!, as: ValhallaResponse.self)
            let coords = r.trip.legs.flatMap { Geo.decodePolyline($0.shape) }.map(Coord.init)
            let route = Route(id: "traffic-test-\(UUID().uuidString.prefix(6))", coords: coords, distance: r.trip.summary.length * 1000,
                              duration: r.trip.summary.time, maneuvers: [])
            let core = Core.shared
            core.destination = Place(name: "Test trafic", coordinate: to)
            core.routes = [route]; core.activeRoute = 0
            core.mode = .drive; core.follow = true
            emit(.driveStart(routeId: route.id))
            NSLog("OsaMaps traffic: itinéraire de test %.1f km", route.distance / 1000)
        } catch {
            NSLog("OsaMaps traffic: itinéraire de test impossible (%@)", String(describing: error))
        }
    }
}
#endif
